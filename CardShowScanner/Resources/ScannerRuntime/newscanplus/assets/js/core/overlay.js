/*
 * overlay.js - canvas overlay over the camera preview: live quad + label chip anchored to the card.
 *
 * Exports
 *   STATES = {SEARCHING:'searching', MATCHED:'matched', LOW:'low', RETRY:'retry'}
 *   createOverlay(canvas, {fit='cover', mirror=false}) -> Overlay
 *     setSource(w, h)   coordinate space of incoming quads (e.g. grabSmall frame size or video size)
 *     draw({quad?, state='searching', label?:{name, number?, price?}, hint?, badge?})
 *        badge: short text (e.g. '?') in a small round marker on the card's top edge (low-confidence guess).
 *        quad in source px, card order or clockwise. 'low' shows hint (default "Tilt the card - glare"),
 *        'retry' shows hint (default "Hold steady"); 'matched' draws a compact chip (name, then number/price)
 *        inside the card just below its centre, at most ~the card's width (text ellipsised), clamped to the
 *        canvas minus the insets so it never hides under the top bar or the info panel.
 *     setInsets({top=0, bottom=0})  css px at the top/bottom covered by page UI (header, info panel)
 *     clear(), resize(), destroy()
 * fit must match the preview element's CSS object-fit (cover | contain). Canvas is sized to its CSS box x DPR
 * (ResizeObserver when available). Drawing only - no OpenCV.
 */

export const STATES = { SEARCHING: 'searching', MATCHED: 'matched', LOW: 'low', RETRY: 'retry' };

const STYLE = {
  searching: { stroke: 'rgba(255,255,255,0.85)', dash: [10, 8], width: 2 },
  matched: { stroke: '#7cf6d6', dash: [], width: 3 },
  low: { stroke: '#ffb86b', dash: [6, 6], width: 3 },
  retry: { stroke: '#ff5a5f', dash: [4, 6], width: 2.5 },
};
const HINTS = { low: 'Tilt the card - glare', retry: 'Hold steady' };

function fmtPrice(p) {
  if (p === null || p === undefined || p === '') return '';
  const n = Number(p);
  return Number.isFinite(n) ? '$' + n.toFixed(2) : String(p);
}

