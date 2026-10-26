// Isolate each Emscripten runtime: the application loads exactly one build per JS realm.
const assert = require('node:assert/strict');
const path = require('node:path');
const { createHash } = require('node:crypto');
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
    const { warpCard } = await import(pathToFileURL(path.join(assets, 'js/core/warp.js')));
    const mat = new cv.Mat(96, 64, cv.CV_8UC3);
    let hex;
    try {
      for (let i = 0; i < mat.data.length; i++) mat.data[i] = (i * 31 + Math.floor(i / 64) * 7) % 256;
      hex = bh1(mat);
    } finally { mat.delete(); }
    assert.match(hex, /^[0-9a-f]{324}$/i);
    assert.equal(hex, 'a74b9499aa54cee315a4c31dcf1a75a9d8c8a55d62317a4c31d575af89d88ccaddca2299ae075d5548fd918d4c8c8ff50598eb2cb68a8ab52b91b8abf9406b88126bfaedaa54b513d83b148fad830ebaaad92b73223d83e1d153d838e2abaf82b56a07f17029be2f070d749a8750bd0bd87c1d223fa48f2cdc38dd89d8998e9de242d8c826d36f8e95b91998e9b56c198e1069f6d8a953bb318a939659b88ba6ba6a', 'the pre-diagnostics synthetic hash must not change');

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
      assert.deepEqual(result.diagnostics, { solid: false, tracked: false, scanStage: 'none', rawQuads: 0, rejectedQuads: 0, candidateQuads: 0, quadSource: 'none' });
    } finally { engine.dispose(); }

    // Snapshot of the original default engine's complete decisions on a bright
    // synthetic card, two tracked repeats and card removal. Captured before the
    // diagnostic adaptation; excludes timings and the new metadata only.
    const width = 480, height = 640, data = new Uint8ClampedArray(width * height * 4);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const k = (y * width + x) * 4;
      let r = 25, g = 25, b = 25;
      if (x >= 140 && x <= 339 && y >= 180 && y <= 459) {
        r = 230; g = 210; b = 30;
        if (x >= 150 && x <= 329 && y >= 190 && y <= 449) {
          r = (Math.floor(x / 19) * 31 + Math.floor(y / 17) * 29) % 220 + 20;
          g = (Math.floor(x / 13) * 37 + Math.floor(y / 23) * 13) % 220 + 20;
          b = (Math.floor(x / 29) * 17 + Math.floor(y / 11) * 23) % 220 + 20;
        }
      }
      data[k] = r; data[k + 1] = g; data[k + 2] = b; data[k + 3] = 255;
    }
    const sourcePixels = Buffer.from(data);
    const frameMat = new cv.Mat(height, width, cv.CV_8UC4); frameMat.data.set(data);
    let brightQuery;
    try {
      const card = warpCard(frameMat, [[140, 180], [339, 180], [339, 459], [140, 459]]);
      try { brightQuery = queryFromHex(bh1(card)); } finally { card.delete(); }
    } finally { frameMat.delete(); }
    const brightPack = { n: 2, lo: new Uint32Array(72), hi: new Uint8Array(72), cl: new Int32Array([0, 1, -1, -1]) };
    brightPack.lo.set(brightQuery.lo); brightPack.hi.set(brightQuery.hi);
    for (let i = 0; i < 36; i++) { brightPack.lo[36 + i] = brightQuery.lo[i] ^ 0xffffffff; brightPack.hi[36 + i] = brightQuery.hi[i] ^ 15; }
    const brightEngine = createScanEngine(); brightEngine.setPack(brightPack);
    const decisions = [];
    try {
      for (const pixels of [data, data, data, new Uint8ClampedArray(data.length)]) {
        const scan = brightEngine.scanRGBA({ width, height, data: pixels });
        const { ms, diagnostics, ...decision } = scan;
        assert.equal(diagnostics.solid, scan.solid); assert.equal(diagnostics.tracked, scan.tracked);
        assert.equal(diagnostics.scanStage, scan.stage || 'none');
        if (scan.quad) {
          assert.equal(diagnostics.quadSource, 'selected');
          assert.ok(diagnostics.quadAspect > 0 && diagnostics.quadAspect <= 1);
          assert.ok(diagnostics.quadArea > 0 && diagnostics.quadArea <= 1);
          assert.equal(diagnostics.matchDistance, scan.result.best.d);
          assert.equal(diagnostics.matchGap, scan.result.gap);
        } else { assert.equal(diagnostics.quadSource, 'none'); }
        decisions.push(decision);
      }
    } finally { brightEngine.dispose(); }
    assert.deepEqual(Buffer.from(data), sourcePixels, 'metadata must not alter source pixels');
    const canonical = JSON.stringify(decisions, (_key, value) => typeof value === 'number' ? Math.round(value * 1e6) / 1e6 : value);
    const decisionFingerprint = createHash('sha256').update(canonical).digest('hex');
    assert.equal(decisionFingerprint, 'e39192ac050a599fe2ae27fbc048fdb705e2b79c5d56064a3a28bf7004302afd', 'default decisions must match the pre-diagnostics engine');
    console.log(JSON.stringify({ build, hash: hex, matchedSyntheticReference: 0, blankFrameRejected: true, decisionFingerprint, sourcePixelsUnchanged: true, metadataVerified: true }));
})().catch(error => { console.error(error); process.exitCode = 1; });
