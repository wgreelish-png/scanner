const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../CardShowScanner/Resources/TCGTrackingBridge.js'), 'utf8');
const operation = 'b8021c42-c5ee-4f17-80ca-36e67e08b685';
const replacement = 'efc6318e-1880-44cf-abf2-f6effaa6c414';

// This harness exercises only the app-owned RPC seam; the visual engine remains
// a stub, so no camera, native Vision request or network is involved.
function harness({ width = 1920, height = 1080, image = 'PRIVATE_IMAGE' } = {}) {
  const elements = [], messages = [], events = new Map(), windowEvents = new Map(), tracks = [], snapshots = [];
  let starts = 0, activeLoops = 0, scannerOptions;
  const element = tag => {
    const node = { tag, style: {}, children: [], videoWidth: width, videoHeight: height,
      append(...children) { this.children.push(...children); }, setAttribute() {}, remove() { this.removed = true; }, async play() {},
      getContext() { return { drawImage(input, ...bounds) { snapshots.push({ node, input, bounds }); } }; },
      toDataURL(type, quality) { assert.equal(type, 'image/jpeg'); assert.equal(quality, 0.88); return 'data:image/jpeg;base64,' + image; } };
    elements.push(node); return node;
  };
  const document = { hidden: false, body: element('body'), createElement: element,
    addEventListener(name, fn) { events.set(name, fn); }, removeEventListener(name) { events.delete(name); } };
  const backend = { setPack() {}, dispose() {}, reset() {}, async scanImage(bitmap) { bitmap.close(); return { cards: [] }; } };
  const modules = {
    'core/pack.js': { async loadPack() { return { refs: [] }; } },
    'app/scan-backends.js': { async createBackend() { return backend; } },
    'core/overlay.js': { createOverlay() { return { setSource() {}, clear() {}, draw() {}, destroy() {} }; } },
    'app/quickscan.js': { startQuickScan(options) { starts++; activeLoops++; scannerOptions = options; let active = true; return () => { if (active) { active = false; activeLoops--; } }; } },
    'app/shared.js': { useScope() {} }, 'app/desk-results.js': { candidatesFrom() { return []; } }
  };
  const sandbox = { URL, console, document, performance: { now: () => 100 },
    createImageBitmap: async canvas => ({ width: canvas.width, height: canvas.height, close() {} }),
    requestAnimationFrame: () => 1, cancelAnimationFrame() {}, setTimeout: () => 1, clearTimeout() {},
    navigator: { mediaDevices: { async getUserMedia() { const track = { readyState: 'live', kind: 'video',
      stop() { this.readyState = 'ended'; }, addEventListener() {}, getSettings() { return { frameRate: 30 }; } };
      tracks.push(track); return { getTracks: () => [track], getVideoTracks: () => [track] }; } } },
    window: { addEventListener(name, fn) { windowEvents.set(name, fn); }, removeEventListener(name) { windowEvents.delete(name); },
      webkit: { messageHandlers: { scanResult: { postMessage(value) { messages.push(JSON.parse(JSON.stringify(value))); } } } } }
  };
  const context = vm.createContext(sandbox);
  new vm.Script(source, { importModuleDynamically: async specifier => {
    const exports = modules[specifier.replace('/newscanplus/assets/js/', '')]; assert.ok(exports, specifier);
    const module = new vm.SyntheticModule(Object.keys(exports), function () { for (const [name, value] of Object.entries(exports)) this.setExport(name, value); }, { context });
    await module.link(() => {}); await module.evaluate(); return module;
  } }).runInContext(context);
  return { bridge: sandbox.CardShowBridge, elements, messages, document, events, tracks, snapshots,
    get starts() { return starts; }, get activeLoops() { return activeLoops; }, get scannerOptions() { return scannerOptions; } };
}
async function start(h, mode = 'live', nonce = 'text-test') { await h.bridge.install({ nonce, game: 'tcgp:3', autoStart: true, captureMode: mode }); }
function clean(value) { return JSON.parse(JSON.stringify(value)); }

test('one live frame pauses visual recognition, keeps preview and returns pixels only through RPC', async () => {
  const h = harness({ width: 4000, height: 3000 }); await start(h);
  const original = h.scannerOptions;
  assert.equal(h.activeLoops, 1);
  const image = await h.bridge.captureTextImage('text-test', operation);
  assert.deepEqual(clean(image), { source: 'live', imageBase64: 'PRIVATE_IMAGE' });
  assert.equal(h.activeLoops, 0); assert.equal(h.tracks[0].readyState, 'live');
  assert.deepEqual(h.snapshots.at(-1).bounds, [0, 0, 2048, 1536]);
  assert.equal(h.snapshots.at(-1).node.width, 1); assert.equal(h.snapshots.at(-1).node.height, 1);
  assert.equal(h.snapshots.at(-1).node.removed, true);
  assert.equal(JSON.stringify(h.messages).includes('PRIVATE_IMAGE'), false);
  original.onHide(); assert.equal(h.messages.at(-1).kind === 'hide', false, 'Retired visual callbacks cannot hide text review');
  assert.equal(await h.bridge.captureTextImage('text-test', replacement), null, 'One native OCR operation owns the frame');
  assert.equal(h.bridge.finishTextRecognition('text-test', operation, false), true);
  assert.equal(h.activeLoops, 1); assert.equal(h.starts, 2);
  h.bridge.stop();
});

