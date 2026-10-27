const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const runtime = path.resolve(__dirname, '../../CardShowScanner/Resources/ScannerRuntime/newscanplus/assets/js');
const clone = value => JSON.parse(JSON.stringify(value));
const inner = [[90, 100], [230, 100], [230, 300], [90, 300]];
const holder = [[80, 85], [240, 85], [240, 315], [80, 315]];
const shifted = (quad, dx, dy = 0) => quad.map(([x, y]) => [x + dx, y + dy]);
const scale = (quad, factor) => quad.map(([x, y]) => [x * factor, y * factor]);
function result({ quad = inner, accepted = true, index = 0, solid = true, w = 320, h = 448 } = {}) {
  return { quad: solid ? clone(quad) : null, solid, w, h, frames: solid ? 1 : 0, stage: solid ? 'full' : '', tracked: false,
    ms: { total: 1 }, result: solid ? { accepted, confidence: 96, gap: 5, best: { i: index, d: 1, siblings: [], confidence: 96 } } : null };
}

async function flow({ enabled = true, sameArt = false } = {}) {
  let clock = 0, motion = 'stable', scheduled, nextScan = result(), lastPaint = null;
  let nextOutline = { quad: clone(holder), w: 320, h: 448 };
  const scans = [], draws = [], shows = [], clears = [];
  const video = { videoWidth: 1280, videoHeight: 1792 };
  const context = vm.createContext({ console, performance: { now: () => clock } });
  const pack = { cl: new Int32Array(sameArt ? [7, 7] : [-1, -1]), refs: [0, 1].map(i => [`p:${i + 1}`, `Card ${i}`, '1/2', 'T', 'Test', '', '', [{ primary: true, nm: 1 }]]) };
  const stubs = {
    '/core/motion.js': { createMotionGate: () => ({ update: () => ({ state: motion }) }), thumbFromImageData: image => image },
    '/core/overlay.js': { STATES: { SEARCHING: 'searching', MATCHED: 'matched', LOW: 'low', RETRY: 'retry' } },
    '/app/video-frames.js': { createFrameReader: () => { throw new Error('The test must supply its frame reader'); } },
    '/core/setrank.js': { rankTies: (_pack, indices) => indices },
    '/app/desk-results.js': {
      candidatesFrom: (p, r) => [{ ref: p.refs[r.best.i][0], tuple: p.refs[r.best.i], confidence: 96 }],
      resolveScanCands: async () => {}, applyResolvedToView() {}
    },
    '/app/desk-images.js': { quadJpeg: () => '' }
  };
  const modules = new Map();
  async function load(file) {
    if (modules.has(file)) return modules.get(file);
    const exports = Object.entries(stubs).find(([suffix]) => file.endsWith(suffix))?.[1];
    const module = exports
      ? new vm.SyntheticModule(Object.keys(exports), function () { for (const [key, value] of Object.entries(exports)) this.setExport(key, value); }, { context, identifier: file })
      : new vm.SourceTextModule(fs.readFileSync(file, 'utf8'), { context, identifier: file });
    modules.set(file, module);
    await module.link((specifier, parent) => load(path.resolve(path.dirname(parent.identifier), specifier)));
    return module;
  }
  const module = await load(path.join(runtime, 'app/quickscan.js')); await module.evaluate();
  const options = {
    video, pack, retainAcceptedBorder: enabled, resolveCandidates: false,
    overlay: { setSource() {}, clear() { clears.push(clock); lastPaint = null; }, draw(value) { lastPaint = clone(value); draws.push(lastPaint); } },
    backend: { kind: 'worker', quadEveryMs: 80, reset() {},
      async scan(_video, options) { scans.push(clone(options)); return clone(nextScan); },
      async quad() { return clone(nextOutline); }
    },
    reader: { read: () => ({ data: new Uint8ClampedArray(16), width: 2, height: 2 }) },
    frame(_video, callback) { scheduled = callback; return () => {}; }, now: () => clock,
    onShow: value => shows.push(clone(value))
  };
  let stop = module.namespace.startQuickScan(options);
  return { scans, draws, shows, clears, video, stop: () => stop(),
    restart() { stop(); stop = module.namespace.startQuickScan(options); },
    set scan(value) { nextScan = value; }, set outline(value) { nextOutline = value; },
    async step(t, state = motion) { clock = t; motion = state; scheduled(); for (let i = 0; i < 5; i++) await Promise.resolve(); },
    get draw() { return lastPaint; }
  };
}

