const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../CardShowScanner/Resources/TCGTrackingBridge.js'), 'utf8');
function deferred() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
function harness({ denyCamera = false, cacheState = 'ok', beforePackReady, acquireCamera, playVideo,
  cameraConstraintsSupported = false, applyCameraConstraints, cameraSettings } = {}) {
  const messages = [], elements = [], events = new Map(), windowEvents = new Map(), trackEvents = new Map(), draws = [];
  let overlayDestroyed = 0;
  const packOptions = [], cameraTracks = [], cameraConstraintCalls = [];
  const timers = new Map(), frames = new Map(); let scheduleID = 0;
  let captureOptions, scannerOptions, scannerStarts = 0, activeLoops = 0, cameraRequests = 0, stopped = 0, disposed = 0, now = 0;
  const element = tag => {
    const e = { tag, style: {}, children: [], append(...items) { this.children.push(...items); }, setAttribute() {},
      remove() { this.removed = true; }, async play() { await playVideo?.(); } };
    elements.push(e); return e;
  };
  const body = element('body');
  const document = { body, hidden: false, createElement: element,
    addEventListener(name, fn) { events.set(name, fn); }, removeEventListener(name) { events.delete(name); } };
  const backend = { setPack() {}, dispose() { disposed++; } };
  const modules = {
    'core/pack.js': { async loadPack(game, progress, options) {
      packOptions.push(options);
      if (game !== 'tcgp:3') throw new Error('No downloadable pack is available for this game.');
      progress(1, 1, { downloaded: 0, total: 0, cache: cacheState, cachedHashShards: 1, cachedMetaShards: 1, storage: { persisted: false } });
      await beforePackReady?.();
      return { game };
    } },
    'app/scan-backends.js': { createBackend: async () => backend },
    'core/overlay.js': { createOverlay: () => ({ draw(options) { draws.push(options); }, clear() {}, setSource() {}, destroy() { overlayDestroyed++; } }) },
    'app/quickscan.js': { startQuickScan(options) { scannerStarts++; activeLoops++; scannerOptions = options; let active = true; return () => { if (active) { active = false; activeLoops--; stopped++; } }; } },
    'app/shared.js': { useScope(scope) { assert.equal(scope, 'price'); }, catalogDetail() {} }
  };
  const sandbox = { URL, console, document, performance: { now: () => now },
    setTimeout(fn, delay) { const id = ++scheduleID; timers.set(id, { fn, delay }); return id; }, clearTimeout(id) { timers.delete(id); },
    requestAnimationFrame(fn) { const id = ++scheduleID; frames.set(id, fn); return id; }, cancelAnimationFrame(id) { frames.delete(id); },
    navigator: { mediaDevices: { async getUserMedia(options) {
      cameraRequests++; if (denyCamera) throw new Error("Camera permission denied"); captureOptions = options; await acquireCamera?.(options);
      const track = { kind: 'video', readyState: 'live', fps: options.video.frameRate?.ideal ?? 30,
        stop() { this.readyState = 'ended'; stopped++; }, addEventListener(name, fn) { trackEvents.set(name, fn); },
        getSettings() { return cameraSettings ? cameraSettings(this) : { frameRate: this.fps }; } };
      if (cameraConstraintsSupported || applyCameraConstraints) track.applyConstraints = async constraints => {
        cameraConstraintCalls.push({ track, constraints: clean(constraints) });
        await applyCameraConstraints?.(constraints, track);
        if (track.readyState !== 'ended') track.fps = constraints.frameRate.ideal;
      };
      cameraTracks.push(track);
      return { getTracks: () => [track], getVideoTracks: () => [track] };
    } } },
    window: { addEventListener(name, fn) { windowEvents.set(name, fn); }, removeEventListener(name) { windowEvents.delete(name); }, webkit: { messageHandlers: { scanResult: { postMessage: m => messages.push(JSON.parse(JSON.stringify(m))) } } } }
  };
  const context = vm.createContext(sandbox);
  const script = new vm.Script(source, { importModuleDynamically: async specifier => {
    const prefix = '/newscanplus/assets/js/'; assert.ok(specifier.startsWith(prefix));
    const exports = modules[specifier.slice(prefix.length)]; assert.ok(exports, specifier);
    const mod = new vm.SyntheticModule(Object.keys(exports), function () { for (const [k, v] of Object.entries(exports)) this.setExport(k, v); }, { context });
    await mod.link(() => {}); await mod.evaluate(); return mod;
  } });
  script.runInContext(context);
  return { bridge: sandbox.CardShowBridge, messages, elements, events, windowEvents, trackEvents, draws, document, timers, frames,
    flushTimers() { const pending = [...timers.values()]; timers.clear(); for (const timer of pending) timer.fn(); },
    flushFrames() { const pending = [...frames.values()]; frames.clear(); for (const frame of pending) frame(); },
    get overlayDestroyed() { return overlayDestroyed; }, advance(ms) { now += ms; },
    packOptions, cameraTracks, cameraConstraintCalls, get activeLoops() { return activeLoops; }, get scannerOptions() { return scannerOptions; }, get scannerStarts() { return scannerStarts; }, get cameraRequests() { return cameraRequests; }, get captureOptions() { return captureOptions; }, get stopped() { return stopped; }, get disposed() { return disposed; } };
}
const tuple = (id = 123, variants = [{ id: 10, label: 'Normal', nm: 1.25, primary: true }, { id: 11, label: 'Holofoil', nm: 2.5 }]) =>
  [`p:${id}`, `Sample ${id}`, '1/10', 'DEMO', 'Demo Set', '', 'https://cdn.tcgtracking.com/test.jpg', variants];
