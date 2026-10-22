const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../CardShowScanner/Resources/TCGTrackingBridge.js'), 'utf8');
function harness({ denyCamera = false } = {}) {
  const messages = [], elements = [], events = new Map();
  let captureOptions, scannerOptions, stopped = 0, disposed = 0;
  const element = tag => {
    const e = { tag, style: {}, children: [], append(...items) { this.children.push(...items); }, setAttribute() {},
      remove() { this.removed = true; }, async play() {} };
    elements.push(e); return e;
  };
  const body = element('body');
  const document = { body, hidden: false, createElement: element,
    addEventListener(name, fn) { events.set(name, fn); }, removeEventListener(name) { events.delete(name); } };
  const backend = { setPack() {}, dispose() { disposed++; } };
  const modules = {
    'core/pack.js': { loadPackIndex: async () => ({ games: { 'tcgp:3': {} } }), loadPack: async () => ({ game: 'tcgp:3' }) },
    'app/scan-backends.js': { createBackend: async () => backend },
    'core/overlay.js': { createOverlay: () => ({}) },
    'app/quickscan.js': { startQuickScan(options) { scannerOptions = options; return () => { stopped++; }; } },
    'app/shared.js': { useScope(scope) { assert.equal(scope, 'price'); }, catalogDetail() {} }
  };
  const sandbox = { URL, console, document,
    navigator: { mediaDevices: { async getUserMedia(options) { if (denyCamera) throw new Error("Camera permission denied"); captureOptions = options; return { getTracks: () => [{ stop() { stopped++; } }] }; } } },
    window: { webkit: { messageHandlers: { scanResult: { postMessage: m => messages.push(JSON.parse(JSON.stringify(m))) } } } }
  };
  const context = vm.createContext(sandbox);
  const script = new vm.Script(source, { importModuleDynamically: async specifier => {
    const prefix = '/newscanplus/assets/js/'; assert.ok(specifier.startsWith(prefix));
    const exports = modules[specifier.slice(prefix.length)]; assert.ok(exports, specifier);
    const mod = new vm.SyntheticModule(Object.keys(exports), function () { for (const [k, v] of Object.entries(exports)) this.setExport(k, v); }, { context });
    await mod.link(() => {}); await mod.evaluate(); return mod;
  } });
  script.runInContext(context);
  return { bridge: sandbox.CardShowBridge, messages, elements, events, document,
    get scannerOptions() { return scannerOptions; }, get captureOptions() { return captureOptions; }, get stopped() { return stopped; }, get disposed() { return disposed; } };
}
const tuple = (id = 123, variants = [{ id: 10, label: 'Normal', nm: 1.25, primary: true }, { id: 11, label: 'Holofoil', nm: 2.5 }]) =>
  [`p:${id}`, `Sample ${id}`, '1/10', 'DEMO', 'Demo Set', '', 'https://cdn.tcgtracking.com/test.jpg', variants];
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
  h.scannerOptions.onShow({ ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).kind, 'scan'); assert.equal(h.messages.at(-1).nonce, 'test-nonce');
  h.scannerOptions.onHide(); assert.equal(h.messages.at(-1).kind, 'scan');
  h.bridge.releaseReview();
  h.scannerOptions.onHide(); assert.equal(h.messages.at(-1).kind, 'hide');
  h.bridge.stop(); assert.ok(h.stopped >= 2); assert.equal(h.disposed, 1);
  const count = h.messages.length; h.scannerOptions.onShow({ ref: tuple() }); assert.equal(h.messages.length, count);
});
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
  for (const event of ['bridge_ready', 'modules_ready', 'index_ready', 'pack_ready', 'backend_ready', 'camera_requested', 'camera_acquired', 'video_playing', 'scanner_ready']) {
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
  h.scannerOptions.onShow({ ref: tuple(), confidence: 96, accepted: true });
  assert.ok(h.messages.some(m => m.kind === 'scan' && m.candidates[0].name === 'Sample 123'));
  assert.equal(JSON.stringify(diagnostics()).includes('Sample 123'), false);
});

test('review freezes full payload, including captured image, until explicitly released', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  assert.ok(h.scannerOptions, 'local scanner starts without a mock or website button');
  h.scannerOptions.onShow({ ref: tuple(), accepted: true, confidence: 96, thumb: 'data:image/jpeg;base64,/9j/AA==' });
  const first = h.messages.at(-1);
  assert.equal(first.capturedImageBase64, '/9j/AA==');
  const count = h.messages.length;
  h.scannerOptions.onShow({ ref: tuple(124), confidence: 99 });
  h.scannerOptions.onHide(); assert.equal(h.messages.length, count);
  h.bridge.resetRecognition();
  h.scannerOptions.onShow({ ref: tuple(124), confidence: 99 });
  assert.equal(h.messages.at(-1).candidates[0].ref, 'p:124');
});
test('recognition does not depend on the online catalog detail callback', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  assert.equal(h.scannerOptions.fetchDetails, null);
  assert.equal(h.scannerOptions.resolveCandidates, false);
});

test('saving waits for card removal instead of latching a duplicate frame', async () => {
  const h = harness(); await h.bridge.install({ nonce: 'n', game: 'tcgp:3', autoStart: true });
  h.scannerOptions.onShow({ ref: tuple(), accepted: true, confidence: 96 });
  h.bridge.releaseReview();
  const count = h.messages.length;
  h.scannerOptions.onShow({ ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.length, count);
  h.scannerOptions.onHide(); assert.equal(h.messages.at(-1).kind, 'hide');
  h.scannerOptions.onShow({ ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).kind, 'scan');
});
