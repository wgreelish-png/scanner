/* App-owned adapter for the user-authorized TCGTracking module integration.
 * Uses module exports observed in the supplied source; no DOM scraping or endpoint reimplementation.
 * Loaded from bundled resources on the app's stable loopback origin.
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
  // Diagnostic metadata is a separate scalar-only channel. Never forward an
  // arbitrary backend object, image, card tuple or free-form error text.
  function scanMetadata(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
    const fields = {};
    for (const key of ['solid', 'tracked']) if (typeof value[key] === 'boolean') fields[key] = value[key];
    for (const [key, allowed] of [['scanStage', ['none', 'one', 'quick', 'full']], ['quadSource', ['none', 'detected', 'selected']]]) {
      if (allowed.includes(value[key])) fields[key] = value[key];
    }
    for (const key of ['rawQuads', 'rejectedQuads', 'candidateQuads', 'selectedBase']) {
      if (Number.isInteger(value[key]) && value[key] >= 0 && value[key] <= 1_000_000) fields[key] = value[key];
    }
    for (const [key, maximum] of [['quadAspect', 1], ['quadArea', 1], ['quadSupport', 1], ['meanLuma', 255], ['lumaStd', 128], ['matchDistance', 100], ['matchGap', 100]]) {
      const n = value[key];
      if (typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= maximum) fields[key] = Math.round(n * 1000) / 1000;
    }
    return fields;
  }
  function scanStats(stats) {
    if (!stats || typeof stats !== 'object' || Array.isArray(stats)) return {};
    const fields = scanMetadata(stats.diagnostics);
    if (['worker', 'main'].includes(stats.kind)) fields.backend = stats.kind;
    if (['', 'one', 'quick', 'full'].includes(stats.stage)) fields.scanStage = stats.stage || 'none';
    if (typeof stats.tracked === 'boolean') fields.tracked = stats.tracked;
    for (const [key, input, maximum] of [['scanMS', 'scanMs', 86400000], ['captureMS', 'captureMs', 86400000], ['frames', 'frames', 1_000_000]]) {
      const n = stats[input];
      if (typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= maximum && (key !== 'frames' || Number.isInteger(n))) fields[key] = n;
    }
    return fields;
  }
  let dispose = () => {};
  let resetRecognition = () => {};
  let releaseReview = () => {};
  let refreshDatabase = () => {};
  let markScanIssue = () => false;
  async function install(config) {
    dispose();
    globalThis.CardShowNativeCache = typeof config.cacheToken === 'string' && config.cacheToken.length >= 32 ? { token: config.cacheToken } : null;
    let pending = null;
    let latestScan = null, heldScan = null;
    let running = true, stopLoop = null, stream = null, backend = null, overlay = null, starting = false, held = false, awaitingRemoval = false, beginLoop = null;
    const post = message => { if (running) window.webkit?.messageHandlers?.scanResult?.postMessage({ ...message, nonce: config.nonce }); };
    const diagnostic = (event, fields = {}) => post({ kind: 'diagnostic', event, ...fields });
    const clock = () => globalThis.performance?.now?.() ?? Date.now();
    const issueFields = () => {
      const snapshot = held ? heldScan : latestScan;
      if (!snapshot) return {};
      const age = clock() - snapshot.at;
      if (!Number.isFinite(age) || age < 0) return {};
      return { ...(age <= 15000 ? snapshot.fields : {}), sampleAgeMS: Math.min(600000, Math.floor(age)) };
    };
    markScanIssue = reason => {
      if (!running || !stream || !backend || !beginLoop || !['top_loader', 'dark_card', 'wrong_border'].includes(reason)) return false;
      diagnostic('scan_issue', { issueReason: reason, ...issueFields() });
      return true;
    };
    const errorKind = error => ['NotAllowedError', 'NotFoundError', 'NotReadableError', 'AbortError', 'SecurityError', 'TypeError', 'RangeError'].includes(error?.name) ? error.name : 'Error';
    const recover = () => {
      if (!running || !stream) return;
      pending = null; stopCamera(); backend?.dispose(); backend = null;
      report('Camera interrupted. Tap Retry Scanner to continue.');
      button.disabled = false; button.hidden = false; button.textContent = 'Retry Scanner';
    };
    const onError = event => { diagnostic('javascript_error', { errorKind: errorKind(event.error) }); recover(); };
    const onRejection = event => { diagnostic('javascript_rejection', { errorKind: errorKind(event.reason) }); recover(); };
    window.addEventListener?.('error', onError);
    window.addEventListener?.('unhandledrejection', onRejection);
    diagnostic('bridge_ready');
    const root = document.createElement('section');
    root.style.cssText = 'position:fixed;inset:0;z-index:2147483647;background:#111;color:white;font:16px system-ui;box-sizing:border-box';
    const button = document.createElement('button');
    button.textContent = 'Open Game Database & Start Camera';
    button.style.cssText = 'position:absolute;top:42%;left:24px;right:24px;z-index:2;font:600 17px system-ui;min-height:52px;border-radius:12px';
    const hint = document.createElement('div'); hint.setAttribute('role', 'status'); hint.style.cssText = 'position:absolute;top:calc(42% + 68px);left:24px;right:24px;z-index:2;text-align:center;pointer-events:none';
    const frame = document.createElement('div'); frame.style.cssText = 'position:absolute;inset:0';
    const video = document.createElement('video'); video.muted = true; video.autoplay = true; video.playsInline = true;
    video.style.cssText = 'width:100%;height:100%;object-fit:cover';
    const canvas = document.createElement('canvas'); canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;pointer-events:none';
    frame.append(video, canvas); root.append(frame, button, hint); document.body.append(root);
    const report = value => { hint.hidden = !!stream; hint.textContent = text(value); post({ kind: 'status', message: text(value) }); };
    const stopCamera = () => { stopLoop?.(); stopLoop = null; stream?.getTracks().forEach(t => t.stop()); stream = null; video.srcObject = null; overlay?.destroy?.(); overlay = null; latestScan = null; heldScan = null; };
    const visibility = () => { if (document.hidden) { diagnostic('camera_backgrounded'); pending = null; stopCamera(); post({ kind: 'hide' }); button.disabled = false; button.hidden = false; button.textContent = 'Resume Camera'; } };
    document.addEventListener('visibilitychange', visibility);
    dispose = () => { diagnostic('bridge_stopped'); running = false; pending = null; stopCamera(); backend?.dispose(); backend = null; root.remove(); document.removeEventListener('visibilitychange', visibility); window.removeEventListener?.('error', onError); window.removeEventListener?.('unhandledrejection', onRejection); };
    report('Ready. Saved databases are reused; the first download may be large.');
    button.onclick = async (options = {}) => {
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
        stage = 'pack'; began = clock();
        report(options.refreshDatabase ? 'Checking for database updates…' : 'Opening saved game database…');
        let packStats = null;
        const pack = await packs.loadPack(config.game, (loaded, total, stats) => {
          if (!running) return;
          if (stats) packStats = { ...stats };
          if (stats?.downloaded === 0 && stats?.total === 0) report('Using saved game database');
          else report(stats?.label || `Downloading database: ${Math.round(100 * loaded / Math.max(1, total))}%`);
        }, { cacheFirst: !options.refreshDatabase });
        if (!running) return;
        const cachedShards = (packStats?.cachedHashShards || 0) + (packStats?.cachedMetaShards || 0);
        const cacheFields = {
          downloadedBytes: Number.isFinite(packStats?.downloaded) ? packStats.downloaded : 0,
          cachedShards,
          cacheState: ['ok', 'failed', 'unavailable'].includes(packStats?.cache) ? packStats.cache : 'unknown',
          cacheSource: !packStats ? 'unknown' : !packStats.downloaded ? 'cache' : cachedShards ? 'mixed' : 'download',
          storagePersisted: packStats?.storage?.persisted === true,
          cacheBackend: packStats?.cacheBackend === 'native' ? 'native' : 'indexeddb'
        };
        diagnostic('pack_ready', { elapsedMS: clock() - began, ...cacheFields });
        const cacheWarning = ['failed', 'unavailable'].includes(cacheFields.cacheState);
        if (cacheWarning) diagnostic('pack_cache_warning', cacheFields);
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
        stream = captured;
        for (const track of stream.getTracks()) track.addEventListener?.('ended', () => {
          if (stream !== captured) return;
          diagnostic('camera_interrupted'); recover();
        }, { once: true });
        video.srcObject = stream; await video.play();
        if (!running) { stopCamera(); return; }
        diagnostic('video_playing', { elapsedMS: clock() - began });
        stage = 'scan';
        overlay = overlays.createOverlay(canvas, { fit: 'cover' });
        // The camera outlines a detection; only the candidate sheet names a card.
        // Avoid flashing an upstream tentative name or cached NM price over video.
        const scanOverlay = {
          setSource: (...args) => overlay?.setSource(...args),
          clear: () => overlay?.clear(),
          draw: options => overlay?.draw({ ...options, label: null })
        };
        beginLoop = () => quick.startQuickScan({ video, overlay: scanOverlay, backend, pack, fetchDetails: null, resolveCandidates: false,
          onShow: view => {
            if (held || awaitingRemoval) return;
            const update = normalizeView(view);
            if (!update.same && !update.candidates?.length) return;
            const now = clock();
            if (!update.same) {
              const ref = update.candidates[0].ref;
              if (!pending || pending.ref !== ref || now - pending.last > 1200) {
                pending = { ref, since: now, observations: 0, last: now, result: update };
              }
              pending.result = update;
              if (typeof view.thumb === 'string' && view.thumb.startsWith('data:image/jpeg;base64,') && view.thumb.length <= 1_000_000) {
                pending.result.capturedImageBase64 = view.thumb.slice('data:image/jpeg;base64,'.length);
              }
            }
            if (!pending) return;
            if (now - pending.last > 1200) { pending.since = now; pending.observations = 0; }
            pending.last = now;
            if (update.confidence < 50) { pending.observations = 0; pending.since = now; return; }
            pending.observations++;
            pending.result.accepted = update.accepted;
            pending.result.confidence = update.confidence;
            // same:true contains no tuples: retain the full candidate snapshot.
            // Require repeated observations, never a timer firing on a stale frame.
            const settled = pending.observations >= 3 && now - pending.since >= (update.accepted ? 600 : 1500);
            if (!settled || update.confidence < 50) return;
            held = true;
            heldScan = latestScan ? { at: latestScan.at, fields: { ...latestScan.fields } } : null;
            diagnostic('recognition_settled', { elapsedMS: now - pending.since, frames: pending.observations });
            diagnostic('recognition_snapshot', issueFields());
            post(pending.result);
            pending = null;
          }, onHide: () => { if (!held) { pending = null; awaitingRemoval = false; post({ kind: 'hide' }); } },
          onHint: report, onStats: stats => {
            if (!running) return;
            const now = clock();
            const fields = scanStats(stats);
            if (!Object.keys(fields).length) return;
            latestScan = { at: now, fields };
            if (now - lastStats < 5000) return;
            lastStats = now;
            // Whole-frame quality is sampled only for this five-second event.
            // The callback reads the existing small frame without retaining it.
            let quality = {};
            if (typeof stats.frameQuality === 'function') {
              try {
                const sampled = scanMetadata(stats.frameQuality());
                for (const key of ['meanLuma', 'lumaStd']) if (key in sampled) quality[key] = sampled[key];
              } catch (_) { /* diagnostics must not interrupt recognition */ }
            }
            diagnostic('scan_stats', { ...fields, ...quality });
          } });
        resetRecognition = () => {
          pending = null; held = false; heldScan = null; latestScan = null; awaitingRemoval = false; stopLoop?.(); backend.reset?.();
          if (running && stream) stopLoop = beginLoop();
        };
        releaseReview = () => { pending = null; held = false; heldScan = null; awaitingRemoval = true; };
        stopLoop = beginLoop();
        diagnostic('scanner_ready');
        button.hidden = true; report(cacheWarning ? 'Camera ready. Database could not be saved; it may download again next time.' : 'Live camera ready — hold a card steady.'); hint.hidden = true;
      } catch (error) {
        diagnostic('startup_failed', { stage, errorKind: errorKind(error), elapsedMS: clock() - began });
        stopCamera(); backend?.dispose(); backend = null;
        report(`Scanner unavailable: ${text(error?.message) || 'Check your connection and camera permission.'}`);
        button.hidden = false; button.textContent = 'Retry Scanner';
      } finally { starting = false; button.disabled = false; }
    };
    refreshDatabase = () => {
      if (!running || starting || held) return;
      stopCamera(); pending = null; awaitingRemoval = false;
      return button.onclick({ refreshDatabase: true });
    };
    if (config.autoStart) await button.onclick();
  }
  globalThis.CardShowBridge = { install, stop: () => dispose(), resetRecognition: () => resetRecognition(), releaseReview: () => releaseReview(), refreshDatabase: () => refreshDatabase(), markScanIssue: reason => markScanIssue(reason), normalizeView };
})();