function settle(h, view) {
  h.scannerOptions.onShow(view);
  for (let i = 0; i < 2; i++) {
    h.advance(400);
    h.scannerOptions.onShow({ same: true, accepted: true, confidence: view.confidence });
  }
}
function removeObservedCard(h) {
  h.scannerOptions.onStats({ diagnostics: { solid: false } });
  h.advance(300); h.scannerOptions.onStats({ diagnostics: { solid: false } });
}
function clean(value) { return JSON.parse(JSON.stringify(value)); }
test('winner, candidate metadata and per-printing price/SKU survive', () => {
  const { bridge } = harness();
  const result = bridge.normalizeView({ ref: tuple(), confidence: 96, accepted: true, cands: [{ tuple: tuple(124), confidence: 75 }] });
  assert.equal(result.candidates.length, 2); assert.equal(result.candidates[0].ref, 'p:123');
  assert.equal(result.candidates[1].name, 'Sample 124');
  assert.equal(result.candidates[0].printings[1].marketPrice, 2.5);
  assert.equal(result.candidates[0].printings[1].skuID, '11');
});
test('same:true is a partial update, not a fresh card payload', () => {
  const { bridge } = harness();
  assert.deepEqual(clean(bridge.normalizeView({ same: true, accepted: true, confidence: 97 })), { kind: 'scan', same: true, accepted: true, confidence: 97 });
});
test('five-candidate limit and product deduplication', () => {
  const { bridge } = harness();
  const result = bridge.normalizeView({ ref: tuple(), cands: Array.from({ length: 12 }, (_, i) => ({ tuple: tuple(123 + i), confidence: 90 })) });
  assert.equal(result.candidates.length, 5); assert.equal(new Set(result.candidates.map(c => c.ref)).size, 5);
});
test('unknown prices remain null; unsafe image URLs are rejected', () => {
  const { bridge } = harness(); const card = tuple(123, [{ label: 'Normal', nm: null }]); card[6] = 'javascript:alert(1)';
  const result = bridge.normalizeView({ ref: card });
  assert.equal(result.candidates[0].marketPrice, null); assert.equal(result.candidates[0].imageURL, null);
});
test('invalid refs, numeric strings and nonfinite values are not trusted', () => {
  const { bridge } = harness(); const card = tuple(123, [{ label: 'Normal', nm: '0', id: 'not-a-sku' }]);
  const result = bridge.normalizeView({ ref: card, confidence: Infinity, accepted: 'true' });
  assert.equal(result.accepted, false); assert.equal(result.confidence, 0);
  assert.equal(result.candidates[0].marketPrice, null); assert.equal(result.candidates[0].skuID, null);
  card[0] = 'bad'; assert.equal(bridge.normalizeView({ ref: card }).candidates.length, 0);
});
test('ambiguous printing is explicitly carried to native confirmation', () => {
  const { bridge } = harness();
  assert.equal(bridge.normalizeView({ ref: tuple(), printing: { state: 'ambiguous' } }).candidates[0].requiresPrintingSelection, true);
});
test('camera bootstrap uses module interfaces and delivers scan/hide with nonce', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'test-nonce', game: 'tcgp:3' });
  const button = h.elements.find(e => e.tag === 'button'); await button.onclick();
  assert.equal(h.captureOptions.audio, false); assert.equal(h.captureOptions.video.facingMode.ideal, 'environment');
  assert.ok(h.scannerOptions); assert.equal(button.hidden, true);
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).kind, 'scan'); assert.equal(h.messages.at(-1).nonce, 'test-nonce');
  h.scannerOptions.onHide(); assert.equal(h.messages.at(-1).kind, 'scan');
  h.bridge.releaseReview();
  removeObservedCard(h); assert.equal(h.messages.at(-1).kind, 'hide');
  h.bridge.stop(); assert.ok(h.stopped >= 2); assert.equal(h.disposed, 1);
  const count = h.messages.length; h.scannerOptions.onShow({ ref: tuple() }); assert.equal(h.messages.length, count);
});
test('automatic startup keeps page controls hidden while loading and waiting for playback', { timeout: 5000 }, async () => {
  const packEntered = deferred(), releasePack = deferred(), playEntered = deferred(), releasePlay = deferred();
  const h = harness({
    beforePackReady() { packEntered.resolve(); return releasePack.promise; },
    playVideo() { playEntered.resolve(); return releasePlay.promise; }
  });
  const startup = h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  await packEntered.promise;
  const button = h.elements.find(e => e.tag === 'button');
  const root = h.elements.find(e => e.tag === 'section'), hint = root.children.at(-1);
  assert.equal(button.hidden, true, 'native progress is the only startup control');
  assert.equal(hint.hidden, true, 'page status must not cover native camera UI');
  assert.equal(h.captureOptions, undefined, 'database loading remains before camera capture');
  releasePack.resolve();
  await playEntered.promise;
  assert.equal(button.hidden, true);
  assert.equal(hint.hidden, true);
  assert.equal(h.scannerStarts, 0, 'recognition waits for playback to finish');
  assert.equal(h.messages.some(m => m.event === 'scanner_ready'), false);
  releasePlay.resolve();
  await startup;
  assert.equal(h.scannerStarts, 1);
  assert.equal(h.messages.filter(m => m.event === 'scanner_ready').length, 1);
  assert.equal(button.hidden, true);
  assert.equal(hint.hidden, true);
  h.bridge.stop();
});
test('automatic startup failure exposes an enabled retry button', { timeout: 5000 }, async () => {
  const packEntered = deferred(), releasePack = deferred();
  const h = harness({ beforePackReady() { packEntered.resolve(); return releasePack.promise; } });
  const startup = h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  await packEntered.promise;
  const button = h.elements.find(e => e.tag === 'button');
  assert.equal(button.hidden, true);
  releasePack.reject(new Error('Saved database could not be opened'));
  await startup;
  assert.equal(button.hidden, false);
  assert.equal(button.disabled, false);
  assert.equal(button.textContent, 'Retry Scanner');
  assert.equal(h.scannerStarts, 0);
  assert.equal(h.messages.some(m => m.event === 'scanner_ready'), false);
  assert.match(h.messages.at(-1).message, /Saved database could not be opened/);
  h.bridge.stop();
});
for (const action of ['stop', 'background']) {
  test(`${action} during pending playback releases capture without starting recognition`, { timeout: 5000 }, async () => {
    const playEntered = deferred(), releasePlay = deferred();
    const h = harness({ playVideo() { playEntered.resolve(); return releasePlay.promise; } });
    const startup = h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
    await playEntered.promise;
    const video = h.elements.find(e => e.tag === 'video');
    assert.ok(video.srcObject, 'capture was acquired before playback completed');
    if (action === 'stop') h.bridge.stop();
    else { h.document.hidden = true; h.events.get('visibilitychange')(); }
    assert.equal(video.srcObject, null);
    assert.equal(h.stopped, 1, 'the acquired track stops before playback resolves');
    releasePlay.resolve();
    await startup;
    assert.equal(h.scannerStarts, 0);
    assert.equal(h.messages.some(m => m.event === 'video_playing' || m.event === 'scanner_ready'), false);
    assert.equal(h.messages.some(m => m.kind === 'scan'), false);
    assert.equal(video.srcObject, null);
    assert.equal(h.stopped, 1, 'late playback cannot reopen capture');
    if (action === 'background') h.bridge.stop();
  });
}
test('backgrounding releases camera and invalidates displayed recognition', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3' });
  await h.elements.find(e => e.tag === 'button').onclick();
  h.document.hidden = true; h.events.get('visibilitychange')();
  assert.ok(h.stopped >= 2); assert.equal(h.messages.at(-1).kind, 'hide');
  h.bridge.stop(); assert.equal(h.events.size, 0);
});
test('missing game pack produces retry state without a recognition result', async () => {
  const h = harness();
  await h.bridge.install({ nonce: 'n', game: 'unknown' });
  const button = h.elements.find(e => e.tag === 'button'); await button.onclick();
  assert.equal(button.disabled, false); assert.equal(button.textContent, 'Retry Scanner');
  assert.match(h.messages.at(-1).message, /No downloadable pack/);
  assert.equal(h.messages.some(m => m.kind === 'scan'), false);
});

test('camera denial is recoverable and never emits an inventory result', async () => {
  const h = harness({ denyCamera: true });
  await h.bridge.install({ nonce: 'n', game: 'tcgp:3' });
  const button = h.elements.find(e => e.tag === 'button'); await button.onclick();
  assert.equal(button.disabled, false); assert.equal(button.textContent, 'Retry Scanner');
  assert.match(h.messages.at(-1).message, /Camera permission denied/);
  assert.equal(h.messages.some(m => m.kind === 'scan'), false);
  assert.ok(h.disposed > 0);
});

test('diagnostics report startup stages, sampled timings and safe camera errors', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3' });
  await h.elements.find(e => e.tag === 'button').onclick();
  const diagnostics = () => h.messages.filter(m => m.kind === 'diagnostic');
  for (const event of ['bridge_ready', 'modules_ready', 'pack_ready', 'backend_ready', 'camera_requested', 'camera_acquired', 'video_playing', 'scanner_ready']) {
    assert.ok(diagnostics().some(m => m.event === event), event);
  }
  for (let i = 0; i < 20; i++) h.scannerOptions.onStats({ kind: 'worker', scanMs: 42, captureMs: 3, frames: 2 });
  const stats = diagnostics().filter(m => m.event === 'scan_stats');
  assert.equal(stats.length, 1); assert.equal(stats[0].scanMS, 42);
  const denied = harness({ denyCamera: true }); await denied.bridge.install({ nonce: 'n', game: 'tcgp:3' });
  await denied.elements.find(e => e.tag === 'button').onclick();
  const failure = denied.messages.find(m => m.kind === 'diagnostic' && m.event === 'startup_failed');
  assert.equal(failure.stage, 'camera'); assert.equal(failure.errorKind, 'Error');
  assert.equal('message' in failure, false);
  settle(h, { ref: tuple(), confidence: 96, accepted: true });
  assert.ok(h.messages.some(m => m.kind === 'scan' && m.candidates[0].name === 'Sample 123'));
  assert.equal(JSON.stringify(diagnostics()).includes('Sample 123'), false);
});

test('review freezes full payload, including captured image, until explicitly released', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  assert.ok(h.scannerOptions, 'local scanner starts without a mock or website button');
  settle(h, { ref: tuple(), accepted: true, confidence: 96, thumb: 'data:image/jpeg;base64,/9j/AA==' });
  const first = h.messages.at(-1);
  assert.equal(first.capturedImageBase64, '/9j/AA==');
  const count = h.messages.length;
  settle(h, { ref: tuple(124), confidence: 99 });
  h.scannerOptions.onHide(); assert.equal(h.messages.length, count);
  h.bridge.resetRecognition();
  settle(h, { ref: tuple(124), confidence: 99 });
  assert.equal(h.messages.at(-1).candidates[0].ref, 'p:124');
});
test('recognition does not depend on the online catalog detail callback', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  assert.equal(h.scannerOptions.fetchDetails, null);
  assert.equal(h.scannerOptions.resolveCandidates, false);
});

test('saving waits for card removal instead of latching a duplicate frame', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  h.bridge.releaseReview();
  const count = h.messages.length;
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.length, count);
  removeObservedCard(h); assert.equal(h.messages.at(-1).kind, 'hide');
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).kind, 'scan');
});

test('a different accepted card settles after saving without requiring an upstream hide', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  // The loop may see the replacement while native confirmation still owns A.
  settle(h, { ref: tuple(124), accepted: true, confidence: 96 });
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, 1);
  h.bridge.releaseReview();
  assert.equal(h.scannerStarts, 2, 'saving re-arms complete candidate snapshots');
  assert.equal(h.messages.filter(m => m.event === 'camera_acquired').length, 1, 'the same camera stream is retained');
  const count = h.messages.length;
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.length, count, 'repeat frames of the saved card stay blocked');
  h.scannerOptions.onShow({ ref: tuple(124), accepted: true, confidence: 96 });
  h.advance(400); h.scannerOptions.onShow({ same: true, accepted: true, confidence: 96 });
  assert.equal(h.messages.length, count, 'a replacement still requires the existing settling gate');
  h.advance(400); h.scannerOptions.onShow({ same: true, accepted: true, confidence: 96 });
  const deliveries = h.messages.slice(count).filter(m => m.kind === 'scan' || m.kind === 'hide');
  assert.deepEqual(deliveries.map(m => m.kind), ['hide', 'scan']);
  assert.equal(deliveries[1].candidates[0].ref, 'p:124');
  const savedCount = h.messages.length;
  settle(h, { ref: tuple(124), accepted: true, confidence: 96 });
  assert.equal(h.messages.length, savedCount, 'the new review freezes after one delivery');
});

