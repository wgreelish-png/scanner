const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
let scalarHash;
for (const build of ['opencv-nsp-412.js', 'opencv-nsp-412-simd.js']) {
  test(`bundled ${build} initializes, hashes/matches synthetic input, and rejects an empty frame`, () => {
    const run = spawnSync(process.execPath, [path.resolve(__dirname, '../../scripts/scanner_runtime_smoke.cjs'), build], { encoding: 'utf8', timeout: 30000 });
    assert.equal(run.status, 0, run.stderr || String(run.error));
    const result = JSON.parse(run.stdout);
    assert.equal(result.blankFrameRejected, true);
    assert.equal(result.matchedSyntheticReference, 0);
    if (scalarHash) assert.equal(result.hash, scalarHash); else scalarHash = result.hash;
  });
}
