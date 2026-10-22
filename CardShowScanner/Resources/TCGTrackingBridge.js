/* App-owned adapter for the user-authorized TCGTracking module integration.
 * Uses module exports observed in the supplied source; no DOM scraping or endpoint reimplementation.
 * Loaded in the HTTPS quick page so its import map, static host and browser origin remain intact.
 */
(() => {
  const referencePattern = /^(?:p|t|ts|u):\d{1,12}$/;
  const text = value => typeof value === 'string' ? value.slice(0, 1000) : '';
  const confidence = value => typeof value === 'number' && Number.isFinite(value) ? Math.max(0, Math.min(100, value)) : 0;
  const price = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null;
  const sku = value => (typeof value === 'number' && Number.isSafeInteger(value) && value > 0) || (typeof value === 'string' && /^\d{1,20}$/.test(value)) ? String(value) : null;
  const httpsImage = value => {
    if (!value) return null;
    try { const url = new URL(value, 'https://tcgtracking.com'); return url.protocol === 'https:' ? url.href : null; }
    catch { return null; }
  };
  function candidateFromTuple(tuple, score, printingState) {
    if (!Array.isArray(tuple) || !referencePattern.test(tuple[0])) return null;
    const variants = (Array.isArray(tuple[7]) ? tuple[7] : []).slice(0, 30).map(v => ({
      label: text(v?.label) || 'Default', skuID: sku(v?.id), marketPrice: price(v?.nm), primary: v?.primary === true
    }));
    const primary = variants.find(v => v.primary) || variants[0] || { label: 'Default', skuID: null, marketPrice: null };
    return {
      ref: tuple[0], name: text(tuple[1]) || tuple[0], number: text(tuple[2]), set: text(tuple[4]) || text(tuple[3]),
      imageURL: httpsImage(tuple[6] || (/^p:/.test(tuple[0]) ? `https://cdn.tcgtracking.com/product/${tuple[0].slice(2)}_200w.jpg` : '')),
      confidence: confidence(score), printing: primary.label, skuID: primary.skuID,
      marketPrice: primary.marketPrice, printings: variants,
      requiresPrintingSelection: printingState === 'ambiguous'
    };
  }
  function normalizeView(view) {
    if (view?.same === true) return { kind: 'scan', same: true, accepted: view.accepted === true, confidence: confidence(view.confidence) };
    const rows = [];
    const seen = new Set();
    const add = (tuple, score, state) => {
      const candidate = candidateFromTuple(tuple, score, state);
      if (!candidate || seen.has(candidate.ref) || rows.length >= 5) return;
      seen.add(candidate.ref); rows.push(candidate);
    };
    // Winner first; preserve resolved candidates and their complete tuples.
    add(view?.ref, view?.confidence, view?.printing?.state);
    for (const c of view?.cands || []) add(c.tuple, c.confidence, c.printingState);
    // Older views can carry complete sibling tuples instead of resolved cands.
    for (const tuple of view?.siblings || []) add(tuple, 0, 'ambiguous');
    return { kind: 'scan', same: false, accepted: view?.accepted === true, confidence: confidence(view?.confidence), candidates: rows };
  }
  let dispose = () => {};
  let resetRecognition = () => {};
  let releaseReview = () => {};
  async function install(config) {
    dispose();
    let running = true, stopLoop = null, stream = null, backend = null, starting = false, held = false, awaitingRemoval = false, beginLoop = null;
    const post = message => { if (running) window.webkit?.messageHandlers?.scanResult?.postMessage({ ...message, nonce: config.nonce }); };
    const diagnostic = (event, fields = {}) => post({ kind: 'diagnostic', event, ...fields });
    const clock = () => globalThis.performance?.now?.() ?? Date.now();
    const errorKind = error => ['NotAllowedError', 'NotFoundError', 'NotReadableError', 'AbortError', 'SecurityError', 'TypeError', 'RangeError'].includes(error?.name) ? error.name : 'Error';
    const onError = event => diagnostic('javascript_error', { errorKind: errorKind(event.error) });
    const onRejection = event => diagnostic('javascript_rejection', { errorKind: errorKind(event.reason) });
    window.addEventListener?.('error', onError);
    window.addEventListener?.('unhandledrejection', onRejection);
    diagnostic('bridge_ready');
    const root = document.createElement('section');
    root.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#111;color:white;font:16px system-ui;display:flex;flex-direction:column;padding:8px;box-sizing:border-box';
    const button = document.createElement('button');
    button.textContent = 'Download Game Database & Start Camera';
    button.style.cssText = 'font:600 17px system-ui;min-height:52px;border-radius:12px;margin-bottom:8px';
    const hint = document.createElement('div'); hint.setAttribute('role', 'status'); hint.style.minHeight = '40px';
    const frame = document.createElement('div'); frame.style.cssText = 'position:relative;flex:1;min-height:0';
    const video = document.createElement('video'); video.muted = true; video.autoplay = true; video.playsInline = true;
    video.style.cssText = 'width:100%;height:100%;object-fit:cover';
    const canvas = document.createElement('canvas'); canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;pointer-events:none';
    frame.append(video, canvas); root.append(button, hint, frame); document.body.append(root);
    const report = value => { hint.textContent = text(value); post({ kind: 'status', message: text(value) }); };
    const stopCamera = () => { stopLoop?.(); stopLoop = null; stream?.getTracks().forEach(t => t.stop()); stream = null; video.srcObject = null; };
    const visibility = () => { if (document.hidden) { diagnostic('camera_backgrounded'); stopCamera(); post({ kind: 'hide' }); button.disabled = false; button.hidden = false; button.textContent = 'Resume Camera'; } };
    document.addEventListener('visibilitychange', visibility);
    dispose = () => { diagnostic('bridge_stopped'); running = false; stopCamera(); backend?.dispose(); root.remove(); document.removeEventListener('visibilitychange', visibility); window.removeEventListener?.('error', onError); window.removeEventListener?.('unhandledrejection', onRejection); };
    report('Ready. Database downloads may be large; use Wi-Fi for initial setup.');
    button.onclick = async () => {
      if (starting || !running) return;
      starting = true; button.disabled = true;
      let stage = 'modules', began = clock(), lastStats = -Infinity;
      diagnostic('startup_started');
      try {
        report('Loading scanner modules…');
        const base = '/newscanplus/assets/js/';
        const [packs, backends, overlays, quick, shared] = await Promise.all([
          import(base + 'core/pack.js'), import(base + 'app/scan-backends.js'), import(base + 'core/overlay.js'),
          import(base + 'app/quickscan.js'), import(base + 'app/shared.js')
        ]);
        if (!running) return;
        diagnostic('modules_ready', { elapsedMS: clock() - began });
        shared.useScope('price');
        stage = 'index'; began = clock();
        const index = await packs.loadPackIndex();
        if (!index.games?.[config.game]) throw new Error('No downloadable pack is available for this game.');
        diagnostic('index_ready', { elapsedMS: clock() - began });
        stage = 'pack'; began = clock();
        const pack = await packs.loadPack(config.game, (loaded, total, stats) => {
          if (running) report(stats?.label || `Downloading database: ${Math.round(100 * loaded / Math.max(1, total))}%`);
        });
        if (!running) return;
        diagnostic('pack_ready', { elapsedMS: clock() - began });
        stage = 'backend'; began = clock();
        backend?.dispose(); backend = await backends.createBackend();
        if (!running) { backend.dispose(); return; }
        backend.setPack(pack);
        diagnostic('backend_ready', { elapsedMS: clock() - began, backend: backend.kind });
        stage = 'camera'; began = clock(); diagnostic('camera_requested');
        report('Requesting rear camera…');
        const captured = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } } });
        if (!running || document.hidden) { captured.getTracks().forEach(t => t.stop()); return; }
        diagnostic('camera_acquired', { elapsedMS: clock() - began });
        stage = 'video'; began = clock();
        stream = captured; video.srcObject = stream; await video.play();
        if (!running) { stopCamera(); return; }
        diagnostic('video_playing', { elapsedMS: clock() - began });
        stage = 'scan';
        const overlay = overlays.createOverlay(canvas, { fit: 'cover' });
        beginLoop = () => quick.startQuickScan({ video, overlay, backend, pack, fetchDetails: null, resolveCandidates: false,
          onShow: view => {
            if (held || awaitingRemoval) return;
            const result = normalizeView(view);
            if (result.same || !result.candidates?.length) return;
            if (typeof view.thumb === 'string' && view.thumb.startsWith('data:image/jpeg;base64,') && view.thumb.length <= 1_000_000) {
              result.capturedImageBase64 = view.thumb.slice('data:image/jpeg;base64,'.length);
            }
            held = true;
            post(result);
          }, onHide: () => { if (!held) { awaitingRemoval = false; post({ kind: 'hide' }); } },
          onHint: report, onStats: stats => {
            const now = clock();
            if (now - lastStats < 5000) return;
            lastStats = now;
            diagnostic('scan_stats', { backend: stats.kind, scanMS: stats.scanMs, captureMS: stats.captureMs, frames: stats.frames });
          } });
        resetRecognition = () => {
          held = false; awaitingRemoval = false; stopLoop?.(); backend.reset?.();
          if (running && stream) stopLoop = beginLoop();
        };
        releaseReview = () => { held = false; awaitingRemoval = true; };
        stopLoop = beginLoop();
        diagnostic('scanner_ready');
        button.hidden = true; report('Live camera ready — hold a card steady.');
      } catch (error) {
        diagnostic('startup_failed', { stage, errorKind: errorKind(error), elapsedMS: clock() - began });
        stopCamera(); backend?.dispose(); backend = null;
        report(`Scanner unavailable: ${text(error?.message) || 'Check your connection and camera permission.'}`);
        button.hidden = false; button.textContent = 'Retry Scanner';
      } finally { starting = false; button.disabled = false; }
    };
    if (config.autoStart) await button.onclick();
  }
  globalThis.CardShowBridge = { install, stop: () => dispose(), resetRecognition: () => resetRecognition(), releaseReview: () => releaseReview(), normalizeView };
})();