test('saved references, partial-only updates and weak guesses cannot release the saved-card wait', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  h.bridge.releaseReview();
  h.bridge.releaseReview();
  assert.equal(h.scannerStarts, 2, 'duplicate release does not reset the saved identity');
  const count = h.messages.length;
  h.scannerOptions.onHide();
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.length, count, 'a transient hide is not proof the saved physical card was removed');
  for (let i = 0; i < 5; i++) {
    h.scannerOptions.onShow({ same: true, accepted: true, confidence: 96 });
    h.scannerOptions.onShow({ ref: tuple(124), accepted: false, confidence: 49 });
    h.advance(400); h.scannerOptions.onShow({ same: true, accepted: true, confidence: 96 });
  }
  assert.equal(h.messages.length, count);
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.length, count);
});

test('a different tentative card uses the normal slower settling gate after saving', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  h.bridge.releaseReview();
  const count = h.messages.length;
  h.scannerOptions.onShow({ ref: tuple(124), accepted: false, confidence: 90 });
  for (let i = 0; i < 3; i++) {
    h.advance(400); h.scannerOptions.onShow({ same: true, accepted: false, confidence: 90 });
  }
  assert.equal(h.messages.length, count, 'a tentative replacement cannot use the faster accepted gate');
  h.advance(400); h.scannerOptions.onShow({ same: true, accepted: false, confidence: 90 });
  const deliveries = h.messages.slice(count).filter(m => m.kind === 'scan' || m.kind === 'hide');
  assert.deepEqual(deliveries.map(m => m.kind), ['hide', 'scan']);
  assert.equal(deliveries[1].candidates[0].ref, 'p:124');
  assert.equal(deliveries[1].accepted, false);
  assert.equal(h.scannerStarts, 2, 'a settled different card needs no further loop reset');
  assert.equal(h.messages.filter(m => m.event === 'camera_acquired').length, 1);
});

test('actual no-solid samples re-arm an identical copy after the saved-card loop reset', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  h.bridge.releaseReview();
  const deliveries = () => h.messages.filter(m => m.kind === 'scan' || m.kind === 'hide');
  const count = deliveries().length;
  const starts = h.scannerStarts;
  h.scannerOptions.onStats({ diagnostics: { solid: false } });
  h.advance(200); h.scannerOptions.onStats({ diagnostics: { solid: false } });
  assert.equal(deliveries().length, count);
  h.scannerOptions.onStats(borderStats());
  h.advance(400); h.scannerOptions.onStats({ diagnostics: { solid: false } });
  h.advance(299); h.scannerOptions.onStats({ diagnostics: { solid: false } });
  assert.equal(deliveries().length, count, 'brief misses do not release a saved card');
  h.advance(1); h.scannerOptions.onStats({ diagnostics: { solid: false } });
  assert.equal(h.messages.at(-1).kind, 'hide');
  assert.equal(h.scannerStarts, starts + 1, 'verified absence clears upstream same-art state');
  h.scannerOptions.onStats({ diagnostics: { solid: false } });
  assert.equal(h.scannerStarts, starts + 1, 'one physical boundary rearms the loop only once');
  assert.equal(h.messages.filter(m => m.event === 'camera_acquired').length, 1, 'rearming retains the authorized camera');
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).kind, 'scan');
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, 2);
});

test('native frozen recognition identity survives a restarted camera before save completes', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'first', game: 'tcgp:3', autoStart: true });
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  await h.bridge.install({ nonce: 'restarted', game: 'tcgp:3', autoStart: true });
  h.bridge.releaseReview('p:123');
  const count = h.messages.length;
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.length, count, 'a saved native review cannot be presented again after restart');
  settle(h, { ref: tuple(124), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).kind, 'scan');
  assert.equal(h.messages.at(-1).nonce, 'restarted');
  assert.equal(h.messages.at(-1).candidates[0].ref, 'p:124');
});

 test('a corrected first guess must settle before presenting candidates', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.onShow({ ref: tuple(123), accepted: true, confidence: 95 });
  h.advance(400);
  h.scannerOptions.onShow({ ref: tuple(124), accepted: true, confidence: 96 });
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, 0);
  h.advance(400); h.scannerOptions.onShow({ same: true, accepted: true, confidence: 97 });
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, 0);
  h.advance(400); h.scannerOptions.onShow({ same: true, accepted: true, confidence: 98 });
  assert.equal(h.messages.at(-1).candidates[0].ref, 'p:124');
});
test('low confidence and removed cards cannot open a stale review', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.onShow({ ref: tuple(), accepted: false, confidence: 30 });
  for (let i = 0; i < 6; i++) { h.advance(400); h.scannerOptions.onShow({ same: true, accepted: false, confidence: 30 }); }
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, 0);
  h.scannerOptions.onHide();
  h.advance(800); h.scannerOptions.onShow({ same: true, accepted: true, confidence: 98 });
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, 0);
  settle(h, { ref: tuple(124), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).candidates[0].ref, 'p:124');
});
test('stable ambiguous results remain selectable after a longer settling period', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.onShow({ ref: tuple(), accepted: false, confidence: 65, cands: [{ tuple: tuple(124), confidence: 60 }] });
  for (let i = 0; i < 3; i++) { h.advance(400); h.scannerOptions.onShow({ same: true, accepted: false, confidence: 65 }); }
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, 0);
  h.advance(400); h.scannerOptions.onShow({ same: true, accepted: false, confidence: 65 });
  assert.equal(h.messages.at(-1).accepted, false);
  assert.equal(h.messages.at(-1).candidates.length, 2);
});

test('tentative card names and prices never flash over the live camera', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.overlay.draw({ state: 'matched', quad: [1, 2], label: { name: 'Wrong guess', price: 100 } });
  assert.equal(h.draws.at(-1).label, null);
  assert.equal(h.draws.at(-1).state, 'matched');
  h.bridge.stop(); assert.equal(h.overlayDestroyed, 1);
  assert.equal(h.windowEvents.size, 0);
});
test('a camera interruption offers retry and releases its resources', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.trackEvents.get('ended')();
  const button = h.elements.find(e => e.tag === 'button');
  assert.equal(button.textContent, 'Retry Scanner'); assert.equal(button.hidden, false);
  assert.equal(h.overlayDestroyed, 1); assert.ok(h.stopped >= 2);
  await button.onclick(); assert.equal(button.hidden, true);
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).kind, 'scan');
});
test('a rejected scanner operation stops the loop and offers explicit retry', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.windowEvents.get('unhandledrejection')({ reason: new TypeError('private details') });
  assert.equal(h.elements.find(e => e.tag === 'button').textContent, 'Retry Scanner');
  assert.equal(h.messages.some(m => JSON.stringify(m).includes('private details')), false);
  assert.equal(h.overlayDestroyed, 1);
});

test('a slow frame restarts settling without losing the candidate payload', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.onShow({ ref: tuple(), accepted: true, confidence: 96 });
  h.advance(2000); h.scannerOptions.onShow({ same: true, accepted: true, confidence: 96 });
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, 0);
  for (let i = 0; i < 2; i++) { h.advance(400); h.scannerOptions.onShow({ same: true, accepted: true, confidence: 96 }); }
  assert.equal(h.messages.at(-1).candidates[0].ref, 'p:123');
});

test('camera startup prefers a saved database and reports actual cache use', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  assert.equal(h.packOptions[0].cacheFirst, true);
  const ready = h.messages.find(m => m.event === 'pack_ready');
  assert.equal(ready.downloadedBytes, 0); assert.equal(ready.cachedShards, 2);
  assert.equal(ready.cacheSource, 'cache'); assert.equal(ready.cacheState, 'ok');
  assert.ok(h.messages.some(m => m.kind === 'status' && m.message === 'Using saved game database'));
  assert.equal(h.messages.some(m => m.kind === 'status' && m.message.startsWith('Downloading database')), false);
  await h.bridge.refreshDatabase();
  assert.equal(h.packOptions[1].cacheFirst, false, 'only explicit updates check remote versions');
});
test('cache failures are visible and explicit updates cannot discard a held review', async () => {
  const h = harness({ cacheState: 'failed' });
  await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  assert.ok(h.messages.some(m => m.event === 'pack_cache_warning' && m.cacheState === 'failed'));
  assert.ok(h.messages.some(m => m.kind === 'status' && m.message.includes('could not be saved')));
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  await h.bridge.refreshDatabase();
  assert.equal(h.packOptions.length, 1);
});