for (const [label, nextIndex] of [['duplicate', 0], ['same-art reprint', 1]]) {
  test(`rearming after absence restores a full payload for a ${label} before the old art hold expires`, async () => {
    const h = await flow({ sameArt: true });
    try {
      const camera = h.video;
      await h.step(0);
      assert.equal(h.shows[0].same, false);
      h.scan = result({ solid: false });
      await h.step(400); await h.step(900);
      h.scan = result({ index: nextIndex });
      await h.step(1400);
      assert.equal(h.shows.at(-1).same, true, 'the old accepted-art hold otherwise emits an unusable partial update');
      const before = h.shows.length;
      h.restart(); await h.step(1401);
      assert.equal(h.video, camera);
      assert.equal(h.shows.length, before + 1);
      assert.equal(h.shows.at(-1).same, false);
      assert.equal(h.shows.at(-1).ref[0], `p:${nextIndex + 1}`);
    } finally { h.stop(); }
  });
}

test('brief movement keeps the accepted inner outline searching, then requests a fresh border retry', async () => {
  const h = await flow();
  try {
    await h.step(0); await h.step(10);
    assert.equal(h.draw.state, 'matched');
    await h.step(100, 'moving'); await h.step(180, 'moving');
    assert.equal(h.draw.state, 'searching', 'old acceptance never keeps green while moving');
    assert.deepEqual(h.draw.quad, inner, 'the nested holder does not replace the accepted card during the retry');
    h.scan = result({ quad: shifted(inner, 2) });
    await h.step(450, 'stable');
    assert.deepEqual(h.scans[1], { reset: true, retainAcceptedBorder: true });
    await h.step(460, 'stable');
    assert.equal(h.draw.state, 'matched', 'green returns only after a new accepted scan');
  } finally { h.stop(); }
});

test('retention expires from the accepted scan time and repeated outlines cannot extend it', async () => {
  const h = await flow();
  try {
    await h.step(0); await h.step(10);
    for (const t of [100, 200, 300, 400, 500, 600, 650]) await h.step(t, 'moving');
    assert.deepEqual(h.draw.quad, inner);
    await h.step(701, 'moving'); await h.step(710, 'moving');
    assert.notDeepEqual(h.draw.quad, inner, 'expiry releases the original pose despite compatible holder observations');
    await h.step(720, 'stable');
    assert.equal(h.scans.at(-1).retainAcceptedBorder, false);
  } finally { h.stop(); }
});

test('normal outline tracking is unchanged when border retention is disabled', async () => {
  const h = await flow({ enabled: false });
  try {
    await h.step(0); await h.step(10); await h.step(100, 'moving'); await h.step(200, 'moving');
    assert.notDeepEqual(h.draw.quad, inner);
    assert.equal(h.draw.state, 'searching');
    await h.step(450, 'stable');
    assert.deepEqual(h.scans[1], { reset: true, retainAcceptedBorder: false });
  } finally { h.stop(); }
});

test('outline coordinates from a smaller frame retain the same inner pose without scaling confusion', async () => {
  const h = await flow();
  try {
    await h.step(0); await h.step(10);
    h.outline = { quad: scale(holder, 0.25), w: 80, h: 112 };
    await h.step(100, 'moving'); await h.step(200, 'moving');
    assert.deepEqual(h.draw.quad, inner); assert.equal(h.draw.state, 'searching');
    await h.step(450, 'stable');
    assert.equal(h.scans[1].retainAcceptedBorder, true);
  } finally { h.stop(); }
});