test('text suggestions keep the existing explicit review and release boundary', async () => {
  const h = harness(); await start(h);
  await h.bridge.captureTextImage('text-test', operation);
  assert.equal(h.bridge.finishTextRecognition('text-test', operation, true), true);
  assert.equal(h.activeLoops, 0); assert.equal(h.messages.some(message => message.kind === 'scan'), false, 'Native catalog candidates are not fabricated as visual matches');
  assert.equal(h.bridge.finishTextRecognition('text-test', operation, false), false);
  h.bridge.releaseReview('p:123'); assert.equal(h.activeLoops, 1);
  h.bridge.stop();
});

test('wrong nonces, malformed operations and untyped completions never change capture', async () => {
  const h = harness(); await start(h);
  assert.equal(await h.bridge.captureTextImage('old', operation), null);
  assert.equal(await h.bridge.captureTextImage('text-test', 'bad'), null);
  assert.equal(h.activeLoops, 1);
  await h.bridge.captureTextImage('text-test', operation);
  assert.equal(h.bridge.finishTextRecognition('old', operation, true), false);
  assert.equal(h.bridge.finishTextRecognition('text-test', replacement, true), false);
  assert.equal(h.bridge.finishTextRecognition('text-test', operation, 'true'), false);
  assert.equal(h.activeLoops, 0);
  h.bridge.finishTextRecognition('text-test', operation, false); h.bridge.stop();
});

test('photo text fallback requires failed visual recognition and can run once per still', async () => {
  const h = harness(); await start(h, 'photo');
  assert.equal(await h.bridge.captureTextImage('text-test', operation), null);
  assert.equal(await h.bridge.capturePhoto('text-test'), true);
  assert.equal(h.messages.filter(message => message.kind === 'photoState').at(-1).photoState, 'noMatch');
  assert.equal(h.tracks[0].readyState, 'ended');
  assert.deepEqual(clean(await h.bridge.captureTextImage('text-test', operation)), { source: 'photo', imageBase64: 'PRIVATE_IMAGE' });
  assert.equal(h.bridge.finishTextRecognition('text-test', operation, false), true);
  assert.equal(await h.bridge.captureTextImage('text-test', replacement), null);
  assert.equal(await h.bridge.retakePhoto('text-test'), true);
  assert.equal(await h.bridge.capturePhoto('text-test'), true);
  assert.equal((await h.bridge.captureTextImage('text-test', replacement)).source, 'photo');
  assert.equal(h.bridge.finishTextRecognition('text-test', replacement, true), true);
  assert.equal(h.messages.filter(message => message.kind === 'photoState').at(-1).photoState, 'ready');
  assert.equal(h.activeLoops, 0); h.bridge.stop();
});

for (const retire of ['manual', 'background', 'critical', 'mode', 'reset', 'stop', 'new-document']) {
  test(`${retire} invalidates native OCR ownership and rejects delayed completion`, async () => {
    const h = harness(); await start(h); await h.bridge.captureTextImage('text-test', operation);
    if (retire === 'manual') h.bridge.suspendForManualSearch('text-test');
    else if (retire === 'background') { h.document.hidden = true; h.events.get('visibilitychange')(); }
    else if (retire === 'critical') h.bridge.setResourceMode('cooling', 'text-test', true);
    else if (retire === 'mode') h.bridge.setCaptureMode('photo', 'text-test');
    else if (retire === 'reset') h.bridge.resetRecognition();
    else if (retire === 'new-document') await start(h, 'live', 'replacement');
    else h.bridge.stop();
    const starts = h.starts;
    assert.equal(h.bridge.finishTextRecognition('text-test', operation, true), false);
    assert.equal(h.starts, starts, 'An obsolete completion cannot wake recognition');
    h.bridge.stop();
  });
}

for (const input of [{ width: 0 }, { height: NaN }, { image: 'X'.repeat(2_800_001) }]) {
  test(`invalid or oversized snapshot (${Object.keys(input)[0]}) releases live ownership without truncating`, async () => {
    const h = harness(input); await start(h);
    assert.equal(await h.bridge.captureTextImage('text-test', operation), null);
    assert.equal(h.activeLoops, 1); assert.equal(h.bridge.finishTextRecognition('text-test', operation, false), false);
    if (h.snapshots.length) { assert.equal(h.snapshots.at(-1).node.width, 1); assert.equal(h.snapshots.at(-1).node.removed, true); }
    h.bridge.stop();
  });
}