const borderStats = (overrides = {}) => ({
  kind: 'worker', scanMs: 42, captureMs: 1, frames: 1, stage: 'one', tracked: false,
  diagnostics: { solid: true, tracked: false, scanStage: 'one', rawQuads: 7, rejectedQuads: 2,
    candidateQuads: 3, selectedBase: 1, quadSource: 'selected', quadAspect: 0.716,
    quadArea: 0.4, quadSupport: 0.97, matchDistance: 4.125, matchGap: 3.25 },
  ...overrides
});
test('border diagnostics forward only bounded scalars and sample frame quality every five seconds', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  let qualityReads = 0;
  const stats = borderStats({ frameQuality() { qualityReads++; return { meanLuma: 31.12345, lumaStd: 12.5, solid: false, image: 'private-image' }; } });
  for (let i = 0; i < 10; i++) h.scannerOptions.onStats(stats);
  assert.equal(qualityReads, 1);
  const first = h.messages.filter(m => m.event === 'scan_stats');
  assert.equal(first.length, 1);
  assert.equal(first[0].solid, true, 'quality sampling cannot replace detection metadata');
  assert.equal(first[0].quadSource, 'selected'); assert.equal(first[0].quadAspect, 0.716);
  assert.equal(first[0].candidateQuads, 3); assert.equal(first[0].selectedBase, 1);
  assert.equal(first[0].meanLuma, 31.123); assert.equal(first[0].lumaStd, 12.5);
  assert.equal(JSON.stringify(first).includes('private-image'), false);
  h.advance(5000); h.scannerOptions.onStats(stats);
  assert.equal(qualityReads, 2);
  assert.equal(h.messages.filter(m => m.event === 'scan_stats').length, 2);
});
test('malformed oversized and nonfinite diagnostic values never cross the bridge', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.onStats({ kind: 'private-kind', scanMs: Infinity, captureMs: -1, frames: 1.5, stage: 'private-stage', tracked: 'true', diagnostics: {
    solid: 'true', tracked: 1, scanStage: 'private-stage', quadSource: 'private-source',
    rawQuads: 1000001, rejectedQuads: -1, candidateQuads: 1.5, selectedBase: '1',
    quadAspect: 1.01, quadArea: -0.1, quadSupport: Infinity, meanLuma: 256, lumaStd: 129,
    matchDistance: NaN, matchGap: 101, ref: 'p:123', image: 'private-image', token: 'private-token'
  } });
  assert.equal(h.messages.filter(m => m.event === 'scan_stats').length, 0);
  h.scannerOptions.onStats(null); h.scannerOptions.onStats([]);
  h.scannerOptions.onStats(borderStats({ frameQuality() { throw new Error('private failure'); } }));
  assert.equal(h.messages.filter(m => m.event === 'scan_stats').length, 1);
  assert.equal(JSON.stringify(h.messages.filter(m => m.kind === 'diagnostic')).includes('private'), false);
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).kind, 'scan', 'diagnostic failures cannot interrupt recognition');
});
test('issue marker uses the newest stats even when their sampled log was suppressed', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.onStats(borderStats());
  h.advance(1000);
  h.scannerOptions.onStats(borderStats({ diagnostics: { solid: false, scanStage: 'none', rawQuads: 0, rejectedQuads: 0, candidateQuads: 0, quadSource: 'none' }, stage: '', frames: 0 }));
  h.advance(25);
  const stopped = h.stopped, disposed = h.disposed;
  assert.equal(h.bridge.markScanIssue('top_loader'), true);
  const marker = h.messages.at(-1);
  assert.equal(marker.event, 'scan_issue'); assert.equal(marker.issueReason, 'top_loader');
  assert.equal(marker.sampleAgeMS, 25); assert.equal(marker.solid, false);
  assert.equal(marker.quadSource, 'none'); assert.equal(marker.candidateQuads, 0);
  assert.equal(h.messages.filter(m => m.event === 'scan_stats').length, 1);
  assert.equal(h.stopped, stopped); assert.equal(h.disposed, disposed);
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, 0);
});
test('recognition snapshot and issue markers retain frozen review geometry', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.onStats(borderStats());
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  const frozen = h.messages.at(-1);
  const snapshot = h.messages.find(m => m.event === 'recognition_snapshot');
  assert.equal(snapshot.quadArea, 0.4); assert.equal(snapshot.selectedBase, 1); assert.equal(snapshot.sampleAgeMS, 800);
  h.advance(1000);
  h.scannerOptions.onStats(borderStats({ diagnostics: { solid: true, quadSource: 'selected', quadArea: 0.8, selectedBase: 0 }, stage: 'full' }));
  assert.equal(h.bridge.markScanIssue('wrong_border'), true);
  const marker = h.messages.at(-1);
  assert.equal(marker.quadArea, 0.4); assert.equal(marker.selectedBase, 1); assert.equal(marker.sampleAgeMS, 1800);
  assert.equal(marker.scanStage, 'one');
  settle(h, { ref: tuple(124), accepted: true, confidence: 99 });
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, 1);
  assert.deepEqual(h.messages.find(m => m.kind === 'scan'), frozen, 'marking an issue neither changes nor releases a held review');
});
test('issue marker reports missing or stale metadata without inventing current geometry', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  assert.equal(h.bridge.markScanIssue('dark_card'), true);
  assert.deepEqual(h.messages.at(-1), { kind: 'diagnostic', event: 'scan_issue', issueReason: 'dark_card', nonce: 'n' });
  h.scannerOptions.onStats(borderStats()); h.advance(15001);
  assert.equal(h.bridge.markScanIssue('top_loader'), true);
  assert.deepEqual(h.messages.at(-1), { kind: 'diagnostic', event: 'scan_issue', issueReason: 'top_loader', sampleAgeMS: 15001, nonce: 'n' });
  h.advance(900000); assert.equal(h.bridge.markScanIssue('wrong_border'), true);
  assert.equal(h.messages.at(-1).sampleAgeMS, 600000);
  assert.equal('quadArea' in h.messages.at(-1), false);
});
test('issue markers reject unknown reasons and cannot start an absent or stopped camera', async () => {
  const h = harness();
  assert.equal(h.bridge.markScanIssue('top_loader'), false);
  await h.bridge.install({ nonce: 'n', game: 'tcgp:3' });
  assert.equal(h.bridge.markScanIssue('top_loader'), false);
  await h.elements.find(e => e.tag === 'button').onclick();
  let count = h.messages.length;
  for (const reason of ['private-reason', 'top_loader\nprivate', '', null, 1, {}, ['top_loader']]) assert.equal(h.bridge.markScanIssue(reason), false);
  assert.equal(h.messages.length, count);
  assert.equal(h.bridge.markScanIssue('top_loader'), true);
  h.bridge.stop(); count = h.messages.length;
  assert.equal(h.bridge.markScanIssue('top_loader'), false); assert.equal(h.messages.length, count);
});

const manualSuggestions = h => h.messages.filter(m => m.kind === 'manualSearchSuggested');
async function observeSolidCard(h, milliseconds = 500) {
  h.advance(milliseconds); h.scannerOptions.onStats(borderStats()); await Promise.resolve();
}
async function waitOnCard(h) {
  h.scannerOptions.onStats(borderStats());
  for (let i = 0; i < 8; i++) await observeSolidCard(h);
}
test('manual search is offered after four seconds of observed card presence, never empty camera time', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.advance(20000);
  h.scannerOptions.onStats({ diagnostics: { solid: false } }); await Promise.resolve();
  assert.equal(manualSuggestions(h).length, 0);
  h.scannerOptions.onStats(borderStats());
  for (let i = 0; i < 7; i++) await observeSolidCard(h);
  assert.equal(manualSuggestions(h).length, 0);
  await observeSolidCard(h, 499); assert.equal(manualSuggestions(h).length, 0);
  await observeSolidCard(h, 1);
  assert.deepEqual(manualSuggestions(h), [{ kind: 'manualSearchSuggested', nonce: 'n' }]);
  for (let i = 0; i < 10; i++) await observeSolidCard(h);
  assert.equal(manualSuggestions(h).length, 1, 'one offer for the same unresolved card');
});
test('brief movement retains the four-second attempt but sustained absence starts another', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  const outline = { quad: [[0, 0], [70, 0], [70, 100], [0, 100]], state: 'searching' };
  h.scannerOptions.overlay.draw(outline);
  for (let i = 0; i < 4; i++) await observeSolidCard(h);
  h.scannerOptions.onHide(); h.advance(800); h.scannerOptions.overlay.draw(outline);
  await observeSolidCard(h, 700); await observeSolidCard(h, 500);
  assert.equal(manualSuggestions(h).length, 1, 'short tracking loss does not restart the clock');
  h.bridge.resumeAfterManualSearchPrompt();
  h.scannerOptions.onHide(); h.advance(1200);
  h.scannerOptions.overlay.draw(outline);
  for (let i = 0; i < 7; i++) await observeSolidCard(h);
  assert.equal(manualSuggestions(h).length, 1);
  await observeSolidCard(h);
  assert.equal(manualSuggestions(h).length, 2, 'a later physical attempt can offer search');
});
test('a pending manual prompt blocks scan/hide delivery and Keep Scanning does not nag for the same attempt', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  await waitOnCard(h);
  const count = h.messages.length;
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  h.scannerOptions.onHide();
  assert.equal(h.messages.length, count, 'the popup cannot race a new confirmation sheet');
  h.bridge.resumeAfterManualSearchPrompt();
  assert.equal(h.scannerStarts, 2, 'Keep Scanning rearms full candidate payloads after suppressed same:true results');
  assert.equal(h.messages.filter(m => m.event === 'camera_acquired').length, 1, 'resuming uses the existing camera stream');
  for (let i = 0; i < 8; i++) await observeSolidCard(h);
  assert.equal(manualSuggestions(h).length, 1);
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).kind, 'scan', 'recognition resumes after the explicit choice');
});
test('a settled recognition wins over a timeout queued by the same scan callback', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.onStats(borderStats());
  for (let i = 0; i < 6; i++) await observeSolidCard(h);
  h.advance(200); h.scannerOptions.onShow({ ref: tuple(), accepted: true, confidence: 96 });
  h.advance(400); h.scannerOptions.onShow({ same: true, accepted: true, confidence: 96 });
  h.advance(400); h.scannerOptions.onStats(borderStats());
  h.scannerOptions.onShow({ same: true, accepted: true, confidence: 96 });
  await Promise.resolve();
  assert.equal(manualSuggestions(h).length, 0);
  assert.equal(h.messages.at(-1).kind, 'scan');
});
test('held confirmation and saved-card removal wait never trigger manual search', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.onStats(borderStats());
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  for (let i = 0; i < 12; i++) await observeSolidCard(h);
  assert.equal(manualSuggestions(h).length, 0);
  h.bridge.releaseReview();
  for (let i = 0; i < 12; i++) await observeSolidCard(h);
  assert.equal(manualSuggestions(h).length, 0);
  removeObservedCard(h); await waitOnCard(h);
  assert.equal(manualSuggestions(h).length, 1);
});
test('reset, background and stop cancel queued timeout work and clear prior prompt state', async () => {
  for (const action of ['reset', 'background', 'stop']) {
    const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
    h.scannerOptions.onStats(borderStats());
    for (let i = 0; i < 7; i++) await observeSolidCard(h);
    h.advance(500); h.scannerOptions.onStats(borderStats());
    if (action === 'reset') h.bridge.resetRecognition();
    else if (action === 'background') { h.document.hidden = true; h.events.get('visibilitychange')(); }
    else h.bridge.stop();
    await Promise.resolve();
    assert.equal(manualSuggestions(h).length, 0, action);
    if (action === 'reset') {
      await waitOnCard(h); assert.equal(manualSuggestions(h).length, 1, 'explicit Scan Next starts a fresh attempt');
    }
  }
});