test('large translation, rotation and frame-aspect changes release the old border before the next scan', async () => {
  const angle = Math.PI / 4, cx = 160, cy = 200;
  const rotated = inner.map(([x, y]) => [cx + (x - cx) * Math.cos(angle) - (y - cy) * Math.sin(angle), cy + (x - cx) * Math.sin(angle) + (y - cy) * Math.cos(angle)]);
  for (const outline of [{ quad: shifted(inner, 130), w: 320, h: 448 }, { quad: rotated, w: 320, h: 448 }, { quad: holder, w: 320, h: 180 }]) {
    const h = await flow();
    try {
      await h.step(0); await h.step(10); h.outline = outline;
      await h.step(100, 'moving'); await h.step(200, 'moving'); await h.step(450, 'stable');
      assert.equal(h.scans[1].retainAcceptedBorder, false);
    } finally { h.stop(); }
  }
});

test('camera dimension changes and confirmed no-card scans clear retention', async () => {
  const changed = await flow();
  try {
    await changed.step(0); await changed.step(10); changed.video.videoHeight = 720;
    await changed.step(100, 'moving'); await changed.step(450, 'stable');
    assert.equal(changed.scans[1].retainAcceptedBorder, false);
  } finally { changed.stop(); }
  const removed = await flow();
  try {
    await removed.step(0); await removed.step(10); await removed.step(100, 'moving');
    removed.scan = result({ solid: false });
    await removed.step(450, 'stable'); await removed.step(460, 'moving');
    assert.notDeepEqual(removed.draw?.quad, inner, 'a no-card scan releases the held geometry immediately');
    removed.scan = result(); await removed.step(1000, 'stable');
    assert.equal(removed.scans.at(-1).retainAcceptedBorder, false);
  } finally { removed.stop(); }
});

test('an unaccepted replacement and stopping cannot retain the previous accepted card', async () => {
  const h = await flow();
  await h.step(0); await h.step(10); await h.step(100, 'moving');
  h.scan = result({ accepted: false, quad: shifted(inner, 3), index: 1 });
  await h.step(450, 'stable'); await h.step(500, 'moving');
  h.scan = result({ index: 1 }); await h.step(550, 'stable');
  assert.equal(h.scans.at(-1).retainAcceptedBorder, false);
  h.stop();
  const draws = h.draws.length; await h.step(600, 'moving');
  assert.equal(h.draws.length, draws);
});

test('a newly accepted identity replaces rather than retaining the previous card pose', async () => {
  const h = await flow();
  try {
    await h.step(0); await h.step(10); await h.step(100, 'moving');
    const replacement = shifted(inner, 30);
    h.scan = result({ index: 1, quad: replacement });
    await h.step(450, 'stable'); await h.step(470, 'moving');
    assert.deepEqual(h.draw.quad, replacement); assert.equal(h.draw.state, 'searching');
  } finally { h.stop(); }
});

async function backendHarness({ worker = false, bitmap = false } = {}) {
  const messages = [], engineOptions = [];
  const engine = { setPack() {}, setAllow() {}, reset() {}, dispose() {},
    scanMat(_mat, options) { engineOptions.push(clone(options)); return { ms: { total: 1 } }; } };
  const video = { videoWidth: 640, videoHeight: 896, readyState: 4 };
  const frame = { data: new Uint8ClampedArray(4), width: 1, height: 1 };
  class FakeWorker {
    postMessage(message) {
      messages.push(message);
      Promise.resolve().then(() => this.onmessage?.({ data: message.type === 'init'
        ? { type: 'ready', bitmap } : { type: message.type, seq: message.seq, scan: { ms: { total: 1 } } } }));
    }
    terminate() {}
  }
  const context = vm.createContext({ console, performance: { now: () => 0 },
    Worker: worker ? FakeWorker : undefined, createImageBitmap: async () => ({ width: 640, height: 896, close() {} }),
    setTimeout(fn, milliseconds) { if (milliseconds === 0) Promise.resolve().then(fn); return 0; }, clearTimeout() {} });
  const exports = {
    './shared.js': { versioned: value => value, importMap: () => ({}) },
    './video-frames.js': { createFrameReader: () => ({ read: () => frame }) },
    '../core/cv.js': { pickSrc: () => 'test-cv', cvReady: async () => {} },
    '../core/frame.js': { createGrabber: () => ({ grab: () => ({ mat: {} }), release() {}, dispose() {} }) },
    './scan-engine.js': { createScanEngine: () => engine }
  };
  const modules = new Map();
  async function stub(specifier) {
    if (modules.has(specifier)) return modules.get(specifier);
    assert.ok(exports[specifier], specifier);
    const values = exports[specifier];
    const mod = new vm.SyntheticModule(Object.keys(values), function () { for (const [key, value] of Object.entries(values)) this.setExport(key, value); }, { context });
    modules.set(specifier, mod); await mod.link(() => {}); await mod.evaluate(); return mod;
  }
  const mod = new vm.SourceTextModule(fs.readFileSync(path.join(runtime, 'app/scan-backends.js'), 'utf8'), {
    context, importModuleDynamically: specifier => stub(specifier)
  });
  await mod.link(specifier => stub(specifier)); await mod.evaluate();
  return { backend: await mod.namespace.createBackend(), messages, engineOptions, video };
}

