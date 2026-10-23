// Isolate each Emscripten runtime: the application loads exactly one build per JS realm.
const assert = require('node:assert/strict');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const assets = path.resolve(__dirname, '../CardShowScanner/Resources/ScannerRuntime/newscanplus/assets');
const build = process.argv[2];
assert.ok(['opencv-nsp-412.js', 'opencv-nsp-412-simd.js'].includes(build));
(async () => {
    const cv = await require(path.join(assets, 'vendor', build));
    const core = await import(pathToFileURL(path.join(assets, 'js/core/cv.js')));
    core.setCv(cv);
    const { bh1 } = await import(pathToFileURL(path.join(assets, 'js/core/hash.js')));
    const { queryFromHex, matchFrames } = await import(pathToFileURL(path.join(assets, 'js/core/localmatch.js')));
    const { createScanEngine } = await import(pathToFileURL(path.join(assets, 'js/app/scan-engine.js')));
    const mat = new cv.Mat(96, 64, cv.CV_8UC3);
    let hex;
    try {
      for (let i = 0; i < mat.data.length; i++) mat.data[i] = (i * 31 + Math.floor(i / 64) * 7) % 256;
      hex = bh1(mat);
    } finally { mat.delete(); }
    assert.match(hex, /^[0-9a-f]{324}$/i);

    const query = queryFromHex(hex);
    const pack = { n: 2, lo: new Uint32Array(72), hi: new Uint8Array(72), cl: new Int32Array([0, 1, -1, -1]) };
    pack.lo.set(query.lo); pack.hi.set(query.hi);
    for (let i = 0; i < 36; i++) { pack.lo[36 + i] = query.lo[i] ^ 0xffffffff; pack.hi[36 + i] = query.hi[i] ^ 15; }
    const match = matchFrames(pack, [[query]]);
    assert.equal(match.best.i, 0); assert.equal(match.best.d, 0); assert.equal(match.accepted, true);
    const engine = createScanEngine();
    try {
      engine.setPack(pack);
      const result = engine.scanRGBA({ width: 320, height: 320, data: new Uint8ClampedArray(320 * 320 * 4) }, { reset: true });
      assert.equal(result.result, null); assert.equal(result.quad, null); assert.equal(result.solid, false);
    } finally { engine.dispose(); }
    console.log(JSON.stringify({ build, hash: hex, matchedSyntheticReference: 0, blankFrameRejected: true }));
})().catch(error => { console.error(error); process.exitCode = 1; });