export function createOverlay(canvas, { fit = 'cover', mirror = false } = {}) {
  const ctx = canvas.getContext('2d');
  let srcW = 1, srcH = 1, cssW = 0, cssH = 0, dpr = 1, last = null;
  let insetTop = 0, insetBottom = 0;

  function resize() {
    const r = canvas.getBoundingClientRect();
    dpr = (typeof devicePixelRatio === 'number' && devicePixelRatio) || 1;
    cssW = r.width; cssH = r.height;
    canvas.width = Math.max(1, Math.round(cssW * dpr));
    canvas.height = Math.max(1, Math.round(cssH * dpr));
    if (last) draw(last);
  }

  const ro = typeof ResizeObserver === 'function' ? new ResizeObserver(resize) : null;
  if (ro) ro.observe(canvas);
  resize();

  function map(p) {
    const s = fit === 'contain' ? Math.min(cssW / srcW, cssH / srcH) : Math.max(cssW / srcW, cssH / srcH);
    const ox = (cssW - srcW * s) / 2, oy = (cssH - srcH * s) / 2;
    const x = ox + p[0] * s, y = oy + p[1] * s;
    return [mirror ? cssW - x : x, y];
  }

  function roundRect(x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  function ellipsize(text, maxW) {
    if (ctx.measureText(text).width <= maxW) return text;
    let lo = 0, hi = text.length;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (ctx.measureText(text.slice(0, mid) + '\u2026').width <= maxW) lo = mid; else hi = mid - 1;
    }
    return text.slice(0, lo).trimEnd() + '\u2026';
  }

  // centred on `center`, clamped to the visible band between the insets (the top inset wins when cramped)
  function chip(lines, center, maxW, color) {
    const pad = 8, lh = 18;
    const F0 = '600 15px system-ui, -apple-system, sans-serif', F1 = '13px system-ui, -apple-system, sans-serif';
    const limit = Math.max(60, Math.min(cssW - 8, maxW)) - pad * 2;
    ctx.font = F0;
    const t0 = ellipsize(lines[0], limit);
    const w0 = ctx.measureText(t0).width;
    ctx.font = F1;
    const t1 = lines[1] ? ellipsize(lines[1], limit) : '';
    const w1 = t1 ? ctx.measureText(t1).width : 0;
    const w = Math.max(w0, w1) + pad * 2;
    const h = pad * 2 + lh * (t1 ? 2 : 1) - 2;
    const x = Math.max(4, Math.min(cssW - w - 4, center[0] - w / 2));
    const y = Math.max(insetTop + 4, Math.min(cssH - insetBottom - h - 4, center[1] - h / 2));
    ctx.fillStyle = 'rgba(12,14,20,0.82)';
    roundRect(x, y, w, h, 8);
    ctx.fill();
    ctx.strokeStyle = color; ctx.lineWidth = 1.5; ctx.setLineDash([]);
    ctx.stroke();
    ctx.textBaseline = 'top';
    ctx.textAlign = 'center';
    ctx.fillStyle = '#fff';
    ctx.font = F0;
    ctx.fillText(t0, x + w / 2, y + pad);
    if (t1) {
      ctx.font = F1;
      ctx.fillStyle = '#cfd6e4';
      ctx.fillText(t1, x + w / 2, y + pad + lh);
    }
    ctx.textAlign = 'start';
  }

  function banner(text, color) {
    ctx.font = '600 15px system-ui, -apple-system, sans-serif';
    const w = ctx.measureText(text).width + 24, h = 32;
    const x = (cssW - w) / 2, y = cssH - h - 24;
    ctx.fillStyle = 'rgba(12,14,20,0.78)';
    roundRect(x, y, w, h, 16);
    ctx.fill();
    ctx.fillStyle = color; ctx.textBaseline = 'middle';
    ctx.fillText(text, x + 12, y + h / 2);
  }

  function draw(opts) {
    last = opts;
    const { quad = null, state = STATES.SEARCHING, label = null, hint = '', badge = '' } = opts || {};
    const st = STYLE[state] || STYLE.searching;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, cssW, cssH);
    if (quad) {
      const pts = quad.map(map);
      ctx.beginPath();
      pts.forEach((p, i) => (i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1])));
      ctx.closePath();
      ctx.setLineDash(st.dash);
      ctx.lineWidth = st.width;
      ctx.strokeStyle = st.stroke;
      ctx.lineJoin = 'round';
      ctx.stroke();
      if (badge) {
        const top = pts.reduce((a, p) => (p[1] < a[1] ? p : a), pts[0]);
        const others = pts.filter((p) => p !== top);
        const top2 = others.reduce((a, p) => (p[1] < a[1] ? p : a), others[0]);
        const x = Math.max(16, Math.min(cssW - 16, (top[0] + top2[0]) / 2));
        const y = Math.max(16, Math.min(cssH - 16, Math.min(top[1], top2[1])));
        ctx.setLineDash([]);
        ctx.beginPath();
        ctx.arc(x, y, 12, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(12,14,20,0.82)';
        ctx.fill();
        ctx.lineWidth = 1.5;
        ctx.strokeStyle = st.stroke;
        ctx.stroke();
        ctx.fillStyle = st.stroke;
        ctx.font = '700 14px system-ui, -apple-system, sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(badge, x, y + 1);
        ctx.textAlign = 'start';
      }
      if (state === STATES.MATCHED && label && label.name) {
        const cx = (pts[0][0] + pts[1][0] + pts[2][0] + pts[3][0]) / 4;
        const cy = (pts[0][1] + pts[1][1] + pts[2][1] + pts[3][1]) / 4;
        const side = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);
        const sa = (side(pts[0], pts[1]) + side(pts[2], pts[3])) / 2;
        const sb = (side(pts[1], pts[2]) + side(pts[3], pts[0])) / 2;
        const sub = [label.number ? '#' + label.number : '', fmtPrice(label.price)].filter(Boolean).join('  \u00b7  ');
        chip(sub ? [label.name, sub] : [label.name], [cx, cy + 0.12 * Math.max(sa, sb)], Math.max(160, 0.92 * Math.min(sa, sb)), st.stroke);
      }
    }
    if (state === STATES.LOW || state === STATES.RETRY) banner(hint || HINTS[state], st.stroke);
    else if (hint) banner(hint, '#fff');
  }

  return {
    setSource(w, h) { srcW = w || 1; srcH = h || 1; },
    setInsets({ top = 0, bottom = 0 } = {}) {
      if (top === insetTop && bottom === insetBottom) return;
      insetTop = Math.max(0, top); insetBottom = Math.max(0, bottom);
      if (last) draw(last);
    },
    draw,
    clear() { last = null; ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, canvas.width, canvas.height); },
    resize,
    destroy() { if (ro) ro.disconnect(); last = null; },
  };
}