test('main-thread fallback forwards the border-retry flag and defaults it off', async () => {
  const h = await backendHarness();
  try {
    await h.backend.scan(h.video, { reset: true, retainAcceptedBorder: true });
    await h.backend.scan(h.video, { reset: true });
    assert.deepEqual(h.engineOptions, [{ reset: true, retainAcceptedBorder: true }, { reset: true, retainAcceptedBorder: false }]);
  } finally { h.backend.dispose(); }
});

test('both bitmap and RGBA worker transports forward the retry flag', async () => {
  for (const bitmap of [false, true]) {
    const h = await backendHarness({ worker: true, bitmap });
    try {
      await h.backend.scan(h.video, { reset: true, retainAcceptedBorder: true });
      await h.backend.scan(h.video, { reset: true });
      const scans = h.messages.filter(message => message.type === 'scan');
      assert.equal(scans.length, 2); assert.equal(scans[0].retainAcceptedBorder, true); assert.equal(scans[1].retainAcceptedBorder, false);
      assert.equal(!!scans[0].bitmap, bitmap); assert.equal(!!scans[0].image, !bitmap);
    } finally { h.backend.dispose(); }
  }
});

test('the worker sends the explicit retry flag to the engine for both frame formats', async () => {
  const replies = [], engineOptions = [];
  const self = { location: { origin: 'https://local.test' }, postMessage(message) { replies.push(message); } };
  class Canvas {
    constructor(width, height) { this.width = width; this.height = height; }
    getContext() { return { drawImage() {}, getImageData: () => ({ width: this.width, height: this.height, data: new Uint8ClampedArray(this.width * this.height * 4) }) }; }
  }
  const engine = { scanRGBA(_image, options) { engineOptions.push(clone(options)); return { ms: {} }; } };
  const context = vm.createContext({ console, self, URL, OffscreenCanvas: Canvas, performance: { now: () => 0 },
    fetch: async () => ({ ok: true, text: async () => '' }) });
  const values = { createModuleLoader: () => async specifier => specifier.endsWith('/core/cv.js')
    ? { setCv() {}, settle: async () => ({}) } : { createScanEngine: () => engine } };
  const graph = new vm.SyntheticModule(Object.keys(values), function () { for (const [key, value] of Object.entries(values)) this.setExport(key, value); }, { context });
  await graph.link(() => {}); await graph.evaluate();
  const script = new vm.Script(fs.readFileSync(path.join(runtime, 'app/quickscan-worker.js'), 'utf8'), {
    importModuleDynamically: async () => graph
  });
  script.runInContext(context);
  async function send(message) {
    const count = replies.length; self.onmessage({ data: message });
    for (let i = 0; i < 100 && replies.length === count; i++) await new Promise(setImmediate);
    assert.ok(replies.length > count, 'worker reply'); assert.notEqual(replies.at(-1).type, 'error', JSON.stringify(replies.at(-1)));
  }
  await send({ type: 'init', map: {}, cvUrl: 'test-cv' });
  await send({ type: 'scan', seq: 1, reset: true, retainAcceptedBorder: true, image: { data: new Uint8ClampedArray(4), width: 1, height: 1 } });
  await send({ type: 'scan', seq: 2, reset: true, retainAcceptedBorder: true, bitmap: { width: 1, height: 1, close() {} } });
  await send({ type: 'scan', seq: 3, reset: true, image: { data: new Uint8ClampedArray(4), width: 1, height: 1 } });
  assert.deepEqual(engineOptions, [{ reset: true, retainAcceptedBorder: true }, { reset: true, retainAcceptedBorder: true }, { reset: true, retainAcceptedBorder: false }]);
});

