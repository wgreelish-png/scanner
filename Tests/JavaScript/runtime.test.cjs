const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');
let scalarHash;
for (const build of ['opencv-nsp-412.js', 'opencv-nsp-412-simd.js']) {
  test(`bundled ${build} preserves default decisions and pixels while reporting scalar diagnostics`, () => {
    const run = spawnSync(process.execPath, [path.resolve(__dirname, '../../scripts/scanner_runtime_smoke.cjs'), build], { encoding: 'utf8', timeout: 30000 });
    assert.equal(run.status, 0, run.stderr || String(run.error));
    const result = JSON.parse(run.stdout);
    assert.equal(result.blankFrameRejected, true);
    assert.equal(result.matchedSyntheticReference, 0);
    assert.equal(result.metadataVerified, true);
    assert.equal(result.sourcePixelsUnchanged, true);
    assert.equal(result.retainedBorderVerified, true);
    assert.equal(result.decisionFingerprint, 'e39192ac050a599fe2ae27fbc048fdb705e2b79c5d56064a3a28bf7004302afd');
    if (scalarHash) assert.equal(result.hash, scalarHash); else scalarHash = result.hash;
  });
}

test('quick-scan diagnostics lazily read the existing frame without changing pixels or no-card decisions', async () => {
  const moduleURL = pathToFileURL(path.resolve(__dirname, '../../CardShowScanner/Resources/ScannerRuntime/newscanplus/assets/js/app/quickscan.js'));
  const { startQuickScan } = await import(moduleURL);
  const data = new Uint8ClampedArray(32 * 32 * 4);
  for (let i = 0; i < data.length; i += 4) { data[i] = data[i + 1] = data[i + 2] = 40; data[i + 3] = 255; }
  const original = Buffer.from(data), stats = [], shows = [];
  let scheduled, clock = 0, scans = 0;
  const stop = startQuickScan({
    video: {}, pack: { cl: new Int32Array() }, overlay: { clear() {}, draw() {}, setSource() {} },
    backend: {
      kind: 'worker', quadEveryMs: 80, reset() {},
      async quad() { return { quad: null, w: 32, h: 32 }; },
      async scan() { scans++; return { result: null, quad: null, solid: false, frames: 0, stage: '', tracked: false, ms: { total: 2, capture: 0 },
        diagnostics: { solid: false, tracked: false, scanStage: 'none', rawQuads: 0, rejectedQuads: 0, candidateQuads: 0, quadSource: 'none' } }; }
    },
    reader: { read() { return { data, width: 32, height: 32 }; } },
    frame(_video, fn) { scheduled = fn; return () => {}; }, now: () => clock,
    onStats(value) { stats.push(value); }, onShow(value) { shows.push(value); }
  });
  try {
    for (clock = 0; clock <= 800; clock += 80) { scheduled(); await Promise.resolve(); await Promise.resolve(); }
    assert.ok(scans > 0); assert.ok(stats.length > 0); assert.equal(shows.length, 0);
    assert.equal(typeof stats[0].frameQuality, 'function');
    assert.equal('meanLuma' in stats[0], false, 'quality is computed only when the diagnostic adapter asks');
    assert.equal(stats[0].diagnostics.solid, false); assert.equal(stats[0].frames, 0);
    const quality = stats[0].frameQuality();
    assert.ok(Math.abs(quality.meanLuma - 40) < 1e-9); assert.ok(quality.lumaStd < 1e-5);
    assert.deepEqual(Buffer.from(data), original);
  } finally { stop(); }
});
