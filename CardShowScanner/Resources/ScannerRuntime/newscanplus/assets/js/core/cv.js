/*
 * cv.js - single OpenCV.js loader.
 *
 * Exports
 *   cv                      live binding to the OpenCV instance (null until ready)
 *   cvReady(src?) -> Promise<cv>   loads once (script tag; importScripts in classic workers; module workers
 *                                  must setCv() themselves); later calls return the same promise
 *   setCv(instance) -> cv   inject an already-initialised instance (Node tests, workers)
 *   settle(moduleOrPromise) -> Promise<cv>   waits for runtime init; strips the self-resolving `then`
 *   features -> {hasLSD, hasCLAHE, version, simd}   valid after ready (simd: the loaded build uses wasm SIMD)
 *   hasLSD() -> boolean
 *   hasWasmSimd() -> boolean   WebAssembly.validate of a 1-function SIMD module (cached)
 *   pickSrc() -> url           SRC.simd when hasWasmSimd(), else SRC.base (wasm SIMD: Safari >= 16.4,
 *                              Chrome >= 91, Firefox >= 89)
 *   SRC = {simd, base}, DEFAULT_SRC = pickSrc()
 *
 * Builds (assets/vendor/; the filename carries the version because nginx caches .js for a year - a rebuild
 * gets a new name, never an overwrite). Both are single-file (wasm embedded), modules core+imgproc+js only:
 *   opencv-nsp-412-simd.js  OpenCV 4.12.0, emsdk 3.1.64, -msimd128 + CV_ENABLE_INTRINSICS=ON
 *   opencv-nsp-412.js       same whitelist, scalar (no intrinsics, no -msimd128)
 *   opencv.js               legacy full build (copy of /scan/vendor/opencv.js; no LSD) - unused here
 * Neither has cv.dct; hash.js does its own DCT.
 *
 * Rebuild recipe (lab: /home/master/newscanplus-lab/opencvjs, whitelist nsp_config.py there):
 *   git clone --depth 1 -b 4.12.0 https://github.com/opencv/opencv.git
 *   git clone https://github.com/emscripten-core/emsdk && emsdk/emsdk install 3.1.64 && emsdk/emsdk activate 3.1.64
 *   source emsdk/emsdk_env.sh            # cmake < 4 on PATH (cmake 4 rejects old 3rdparty minimums)
 *   python3 opencv/platforms/js/build_js.py build_simd --build_wasm --simd --config=nsp_config.py \
 *     --config_only --build_flags=-O3 \
 *     --cmake_option=-DBUILD_LIST=core,imgproc,js,js_bindings_generator \
 *     --cmake_option=-DBUILD_TESTS=OFF --cmake_option=-DBUILD_PERF_TESTS=OFF --cmake_option=-DBUILD_EXAMPLES=OFF
 *   (cd build_simd && nice -n 15 make -j4 opencv.js)   # build_js.py would use make -j$(nproc)
 *   # fallback: same without --simd, into build_base
 *   # whitelist = every cv.* used by core/*.js, app/*.js, tests/*.mjs:
 *   #   core:    absdiff, bitwise_and/or/not, countNonZero, inRange, mean, meanStdDev, merge,
 *   #            perspectiveTransform, split (+ Mat/MatVector/Size/Rect/Scalar/RotatedRect/boxPoints,
 *   #            matFromArray/matFromImageData, getBuildInformation from core_bindings/helpers)
 *   #   imgproc: approxPolyDP, arcLength, Canny, contourArea, convexHull, CLAHE (createCLAHE + apply),
 *   #            createLineSegmentDetector + LineSegmentDetector.detect, cvtColor, dilate, findContours,
 *   #            fitLine, GaussianBlur, getPerspectiveTransform, isContourConvex, Laplacian, minAreaRect,
 *   #            morphologyEx, remap, resize, threshold, warpAffine, warpPerspective
 *   # verify: NSP_OPENCV=opencv-nsp-412-simd.js node assets/js/tests/parity.mjs (and smoke/bench)
 */