async function engineHarness() {
  let clock = 0;
  const config = { trackPresent: true, fullPresent: true, trackAccepted: true, fullAccepted: true, cardIndex: 0 };
  const calls = { track: [], full: [], matches: [] };
  const context = vm.createContext({ console, performance: { now: () => clock } });
  function detection(quad, tracked) {
    return { present: tracked ? config.trackPresent : config.fullPresent, tracked, raw: 1, rejected: 0,
      quads: [quad], support: [0.9], cands: [{ quad, base: 0, support: 0.9 }], ms: { lsd: 0 } };
  }
  function card(mat, quad) {
    return { query: { accepted: quad[0][0] === 92 ? config.trackAccepted : config.fullAccepted, index: config.cardIndex }, delete() {} };
  }
  const stubs = {
    '../core/cv.js': { cv: {} },
    '../core/detect.js': {
      detectCandidates(mat, options) { calls.full.push({ mat, options: clone(options) }); return detection(clone(inner), false); },
      trackCandidates(_mat, seeds, options) { calls.track.push({ seeds: clone(seeds), options: clone(options) }); return config.trackPresent ? detection(shifted(inner, 2), true) : null; },
      fastQuad: () => null
    },
    '../core/warp.js': { warpCard: card, warpCardPair: (mat, quad) => [card(mat, quad), card(mat, quad)] },
    '../core/hash.js': { bh1: image => image.query },
    '../core/quality.js': { glareScore: () => 0 },
    '../core/localmatch.js': { GAP_MIN: 1.5, queryFromHex: query => query,
      matchFrames(_pack, frames) {
        calls.matches.push(clone(frames));
        const frame = frames.length - 1, query = frames[frame][0];
        return { accepted: query.accepted, gap: query.accepted ? 5 : 0, hint: 'retry', confidence: query.accepted ? 96 : 40,
          best: { i: query.index, frame, cand: 0, d: 1, match_pct: 99, confidence: 96, siblings: [] }, top: [] };
      }
    }
  };
  const modules = new Map();
  const file = path.join(runtime, 'app/scan-engine.js');
  const module = new vm.SourceTextModule(fs.readFileSync(file, 'utf8'), { context, identifier: file });
  await module.link(async specifier => {
    if (modules.has(specifier)) return modules.get(specifier);
    const exports = stubs[specifier];
    const dependency = exports ? new vm.SyntheticModule(Object.keys(exports), function () {
      for (const [key, value] of Object.entries(exports)) this.setExport(key, value);
    }, { context }) : new vm.SourceTextModule(fs.readFileSync(path.resolve(path.dirname(file), specifier), 'utf8'), { context });
    modules.set(specifier, dependency); await dependency.link(() => {}); return dependency;
  });
  await module.evaluate();
  const engine = module.namespace.createScanEngine();
  const pack = { n: 2, lo: new Uint32Array(), hi: new Uint8Array(), cl: new Int32Array([-1, -1]) };
  engine.setPack(pack);
  return { engine, config, calls, pack,
    scan(t, options = {}, dimensions = { cols: 320, rows: 448 }) { clock = t; return engine.scanMat(dimensions, options); }
  };
}