test('steady border preference reaches scanning and can change without reopening the camera', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true, steadyCardBorder: true });
  assert.equal(h.scannerOptions.retainAcceptedBorder, true);
  h.bridge.setSteadyCardBorder(false);
  assert.equal(h.scannerOptions.retainAcceptedBorder, false);
  assert.equal(h.messages.filter(m => m.event === 'camera_acquired').length, 1);
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  h.bridge.setSteadyCardBorder(true);
  assert.equal(h.scannerOptions.retainAcceptedBorder, false, 'changing a preference cannot interrupt a frozen review');
  h.bridge.releaseReview();
  h.bridge.setSteadyCardBorder(true);
  assert.equal(h.scannerOptions.retainAcceptedBorder, true);
  const count = h.messages.filter(m => m.kind === 'scan').length;
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.filter(m => m.kind === 'scan').length, count, 'changing the preference does not re-add the saved card');
  h.bridge.stop();
});

test('border retry diagnostics retain booleans without copying candidate or image data', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true, steadyCardBorder: true });
  h.scannerOptions.onStats({ diagnostics: { borderRetry: true, borderRetained: false, image: 'PRIVATE_IMAGE', ref: 'PRIVATE_CARD' } });
  const event = h.messages.find(m => m.event === 'border_retry');
  assert.equal(event.borderRetry, true); assert.equal(event.borderRetained, false);
  assert.equal(JSON.stringify(event).includes('PRIVATE_'), false);
  const count = h.messages.filter(m => m.event === 'border_retry').length;
  h.scannerOptions.onStats({ diagnostics: { borderRetry: 'true', borderRetained: 'PRIVATE_BOOL' } });
  assert.equal(h.messages.filter(m => m.event === 'border_retry').length, count);
  h.bridge.stop();
});

test('manual entry keeps the camera, document, pack and backend warm and retires old worker callbacks', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'warm', game: 'tcgp:3', autoStart: true });
  const oldLoop = h.scannerOptions, root = h.elements.find(e => e.tag === 'section');
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  const scans = () => h.messages.filter(m => m.kind === 'scan').length;
  const before = scans(), disposed = h.disposed, cameras = h.cameraRequests;
  assert.equal(h.bridge.suspendForManualSearch('warm'), true);
  oldLoop.onShow({ ref: tuple(999), accepted: true, confidence: 96 });
  oldLoop.onHide();
  assert.equal(scans(), before);
  await h.bridge.resumeAfterManualSearch('warm');
  assert.equal(h.packOptions.length, 1); assert.equal(h.cameraRequests, cameras);
  assert.equal(h.disposed, disposed); assert.equal(root.removed, undefined);
  // A result already in flight from the retired loop cannot contaminate the
  // fresh settling window, even once the manual screen has been dismissed.
  oldLoop.onShow({ ref: tuple(999), accepted: true, confidence: 96 });
  const messageCount = h.messages.length;
  oldLoop.onHide(); oldLoop.onHint('Retired worker hint'); oldLoop.overlay.draw({ quad: [[0, 0]] });
  assert.equal(h.messages.length, messageCount);
  assert.equal(scans(), before);
  settle(h, { ref: tuple(124), accepted: true, confidence: 96 });
  assert.equal(scans(), before + 1); assert.equal(h.messages.at(-1).candidates[0].ref, 'p:124');
  h.bridge.stop();
});

test('opening manual entry during pack startup defers camera and resumes without loading the pack twice', async () => {
  const pack = deferred(), entered = deferred();
  const h = harness({ beforePackReady: () => { entered.resolve(); return pack.promise; } });
  const startup = h.bridge.install({ nonce: 'early', game: 'tcgp:3', autoStart: true });
  await entered.promise;
  h.bridge.suspendForManualSearch('early'); pack.resolve(); await startup;
  assert.equal(h.cameraRequests, 0); assert.equal(h.scannerStarts, 0);
  await h.bridge.resumeAfterManualSearch('early');
  assert.equal(h.packOptions.length, 1); assert.equal(h.cameraRequests, 1); assert.equal(h.scannerStarts, 1);
  h.bridge.stop();
});

test('a pause carried into installation prevents initial camera startup until manual dismissal', async () => {
  const h = harness();
  await h.bridge.install({ nonce: 'initial', game: 'tcgp:3', autoStart: true, manualSearchSuspended: true });
  assert.equal(h.cameraRequests, 0); assert.equal(h.packOptions.length, 1);
  await h.bridge.resumeAfterManualSearch('initial');
  assert.equal(h.packOptions.length, 1); assert.equal(h.scannerStarts, 1);
  h.bridge.stop();
});

test('a rapid manual open and dismissal while playback is pending retires the old capture then resumes once', async () => {
  for (const abort of [false, true]) {
    const video = deferred(), entered = deferred(); let plays = 0;
    const h = harness({ playVideo: () => { if (++plays === 1) { entered.resolve(); return video.promise; } } });
    const startup = h.bridge.install({ nonce: 'playback', game: 'tcgp:3', autoStart: true });
    await entered.promise;
    h.bridge.suspendForManualSearch('playback');
    await h.bridge.resumeAfterManualSearch('playback');
    if (abort) video.reject(Object.assign(new Error('Retired playback'), { name: 'AbortError' }));
    else video.resolve();
    await startup;
    assert.equal(h.packOptions.length, 1); assert.equal(h.cameraRequests, 2); assert.equal(h.scannerStarts, 1);
    h.bridge.stop();
  }
});

test('background and terminal stop while manual entry is open cannot warm-resume capture', async () => {
  for (const action of ['background', 'stop']) {
    const h = harness(); await h.bridge.install({ nonce: 'retired', game: 'tcgp:3', autoStart: true });
    h.bridge.suspendForManualSearch('retired');
    if (action === 'background') { h.document.hidden = true; h.events.get('visibilitychange')(); }
    else h.bridge.stop();
    const starts = h.scannerStarts, cameras = h.cameraRequests;
    assert.equal(await h.bridge.resumeAfterManualSearch('retired'), action === 'background');
    assert.equal(h.scannerStarts, starts); assert.equal(h.cameraRequests, cameras);
    if (action === 'background') h.bridge.stop();
  }
});

test('manual dismissal while WebKit is still hidden defers one warm resume until visibility returns', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'visible', game: 'tcgp:3', autoStart: true });
  h.bridge.suspendForManualSearch('visible');
  h.document.hidden = true; h.events.get('visibilitychange')();
  assert.equal(await h.bridge.resumeAfterManualSearch('visible'), true);
  assert.equal(h.cameraRequests, 1);
  h.document.hidden = false; h.events.get('visibilitychange')();
  // Startup uses asynchronous module interfaces, so observe its ready event.
  for (let i = 0; i < 100 && h.scannerStarts < 2; i++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.packOptions.length, 1); assert.equal(h.cameraRequests, 2); assert.equal(h.scannerStarts, 2);
  h.events.get('visibilitychange')(); assert.equal(h.scannerStarts, 2);
  h.bridge.suspendForManualSearch('visible'); h.document.hidden = true; h.events.get('visibilitychange')();
  await h.bridge.resumeAfterManualSearch('visible');
  const visible = h.events.get('visibilitychange'); h.bridge.stop(); h.document.hidden = false; visible();
  assert.equal(h.cameraRequests, 2); assert.equal(h.scannerStarts, 2, 'A terminal stop cancels deferred visibility resume');
});

