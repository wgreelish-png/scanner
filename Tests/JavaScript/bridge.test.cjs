const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../../CardShowScanner/Resources/TCGTrackingBridge.js'), 'utf8');
function harness({ denyCamera = false, cacheState = 'ok' } = {}) {
  const messages = [], elements = [], events = new Map(), windowEvents = new Map(), trackEvents = new Map(), draws = [];
  let overlayDestroyed = 0;
  const packOptions = [];
  let captureOptions, scannerOptions, scannerStarts = 0, stopped = 0, disposed = 0, now = 0;
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
    'core/pack.js': { async loadPack(game, progress, options) {
      packOptions.push(options);
      if (game !== 'tcgp:3') throw new Error('No downloadable pack is available for this game.');
      progress(1, 1, { downloaded: 0, total: 0, cache: cacheState, cachedHashShards: 1, cachedMetaShards: 1, storage: { persisted: false } });
      return { game };
    } },
    'app/scan-backends.js': { createBackend: async () => backend },
    'core/overlay.js': { createOverlay: () => ({ draw(options) { draws.push(options); }, clear() {}, setSource() {}, destroy() { overlayDestroyed++; } }) },
    'app/quickscan.js': { startQuickScan(options) { scannerStarts++; scannerOptions = options; return () => { stopped++; }; } },
    'app/shared.js': { useScope(scope) { assert.equal(scope, 'price'); }, catalogDetail() {} }
  };
  const sandbox = { URL, console, document, performance: { now: () => now },
    navigator: { mediaDevices: { async getUserMedia(options) { if (denyCamera) throw new Error("Camera permission denied"); captureOptions = options; return { getTracks: () => [{ stop() { stopped++; }, addEventListener(name, fn) { trackEvents.set(name, fn); } }] }; } } },
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
  return { bridge: sandbox.CardShowBridge, messages, elements, events, windowEvents, trackEvents, draws, document, get overlayDestroyed() { return overlayDestroyed; }, advance(ms) { now += ms; },
    packOptions, get scannerOptions() { return scannerOptions; }, get scannerStarts() { return scannerStarts; }, get captureOptions() { return captureOptions; }, get stopped() { return stopped; }, get disposed() { return disposed; } };
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
  h.scannerOptions.onHide(); assert.equal(h.messages.at(-1).kind, 'hide');
  settle(h, { ref: tuple(), accepted: true, confidence: 96 });
  assert.equal(h.messages.at(-1).kind, 'scan');
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
  h.scannerOptions.onHide(); await waitOnCard(h);
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
