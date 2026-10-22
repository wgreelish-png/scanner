/*
 * quality.js - cheap image-quality signals.
 *
 * Exports
 *   GLARE_TILT = 0.20                        contract threshold for the "tilt" hint
 *   glareScore(img) -> number 0..1           50x70 INTER_AREA, HSV, fraction V>=225 && S<=60 (contract)
 *                                            img: RGB (CV_8UC3) or RGBA card/frame Mat
 *   blurScore(img, thumbLong=280) -> number  variance of Laplacian on a gray thumbnail (higher = sharper)
 *   quadAreaFrac(quad, w, h) -> number       quad area / frame area
 *   cardTooSmall(quad, w, h, minFrac=0.12) -> boolean
 *   assessCard(rgb200) -> {glare, blur}
 */
import { cv } from './cv.js';

export const GLARE_TILT = 0.20;

export function glareScore(img) {
  const small = new cv.Mat();
  const hsv = new cv.Mat();
  try {
    cv.resize(img, small, new cv.Size(50, 70), 0, 0, cv.INTER_AREA);
    if (small.channels() === 4) cv.cvtColor(small, small, cv.COLOR_RGBA2RGB);
    cv.cvtColor(small, hsv, cv.COLOR_RGB2HSV);
    const d = hsv.data;
    let n = 0;
    for (let i = 0; i < 3500 * 3; i += 3) if (d[i + 2] >= 225 && d[i + 1] <= 60) n++;
    return n / 3500;
  } finally {
    small.delete(); hsv.delete();
  }
}

export function blurScore(img, thumbLong = 280) {
  const small = new cv.Mat();
  const gray = new cv.Mat();
  const lap = new cv.Mat();
  const mean = new cv.Mat();
  const sd = new cv.Mat();
  try {
    const s = Math.min(1, thumbLong / Math.max(img.cols, img.rows));
    if (s < 1) cv.resize(img, small, new cv.Size(0, 0), s, s, cv.INTER_AREA);
    else img.copyTo(small);
    const ch = small.channels();
    if (ch === 4) cv.cvtColor(small, gray, cv.COLOR_RGBA2GRAY);
    else if (ch === 3) cv.cvtColor(small, gray, cv.COLOR_RGB2GRAY);
    else small.copyTo(gray);
    cv.Laplacian(gray, lap, cv.CV_64F);
    cv.meanStdDev(lap, mean, sd);
    const v = sd.doubleAt(0, 0);
    return v * v;
  } finally {
    small.delete(); gray.delete(); lap.delete(); mean.delete(); sd.delete();
  }
}

export function quadAreaFrac(quad, w, h) {
  let a = 0;
  for (let i = 0; i < 4; i++) {
    const p = quad[i], q = quad[(i + 1) % 4];
    a += p[0] * q[1] - q[0] * p[1];
  }
  return Math.abs(a) / 2 / (w * h);
}

export function cardTooSmall(quad, w, h, minFrac = 0.12) {
  return !quad || quadAreaFrac(quad, w, h) < minFrac;
}

export function assessCard(rgb200) {
  return { glare: glareScore(rgb200), blur: blurScore(rgb200) };
}
