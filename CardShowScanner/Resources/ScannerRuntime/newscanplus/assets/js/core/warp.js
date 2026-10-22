/*
 * warp.js - quad -> normalised 200x280 RGB card (contract "Card normalisation").
 *
 * Exports
 *   CARD_W = 200, CARD_H = 280
 *   warpCard(frame, quad) -> cv.Mat CV_8UC3 RGB 200x280   (caller deletes)
 *       frame: CV_8UC4 RGBA or CV_8UC3 RGB; quad: [[x,y]x4] in card order TL,TR,BR,BL (frame px).
 *       perspective warp to 400x560 INTER_LINEAR, then INTER_AREA to 200x280.
 *   warpCardPair(frame, quad) -> [card, card180]  (caller deletes both)  warpCard(quad) and warpCard of the
 *       quad rolled by 2 (the other orientation hypothesis) from ONE perspective warp; equal to two warpCard
 *       calls except the outermost super-sampled row/column of the twin (replicated)
 *   normalizeCard(img) -> cv.Mat CV_8UC3 RGB 200x280      (caller deletes)
 *       reference/upload path: alpha bbox crop (alpha > 16) + composite on white with the service's integer
 *       rule c' = (c*a + 255*(255-a) + 127) // 255, then INTER_AREA stretch.
 *   toImageData(rgbMat) -> ImageData-like {data, width, height}
 */
import { cv } from './cv.js';

export const CARD_W = 200;
export const CARD_H = 280;
const SUPER_W = 400;
const SUPER_H = 560;

export function warpCard(frame, quad) {
  const src = cv.matFromArray(4, 1, cv.CV_32FC2, quad.flat());
  const dst = cv.matFromArray(4, 1, cv.CV_32FC2, [0, 0, SUPER_W, 0, SUPER_W, SUPER_H, 0, SUPER_H]);
  const M = cv.getPerspectiveTransform(src, dst);
  const big = new cv.Mat();
  const out = new cv.Mat();
  try {
    cv.warpPerspective(frame, big, M, new cv.Size(SUPER_W, SUPER_H), cv.INTER_LINEAR, cv.BORDER_CONSTANT, new cv.Scalar());
    if (big.channels() === 4) cv.cvtColor(big, big, cv.COLOR_RGBA2RGB);
    cv.resize(big, out, new cv.Size(CARD_W, CARD_H), 0, 0, cv.INTER_AREA);
    return out;
  } catch (e) {
    out.delete();
    throw e;
  } finally {
    src.delete(); dst.delete(); M.delete(); big.delete();
  }
}

// Warping the corners rolled by 2 samples dst pixel x at the unrolled warp's pixel 400 - x, so the 180 deg twin is
// the super-sampled warp reversed with a 1 px offset (the never-sampled row/column 400 is replicated).
export function warpCardPair(frame, quad) {
  const src = cv.matFromArray(4, 1, cv.CV_32FC2, quad.flat());
  const dst = cv.matFromArray(4, 1, cv.CV_32FC2, [0, 0, SUPER_W, 0, SUPER_W, SUPER_H, 0, SUPER_H]);
  const M = cv.getPerspectiveTransform(src, dst);
  const big = new cv.Mat();
  const rev = new cv.Mat(SUPER_H, SUPER_W, cv.CV_8UC3);
  const a = new cv.Mat();
  const b = new cv.Mat();
  try {
    cv.warpPerspective(frame, big, M, new cv.Size(SUPER_W, SUPER_H), cv.INTER_LINEAR, cv.BORDER_CONSTANT, new cv.Scalar());
    if (big.channels() === 4) cv.cvtColor(big, big, cv.COLOR_RGBA2RGB);
    const s = big.data, d = rev.data;
    for (let y = 0; y < SUPER_H; y++) {
      const sy = Math.min(SUPER_H - 1, SUPER_H - y) * SUPER_W;
      const row = y * SUPER_W;
      for (let x = 0; x < SUPER_W; x++) {
        const i = (sy + Math.min(SUPER_W - 1, SUPER_W - x)) * 3, j = (row + x) * 3;
        d[j] = s[i]; d[j + 1] = s[i + 1]; d[j + 2] = s[i + 2];
      }
    }
    cv.resize(big, a, new cv.Size(CARD_W, CARD_H), 0, 0, cv.INTER_AREA);
    cv.resize(rev, b, new cv.Size(CARD_W, CARD_H), 0, 0, cv.INTER_AREA);
    return [a, b];
  } catch (e) {
    a.delete(); b.delete();
    throw e;
  } finally {
    src.delete(); dst.delete(); M.delete(); big.delete(); rev.delete();
  }
}

export function normalizeCard(img) {
  const out = new cv.Mat();
  let rgb = null;
  try {
    const ch = img.channels();
    if (ch === 4) {
      const w = img.cols, h = img.rows, d = img.data;
      let x0 = w, y0 = h, x1 = -1, y1 = -1;
      for (let y = 0; y < h; y++) {
        for (let x = 0; x < w; x++) {
          if (d[(y * w + x) * 4 + 3] > 16) {
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            if (y > y1) y1 = y;
          }
        }
      }
      if (x1 < 0) { x0 = 0; y0 = 0; x1 = w - 1; y1 = h - 1; }
      const cw = x1 - x0 + 1, chh = y1 - y0 + 1;
      rgb = new cv.Mat(chh, cw, cv.CV_8UC3);
      const o = rgb.data;
      for (let y = 0; y < chh; y++) {
        for (let x = 0; x < cw; x++) {
          const i = ((y + y0) * w + (x + x0)) * 4;
          const j = (y * cw + x) * 3;
          const a = d[i + 3];
          for (let c = 0; c < 3; c++) o[j + c] = Math.floor((d[i + c] * a + 255 * (255 - a) + 127) / 255);
        }
      }
    } else if (ch === 1) {
      rgb = new cv.Mat();
      cv.cvtColor(img, rgb, cv.COLOR_GRAY2RGB);
    } else {
      rgb = img.clone();
    }
    if (rgb.cols === CARD_W && rgb.rows === CARD_H) rgb.copyTo(out);
    else cv.resize(rgb, out, new cv.Size(CARD_W, CARD_H), 0, 0, cv.INTER_AREA);
    return out;
  } catch (e) {
    out.delete();
    throw e;
  } finally {
    if (rgb) rgb.delete();
  }
}

export function toImageData(rgbMat) {
  const w = rgbMat.cols, h = rgbMat.rows, s = rgbMat.data, ch = rgbMat.channels();
  const data = new Uint8ClampedArray(w * h * 4);
  for (let i = 0, j = 0; i < w * h; i++, j += ch) {
    data[i * 4] = s[j];
    data[i * 4 + 1] = s[j + (ch > 1 ? 1 : 0)];
    data[i * 4 + 2] = s[j + (ch > 1 ? 2 : 0)];
    data[i * 4 + 3] = 255;
  }
  return typeof ImageData === 'function' ? new ImageData(data, w, h) : { data, width: w, height: h };
}