test('old document transitions and failed startup cannot silently restart a replacement or failed camera', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'new', game: 'tcgp:3', autoStart: true });
  const starts = h.scannerStarts;
  assert.equal(h.bridge.suspendForManualSearch('old'), false);
  assert.equal(await h.bridge.resumeAfterManualSearch('old'), false);
  assert.equal(h.scannerStarts, starts); h.bridge.stop();
  const failed = harness({ denyCamera: true });
  await failed.bridge.install({ nonce: 'failed', game: 'tcgp:3', autoStart: true });
  failed.bridge.suspendForManualSearch('failed');
  assert.equal(await failed.bridge.resumeAfterManualSearch('failed'), false);
  assert.equal(failed.cameraRequests, 1);
  assert.equal(failed.elements.find(e => e.tag === 'button').textContent, 'Retry Scanner');
  failed.bridge.stop();
});

async function waitForScannerStarts(h, count) {
  for (let i = 0; i < 100 && h.scannerStarts < count; i++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.scannerStarts, count);
}

async function waitForCameraReady(h, count) {
  for (let i = 0; i < 100 && h.messages.filter(message => message.event === 'scanner_ready').length < count; i++) await new Promise(resolve => setImmediate(resolve));
  assert.equal(h.messages.filter(message => message.event === 'scanner_ready').length, count);
}

test('normal resource mode preserves the default scheduler; reduced mode bounds all frame work with cancellation', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'resources', game: 'tcgp:3', autoStart: true });
  assert.equal(Object.hasOwn(h.scannerOptions, 'frame'), false);
  assert.equal(h.bridge.setResourceMode('reduced', 'resources'), true);
  assert.equal(h.cameraRequests, 1); assert.equal(h.packOptions.length, 1);
  const schedule = h.scannerOptions.frame; let ticks = 0;
  const cancel = schedule({}, () => ticks++);
  assert.deepEqual([...h.timers.values()].map(timer => timer.delay), [200]);
  assert.equal(ticks, 0); h.flushTimers(); assert.equal(ticks, 0);
  h.flushFrames(); assert.equal(ticks, 1); cancel();
  const cancelBeforeTimer = schedule({}, () => ticks++); cancelBeforeTimer(); h.flushTimers(); h.flushFrames();
  const cancelBeforeFrame = schedule({}, () => ticks++); h.flushTimers(); cancelBeforeFrame(); h.flushFrames();
  assert.equal(ticks, 1);
  h.bridge.setResourceMode('normal', 'resources');
  assert.equal(Object.hasOwn(h.scannerOptions, 'frame'), false);
  assert.equal(h.cameraRequests, 1); h.bridge.stop();
});

test('initial cooling defers database/backend/camera startup and only foreground cooling recovery can start it', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'initial-heat', game: 'tcgp:3', autoStart: true, resourceMode: 'cooling' });
  assert.equal(h.cameraRequests, 0); assert.equal(h.packOptions.length, 0); assert.equal(h.scannerStarts, 0);
  assert.match(h.messages.at(-1).message, /Cooling down/);
  h.bridge.setResourceMode('normal', 'initial-heat', false);
  assert.equal(h.cameraRequests, 0); assert.equal(h.packOptions.length, 0);
  h.bridge.setResourceMode('normal', 'initial-heat', true);
  await waitForScannerStarts(h, 1);
  assert.equal(h.cameraRequests, 1); assert.equal(h.packOptions.length, 1); h.bridge.stop();
});

test('cooling releases capture but retains the frozen review and saved-card identity across warm recovery', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'held-heat', game: 'tcgp:3', autoStart: true });
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  const scans = () => h.messages.filter(message => message.kind === 'scan').length;
  const oldLoop = h.scannerOptions, stopped = h.stopped;
  h.bridge.setResourceMode('cooling', 'held-heat');
  assert.ok(h.stopped > stopped); assert.equal(h.disposed, 0); assert.equal(scans(), 1);
  oldLoop.onShow({ ref: tuple(124), accepted: true, confidence: 96 }); oldLoop.onHide();
  assert.equal(scans(), 1);
  h.bridge.setResourceMode('reduced', 'held-heat'); await waitForCameraReady(h, 2);
  assert.equal(h.scannerStarts, 1, 'Cooling recovery cannot restart recognition under a frozen review');
  assert.equal(h.activeLoops, 0);
  assert.equal(h.packOptions.length, 1); assert.equal(h.disposed, 0);
  settle(h, { ref: tuple(124), accepted: true, confidence: 96 });
  assert.equal(scans(), 1, 'A frozen review still owns recognition after cooling');
  h.bridge.releaseReview();
  settle(h, { ref: tuple(124), accepted: true, confidence: 96 });
  assert.equal(scans(), 2, 'Saving releases the original held identity, allowing a different physical card');
  h.bridge.stop();
});

test('late camera acquisition while cooling stops its tracks before playback without discarding the loaded database', async () => {
  for (const rejected of [false, true]) {
    const camera = deferred(), entered = deferred(); let requests = 0;
    const h = harness({ acquireCamera: () => { if (++requests === 1) { entered.resolve(); return camera.promise; } } });
    const startup = h.bridge.install({ nonce: 'acquiring-heat', game: 'tcgp:3', autoStart: true });
    await entered.promise; h.bridge.setResourceMode('cooling', 'acquiring-heat');
    if (rejected) camera.reject(Object.assign(new Error('Native permission deferred by cooling'), { name: 'NotAllowedError' }));
    else camera.resolve();
    await startup;
    assert.equal(h.stopped, rejected ? 0 : 1); assert.equal(h.scannerStarts, 0); assert.equal(h.disposed, 0);
    assert.equal(h.messages.filter(message => message.event === 'startup_failed').length, 0);
    h.bridge.setResourceMode('normal', 'acquiring-heat'); await waitForScannerStarts(h, 1);
    assert.equal(h.packOptions.length, 1); assert.equal(h.cameraRequests, 2); h.bridge.stop();
  }
});

test('cooling during pending playback treats its known AbortError as a pause and resumes once', async () => {
  const playback = deferred(), entered = deferred(); let plays = 0;
  const h = harness({ playVideo: () => { if (++plays === 1) { entered.resolve(); return playback.promise; } } });
  const startup = h.bridge.install({ nonce: 'playing-heat', game: 'tcgp:3', autoStart: true });
  await entered.promise; h.bridge.setResourceMode('cooling', 'playing-heat');
  playback.reject(Object.assign(new Error('Retired thermal playback'), { name: 'AbortError' })); await startup;
  assert.equal(h.disposed, 0); assert.equal(h.scannerStarts, 0);
  assert.equal(h.messages.filter(message => message.event === 'startup_failed').length, 0);
  h.bridge.setResourceMode('normal', 'playing-heat'); await waitForScannerStarts(h, 1);
  assert.equal(h.packOptions.length, 1); h.bridge.stop();
});

test('manual, reset, refresh, visibility and terminal stop cannot bypass cooling or explicit suspension', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'intent-heat', game: 'tcgp:3', autoStart: true });
  h.bridge.suspendForManualSearch('intent-heat'); h.bridge.setResourceMode('cooling', 'intent-heat');
  h.bridge.resetRecognition(); h.bridge.refreshDatabase(); h.bridge.setSteadyCardBorder(true);
  h.bridge.resumeAfterManualSearchPrompt();
  assert.equal(h.cameraRequests, 1); assert.equal(h.packOptions.length, 1);
  h.bridge.setResourceMode('normal', 'intent-heat'); assert.equal(h.scannerStarts, 1);
  await h.bridge.resumeAfterManualSearch('intent-heat'); await waitForScannerStarts(h, 2);
  h.bridge.setResourceMode('cooling', 'intent-heat');
  await h.bridge.resumeAfterManualSearch('intent-heat'); assert.equal(h.cameraRequests, 2);
  h.document.hidden = true; h.events.get('visibilitychange')();
  h.bridge.setResourceMode('normal', 'intent-heat'); assert.equal(h.cameraRequests, 2);
  const visible = h.events.get('visibilitychange'); h.bridge.stop(); h.document.hidden = false; visible();
  assert.equal(h.bridge.setResourceMode('normal', 'intent-heat'), false);
  assert.equal(h.cameraRequests, 2);
});

test('resource updates validate their fixed mode and document nonce before changing capture', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'validated-heat', game: 'tcgp:3', autoStart: true });
  const stopped = h.stopped;
  assert.equal(h.bridge.setResourceMode('cooling', 'old'), false);
  assert.equal(h.bridge.setResourceMode('untrusted', 'validated-heat'), false);
  assert.equal(h.bridge.setResourceMode('cooling', 'validated-heat', 'false'), false);
  assert.equal(h.stopped, stopped); assert.equal(h.scannerStarts, 1); h.bridge.stop();
});