test('engine retries recent accepted coordinates with fresh current-frame matching and no fused history', async () => {
  const h = await engineHarness();
  const first = h.scan(0); assert.equal(first.result.accepted, true);
  const retried = h.scan(100, { reset: true, retainAcceptedBorder: true });
  assert.equal(retried.diagnostics.borderRetry, true); assert.equal(retried.diagnostics.borderRetained, true);
  assert.equal(retried.result.accepted, true); assert.equal(retried.tracked, true); assert.equal(retried.frames, 1);
  assert.equal(h.calls.full.length, 1, 'a freshly revalidated tracked card does not pay for unrelated full search');
  assert.equal(h.calls.matches.at(-1).length, 1, 'motion reset carries no prior image/hash votes');
  assert.deepEqual(h.calls.track[0], { seeds: [inner], options: { drift: 0.04 } });
  h.engine.dispose();
});

test('engine retention accepts the 650ms boundary but not expired, rewound or resized frames', async () => {
  for (const [time, dimensions, expected] of [[650, { cols: 320, rows: 448 }, true], [651, { cols: 320, rows: 448 }, false],
    [-1, { cols: 320, rows: 448 }, false], [100, { cols: 640, rows: 896 }, false]]) {
    const h = await engineHarness(); h.scan(0);
    const out = h.scan(time, { reset: true, retainAcceptedBorder: true }, dimensions);
    assert.equal(out.diagnostics.borderRetry === true, expected);
    assert.equal(h.calls.track.length, expected ? 1 : 0);
    h.engine.dispose();
  }
});

test('engine rejection or failed refit immediately searches the same frame normally', async () => {
  for (const changes of [{ trackAccepted: false }, { trackPresent: false }]) {
    const h = await engineHarness(); h.scan(0); Object.assign(h.config, changes);
    const out = h.scan(100, { reset: true, retainAcceptedBorder: true });
    assert.equal(out.diagnostics.borderRetry, true); assert.equal(out.diagnostics.borderRetained, false);
    assert.equal(out.tracked, false); assert.equal(out.result.accepted, true);
    assert.equal(h.calls.full.length, 2, 'fallback searches the current frame rather than waiting for another video frame');
    assert.equal(out.frames, 1); h.engine.dispose();
  }
});

test('a different freshly matched card cannot validate the previous accepted border preference', async () => {
  const h = await engineHarness(); h.scan(0); h.config.cardIndex = 1;
  const out = h.scan(100, { reset: true, retainAcceptedBorder: true });
  assert.equal(out.diagnostics.borderRetry, true); assert.equal(out.diagnostics.borderRetained, false);
  assert.equal(out.result.best.i, 1); assert.equal(h.calls.full.length, 2);
  assert.equal(out.tracked, false, 'replacement identification comes from normal search'); h.engine.dispose();
});

test('blank and ambiguous frames discard the accepted seed instead of extending its lifetime', async () => {
  for (const changes of [{ trackPresent: false, fullPresent: false }, { trackAccepted: false, fullAccepted: false }]) {
    const h = await engineHarness(); h.scan(0); Object.assign(h.config, changes);
    const failed = h.scan(100, { reset: true, retainAcceptedBorder: true });
    assert.equal(failed.result?.accepted === true, false);
    Object.assign(h.config, { trackPresent: true, fullPresent: true, trackAccepted: true, fullAccepted: true });
    const later = h.scan(200, { reset: true, retainAcceptedBorder: true });
    assert.equal(later.diagnostics.borderRetry, undefined, 'a failed attempt cannot keep an earlier accepted seed alive');
    h.engine.dispose();
  }
});

test('hard reset, pack replacement, allow-mask changes and disposal clear geometry retention', async () => {
  for (const action of [h => h.engine.reset(), h => h.engine.setPack(h.pack), h => h.engine.setAllow(new Uint8Array([1, 1])), h => h.engine.dispose()]) {
    const h = await engineHarness(); h.scan(0); action(h);
    const out = h.scan(100, { reset: true, retainAcceptedBorder: true });
    assert.equal(out.diagnostics.borderRetry, undefined); assert.equal(h.calls.track.length, 0); h.engine.dispose();
  }
});

test('engine keeps the original full-reset behavior unless retention is explicitly requested', async () => {
  const h = await engineHarness(); h.scan(0);
  const out = h.scan(100, { reset: true });
  assert.equal(out.diagnostics.borderRetry, undefined); assert.equal(h.calls.track.length, 0); assert.equal(h.calls.full.length, 2);
  h.engine.dispose();
});