const VENDOR = '/newscanplus/assets/vendor/';
export const SRC = {
  simd: VENDOR + 'opencv-nsp-412-simd.js',
  base: VENDOR + 'opencv-nsp-412.js',
};

// (module (func (result v128) i32.const 0 i8x16.splat i8x16.popcnt)) - final-spec SIMD opcodes only
const SIMD_PROBE = new Uint8Array([
  0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 123, 3, 2, 1, 0, 10, 10, 1, 8, 0, 65, 0, 253, 15, 253, 98, 11,
]);

let simdCache = null;
export function hasWasmSimd() {
  if (simdCache === null) {
    try {
      simdCache = typeof WebAssembly === 'object' && WebAssembly.validate(SIMD_PROBE);
    } catch (_) {
      simdCache = false;
    }
  }
  return simdCache;
}

export function pickSrc() {
  return hasWasmSimd() ? SRC.simd : SRC.base;
}

export const DEFAULT_SRC = pickSrc();

export let cv = null;
export const features = { hasLSD: false, hasCLAHE: false, version: '', simd: false };

let readyPromise = null;

function probe(instance) {
  features.hasLSD = typeof instance.createLineSegmentDetector === 'function';
  features.hasCLAHE = typeof instance.CLAHE === 'function' || typeof instance.createCLAHE === 'function';
  let info = '';
  try {
    info = instance.getBuildInformation ? instance.getBuildInformation() : '';
  } catch (_) {
    info = '';
  }
  const m = /OpenCV ([\d.]+)/.exec(info);
  features.version = m ? m[1] : '';
  features.simd = /-msimd128/.test(info);
}

// embindgen binds factory functions as class constructors (new cv.LineSegmentDetector(refine),
// new cv.CLAHE(clip, size)); lines.js and older callers use the C++ factory names.
function addFactories(instance) {
  for (const [fn, cls] of [['createLineSegmentDetector', 'LineSegmentDetector'], ['createCLAHE', 'CLAHE']]) {
    if (typeof instance[fn] !== 'function' && typeof instance[cls] === 'function') {
      instance[fn] = (...args) => new instance[cls](...args);
    }
  }
}

export function setCv(instance) {
  if (instance && typeof instance.then === 'function') delete instance.then;
  addFactories(instance);
  cv = instance;
  probe(instance);
  if (!readyPromise) readyPromise = Promise.resolve(instance);
  return instance;
}

export function hasLSD() {
  return features.hasLSD;
}

// The emscripten Module is a thenable that resolves with itself; awaiting it directly recurses.
export function settle(candidate) {
  const done = (resolve, m) => {
    if (m && typeof m.then === 'function') delete m.then;
    resolve(m);
  };
  return new Promise((resolve, reject) => {
    if (!candidate) return reject(new Error('OpenCV.js did not define cv'));
    if (candidate.Mat) return done(resolve, candidate);
    if (typeof candidate.then === 'function') {
      candidate.then((m) => done(resolve, m && m.Mat ? m : candidate));
      return;
    }
    const prev = candidate.onRuntimeInitialized;
    candidate.onRuntimeInitialized = () => {
      if (typeof prev === 'function') prev();
      done(resolve, candidate);
    };
  });
}

export function cvReady(src = DEFAULT_SRC) {
  if (readyPromise) return readyPromise;
  readyPromise = (async () => {
    if (!globalThis.cv || !(globalThis.cv.Mat || globalThis.cv.then)) {
      if (typeof document === 'undefined' && typeof importScripts === 'function') {
        importScripts(src);
      } else await new Promise((resolve, reject) => {
        const s = document.createElement('script');
        s.src = src;
        s.async = true;
        s.onload = resolve;
        s.onerror = () => reject(new Error('failed to load ' + src));
        document.head.appendChild(s);
      });
    }
    const instance = await settle(globalThis.cv);
    globalThis.cv = instance;
    setCv(instance);
    return instance;
  })();
  readyPromise.catch(() => { readyPromise = null; });
  return readyPromise;
}