test('cooling recovery preserves an unresolved manual-search prompt until its existing decision is made', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'prompt-heat', game: 'tcgp:3', autoStart: true });
  await waitOnCard(h); assert.equal(manualSuggestions(h).length, 1);
  h.bridge.setResourceMode('cooling', 'prompt-heat');
  h.bridge.setResourceMode('normal', 'prompt-heat'); await waitForCameraReady(h, 2);
  assert.equal(h.scannerStarts, 1, 'Cooling recovery cannot restart recognition under the unresolved prompt');
  assert.equal(h.activeLoops, 0);
  settle(h, { ref: tuple(124), accepted: true, confidence: 96 });
  assert.equal(h.messages.filter(message => message.kind === 'scan').length, 0);
  h.bridge.resumeAfterManualSearchPrompt();
  settle(h, { ref: tuple(124), accepted: true, confidence: 96 });
  assert.equal(h.messages.filter(message => message.kind === 'scan').length, 1); h.bridge.stop();
});

const cameraWorkloads = h => h.messages.filter(message => message.event === 'camera_workload');
const finishCameraWork = () => new Promise(resolve => setImmediate(resolve));

test('camera acquisition bounds actual frame-rate requests without changing resolution or normal recognition scheduling', async () => {
  for (const [mode, fps] of [['normal', 30], ['reduced', 10]]) {
    const h = harness({ cameraConstraintsSupported: true });
    await h.bridge.install({ nonce: mode, game: 'tcgp:3', autoStart: true, resourceMode: mode });
    await finishCameraWork();
    assert.deepEqual(clean(h.captureOptions.video.frameRate), { ideal: fps, max: fps });
    assert.deepEqual(clean(h.captureOptions.video.width), { ideal: 1920 });
    assert.deepEqual(clean(h.captureOptions.video.height), { ideal: 1080 });
    assert.equal(Object.hasOwn(h.scannerOptions, 'frame'), mode === 'reduced');
    const applied = cameraWorkloads(h).at(-1);
    assert.equal(applied.constraintState, 'applied'); assert.equal(applied.cameraFPS, fps);
    assert.equal(applied.targetFPS, fps); assert.equal(applied.captureState, 'live');
    assert.equal(applied.processingActive, true); assert.equal(h.activeLoops, 1);
    h.bridge.stop();
  }
});

test('a frozen native review stops all recognition callbacks and stays stopped across resource changes', async () => {
  const h = harness({ cameraConstraintsSupported: true });
  await h.bridge.install({ nonce: 'review-load', game: 'tcgp:3', autoStart: true });
  const oldLoop = h.scannerOptions;
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.activeLoops, 0); const starts = h.scannerStarts;
  const stats = h.messages.filter(message => message.event === 'scan_stats').length;
  const draws = h.draws.length;
  oldLoop.onStats({ kind: 'worker', scanMs: 20 }); oldLoop.onHint('Late hidden work');
  oldLoop.onShow({ ref: tuple(999), accepted: true, confidence: 96 });
  oldLoop.overlay.draw({ quad: [[0, 0]] });
  assert.equal(h.messages.filter(message => message.event === 'scan_stats').length, stats);
  assert.equal(h.draws.length, draws);
  h.bridge.setResourceMode('reduced', 'review-load'); await finishCameraWork();
  assert.equal(h.cameraTracks[0].fps, 10); assert.equal(h.activeLoops, 0);
  h.bridge.setResourceMode('normal', 'review-load');
  await finishCameraWork();
  assert.equal(h.scannerStarts, starts); assert.equal(h.activeLoops, 0);
  assert.equal(h.cameraTracks[0].fps, 30); assert.equal(cameraWorkloads(h).at(-1).processingActive, false);
  assert.equal(cameraWorkloads(h).at(-1).captureState, 'review');
  assert.equal(h.cameraRequests, 1); assert.equal(h.packOptions.length, 1);
  h.bridge.releaseReview(); assert.equal(h.activeLoops, 1);
  settle(h, { ref: tuple(124), accepted: true, confidence: 96 });
  assert.deepEqual(h.messages.filter(message => message.kind === 'scan').map(message => message.candidates[0].ref), ['p:123', 'p:124']);
  h.bridge.stop();
});

test('a pending manual-search prompt stops work until the existing decision resumes scanning', async () => {
  const h = harness({ cameraConstraintsSupported: true });
  await h.bridge.install({ nonce: 'prompt-load', game: 'tcgp:3', autoStart: true });
  await waitOnCard(h); await finishCameraWork();
  assert.equal(manualSuggestions(h).length, 1); assert.equal(h.activeLoops, 0);
  assert.equal(h.cameraTracks[0].fps, 30); const starts = h.scannerStarts;
  h.bridge.setResourceMode('reduced', 'prompt-load'); await finishCameraWork();
  assert.equal(h.scannerStarts, starts); assert.equal(h.activeLoops, 0);
  assert.equal(h.cameraTracks[0].fps, 10);
  assert.equal(cameraWorkloads(h).at(-1).captureState, 'prompt');
  h.bridge.resumeAfterManualSearchPrompt(); await finishCameraWork();
  assert.equal(h.activeLoops, 1); assert.equal(h.cameraTracks[0].fps, 10);
  assert.equal(manualSuggestions(h).length, 1); assert.equal(h.cameraRequests, 1);
  h.bridge.stop();
});

test('manual entry pauses recognition while keeping the preview smooth and reuses database on return', async () => {
  const h = harness({ cameraConstraintsSupported: true });
  await h.bridge.install({ nonce: 'manual-load', game: 'tcgp:3', autoStart: true });
  const video = h.elements.find(element => element.tag === 'video'), stream = video.srcObject;
  h.bridge.suspendForManualSearch('manual-load'); await finishCameraWork();
  assert.equal(h.activeLoops, 0); assert.equal(video.srcObject, stream);
  assert.equal(h.cameraTracks[0].readyState, 'live'); assert.equal(h.cameraTracks[0].fps, 30);
  h.bridge.setResourceMode('reduced', 'manual-load'); await finishCameraWork();
  assert.equal(h.activeLoops, 0); assert.equal(h.cameraTracks[0].fps, 10);
  await h.bridge.resumeAfterManualSearch('manual-load'); await finishCameraWork();
  assert.equal(h.activeLoops, 1); assert.equal(h.cameraTracks[0].fps, 10);
  assert.equal(video.srcObject, stream); assert.equal(h.cameraRequests, 1);
  assert.equal(h.packOptions.length, 1); assert.equal(h.disposed, 0);
  h.bridge.stop();
});

test('camera constraints are serialized with one latest pending target and no stale applied announcement', async () => {
  const first = deferred(); let entered = 0, active = 0, peak = 0;
  const h = harness({ applyCameraConstraints: async () => {
    peak = Math.max(peak, ++active);
    try { if (++entered === 1) await first.promise; } finally { active--; }
  } });
  await h.bridge.install({ nonce: 'serial-load', game: 'tcgp:3', autoStart: true });
  assert.equal(h.cameraConstraintCalls.length, 1);
  h.bridge.setResourceMode('reduced', 'serial-load'); h.bridge.suspendForManualSearch('serial-load');
  assert.equal(h.cameraConstraintCalls.length, 1, 'Readiness changes cannot launch concurrent operations');
  first.resolve(); await finishCameraWork();
  assert.equal(peak, 1);
  assert.deepEqual(h.cameraConstraintCalls.map(call => call.constraints.frameRate.ideal), [30, 10]);
  assert.equal(h.cameraTracks[0].fps, 10); assert.equal(h.activeLoops, 0);
  const applied = cameraWorkloads(h).filter(message => message.constraintState === 'applied');
  assert.deepEqual(applied.map(message => [message.captureState, message.targetFPS]), [['manual', 10]]);
  h.bridge.stop();
});

test('manual, review and prompt transitions reuse the successful preview rate without reconfiguring the camera', async () => {
  for (const [mode, fps] of [['normal', 30], ['reduced', 10]]) {
    const h = harness({ cameraConstraintsSupported: true });
    await h.bridge.install({ nonce: 'smooth', game: 'tcgp:3', autoStart: true, resourceMode: mode });
    await finishCameraWork();
    assert.equal(h.cameraConstraintCalls.length, 1);
    settle(h, { ref: tuple(), accepted: true, confidence: 96 }); await finishCameraWork();
    assert.equal(h.activeLoops, 0); assert.equal(h.cameraTracks[0].fps, fps);
    assert.equal(cameraWorkloads(h).at(-1).captureState, 'review');
    assert.equal(cameraWorkloads(h).at(-1).processingActive, false);
    for (let i = 0; i < 5; i++) {
      h.bridge.suspendForManualSearch('smooth');
      assert.equal(h.activeLoops, 0); assert.equal(h.cameraTracks[0].fps, fps);
      await h.bridge.resumeAfterManualSearch('smooth');
    }
    await finishCameraWork();
    assert.equal(h.activeLoops, 1); assert.equal(h.cameraTracks[0].fps, fps);
    await waitOnCard(h); await finishCameraWork();
    assert.equal(h.activeLoops, 0); assert.equal(h.cameraTracks[0].fps, fps);
    assert.equal(cameraWorkloads(h).at(-1).captureState, 'prompt');
    h.bridge.resumeAfterManualSearchPrompt(); await finishCameraWork();
    assert.equal(h.activeLoops, 1); assert.equal(h.cameraTracks[0].fps, fps);
    assert.equal(h.cameraConstraintCalls.length, 1, 'Only changing presentation or processing state must not reconfigure the same track');
    assert.equal(h.cameraRequests, 1); assert.equal(h.packOptions.length, 1); assert.equal(h.disposed, 0);
    h.bridge.stop();
  }
});

test('cooling recovery reacquires a smooth preview without resuming an unresolved review or prompt', async () => {
  for (const [mode, fps] of [['normal', 30], ['reduced', 10]]) {
    for (const state of ['review', 'prompt']) {
      const h = harness({ cameraConstraintsSupported: true });
      await h.bridge.install({ nonce: 'held-preview', game: 'tcgp:3', autoStart: true, resourceMode: mode });
      if (state === 'review') settle(h, { ref: tuple(), accepted: true, confidence: 96 });
      else await waitOnCard(h);
      assert.equal(h.activeLoops, 0);
      h.bridge.setResourceMode('cooling', 'held-preview');
      assert.equal(h.cameraTracks[0].readyState, 'ended');
      h.bridge.setResourceMode(mode, 'held-preview'); await waitForCameraReady(h, 2); await finishCameraWork();
      assert.deepEqual(clean(h.captureOptions.video.frameRate), { ideal: fps, max: fps });
      assert.equal(h.cameraTracks[1].fps, fps); assert.equal(h.activeLoops, 0);
      assert.equal(cameraWorkloads(h).at(-1).captureState, state);
      assert.equal(cameraWorkloads(h).at(-1).processingActive, false);
      assert.equal(h.cameraRequests, 2); assert.equal(h.packOptions.length, 1); assert.equal(h.disposed, 0);
      if (state === 'review') h.bridge.releaseReview(); else h.bridge.resumeAfterManualSearchPrompt();
      await finishCameraWork();
      assert.equal(h.activeLoops, 1); assert.equal(h.cameraTracks[1].fps, fps);
      assert.equal(h.cameraConstraintCalls.length, 2, 'A replacement stream needs its own successful target; releasing its sheet does not');
      h.bridge.stop();
    }
  }
});

test('a rejected rate change cannot reuse an earlier successful target or mask another failure', async () => {
  let attempts = 0;
  const h = harness({ applyCameraConstraints: async () => {
    if ([2, 3].includes(++attempts)) throw new Error('PRIVATE_CAMERA_ERROR');
  } });
  await h.bridge.install({ nonce: 'rate-failure', game: 'tcgp:3', autoStart: true }); await finishCameraWork();
  h.bridge.setResourceMode('reduced', 'rate-failure'); await finishCameraWork();
  assert.equal(cameraWorkloads(h).at(-1).constraintState, 'failed');
  h.bridge.setResourceMode('normal', 'rate-failure'); await finishCameraWork();
  assert.equal(cameraWorkloads(h).at(-1).constraintState, 'failed');
  h.bridge.suspendForManualSearch('rate-failure'); await finishCameraWork();
  assert.deepEqual(h.cameraConstraintCalls.map(call => call.constraints.frameRate.ideal), [30, 10, 30, 30]);
  assert.equal(cameraWorkloads(h).at(-1).constraintState, 'applied');
  assert.equal(h.cameraTracks[0].fps, 30); assert.equal(h.activeLoops, 0);
  assert.equal(JSON.stringify(cameraWorkloads(h)).includes('PRIVATE_CAMERA_ERROR'), false);
  h.bridge.stop();
});

test('cooling immediately retires capture and a hung old constraint cannot block or mutate the replacement stream', async () => {
  const oldOperation = deferred(); let calls = 0;
  const h = harness({ applyCameraConstraints: async () => { if (++calls === 1) await oldOperation.promise; } });
  await h.bridge.install({ nonce: 'retired-load', game: 'tcgp:3', autoStart: true });
  const oldTrack = h.cameraTracks[0];
  h.bridge.setResourceMode('cooling', 'retired-load');
  assert.equal(oldTrack.readyState, 'ended'); assert.equal(h.activeLoops, 0);
  assert.equal(cameraWorkloads(h).at(-1).captureState, 'stopped');
  h.bridge.setResourceMode('reduced', 'retired-load'); await waitForCameraReady(h, 2); await finishCameraWork();
  const newTrack = h.cameraTracks[1]; assert.equal(newTrack.fps, 10); assert.equal(h.activeLoops, 1);
  const before = cameraWorkloads(h).length;
  oldOperation.resolve(); await finishCameraWork();
  assert.equal(cameraWorkloads(h).length, before, 'A stopped-track callback cannot announce its obsolete target');
  assert.equal(newTrack.fps, 10); assert.equal(h.cameraTracks.length, 2);
  h.bridge.stop();
});

test('unsupported and rejected camera limits stay observable without claiming lower effective capture', async () => {
  for (const failure of ['unsupported', 'failed']) {
    const h = harness({ cameraSettings: () => ({ frameRate: 30 }),
      ...(failure === 'failed' ? { applyCameraConstraints: async () => { throw new Error('PRIVATE_CAMERA_ERROR'); } } : {}) });
    await h.bridge.install({ nonce: failure, game: 'tcgp:3', autoStart: true, resourceMode: 'reduced' });
    await finishCameraWork();
    const event = cameraWorkloads(h).at(-1);
    assert.equal(event.constraintState, failure); assert.equal(event.targetFPS, 10); assert.equal(event.cameraFPS, 30);
    assert.equal(event.processingActive, true); assert.equal(h.activeLoops, 1);
    assert.equal(cameraWorkloads(h).some(message => message.constraintState === 'applied'), false);
    assert.equal(JSON.stringify(cameraWorkloads(h)).includes('PRIVATE_CAMERA_ERROR'), false);
    h.bridge.stop();
  }
});

test('camera facts are finite bounded scalars and terminal stop invalidates pending constraint work', async () => {
  const pending = deferred();
  const h = harness({ applyCameraConstraints: () => pending.promise, cameraSettings: () => ({ frameRate: NaN, deviceId: 'PRIVATE_ID' }) });
  await h.bridge.install({ nonce: 'bounded-load', game: 'tcgp:3', autoStart: true });
  assert.equal(cameraWorkloads(h).some(message => Object.hasOwn(message, 'cameraFPS')), false);
  h.bridge.stop(); const count = h.messages.length;
  pending.resolve(); await finishCameraWork();
  assert.equal(h.messages.length, count); assert.equal(h.activeLoops, 0);
  assert.equal(h.cameraTracks[0].readyState, 'ended');
  assert.equal(JSON.stringify(cameraWorkloads(h)).includes('PRIVATE_ID'), false);
});

test('only a rejected acquisition frame-rate maximum gets one ideal-only compatibility retry', async () => {
  let attempts = 0; const requested = [];
  const h = harness({ cameraSettings: () => ({ frameRate: 60 }), acquireCamera: options => {
    requested.push(clean(options));
    if (++attempts === 1) throw Object.assign(new Error('Unsupported camera maximum'), { name: 'OverconstrainedError', constraint: 'frameRate' });
  } });
  await h.bridge.install({ nonce: 'compatible-rate', game: 'tcgp:3', autoStart: true, resourceMode: 'reduced' });
  assert.equal(h.cameraRequests, 2); assert.equal(h.activeLoops, 1);
  assert.deepEqual(requested[0].video.frameRate, { ideal: 10, max: 10 });
  assert.deepEqual(requested[1].video.frameRate, { ideal: 10 });
  assert.deepEqual(requested[1].video.width, requested[0].video.width);
  assert.deepEqual(requested[1].video.height, requested[0].video.height);
  assert.equal(cameraWorkloads(h).at(-1).cameraFPS, 60);
  assert.equal(cameraWorkloads(h).at(-1).constraintState, 'unsupported'); h.bridge.stop();
  for (const [name, constraint] of [['OverconstrainedError', 'width'], ['NotAllowedError', 'frameRate'], ['NotReadableError', 'frameRate']]) {
    const failed = harness({ acquireCamera: () => { throw Object.assign(new Error('Camera cannot start'), { name, constraint }); } });
    await failed.bridge.install({ nonce: name, game: 'tcgp:3', autoStart: true });
    assert.equal(failed.cameraRequests, 1); assert.equal(failed.scannerStarts, 0);
    assert.equal(failed.messages.filter(message => message.event === 'startup_failed').length, 1); failed.bridge.stop();
  }
});

test('cooling or terminal stop during unsupported camera acquisition cannot trigger its compatibility retry', async () => {
  for (const action of ['cooling', 'stop']) {
    const gate = deferred(), entered = deferred();
    const h = harness({ acquireCamera: async () => { entered.resolve(); await gate.promise;
      throw Object.assign(new Error('Unsupported camera maximum'), { name: 'OverconstrainedError', constraint: 'frameRate' });
    } });
    const startup = h.bridge.install({ nonce: 'retired-fallback', game: 'tcgp:3', autoStart: true });
    await entered.promise;
    if (action === 'cooling') h.bridge.setResourceMode('cooling', 'retired-fallback');
    else h.bridge.stop();
    gate.resolve(); await startup;
    assert.equal(h.cameraRequests, 1); assert.equal(h.scannerStarts, 0);
    assert.equal(h.messages.filter(message => message.event === 'startup_failed').length, 0);
    if (action === 'cooling') h.bridge.stop();
  }
});
