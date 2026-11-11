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
    for (const key of ['solid', 'tracked', 'borderRetry', 'borderRetained']) if (typeof value[key] === 'boolean') fields[key] = value[key];
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
  let resumeAfterManualSearchPrompt = () => {};
  let suspendForManualSearch = () => false;
  let resumeAfterManualSearch = () => false;
  let refreshDatabase = () => {};
  let markScanIssue = () => false;
  let setSteadyCardBorder = () => {};
  let setResourceMode = () => false;
  let setCaptureMode = () => false;
  let capturePhoto = async () => false;
  let retakePhoto = async () => false;
  async function install(config) {
    dispose();
    globalThis.CardShowNativeCache = typeof config.cacheToken === 'string' && config.cacheToken.length >= 32 ? { token: config.cacheToken } : null;
    let pending = null;
    let heldRef = null, removalRef = null, removalAbsentSince = null;
    let steadyCardBorder = config.steadyCardBorder === true;
    let manualAttempt = null, manualPromptPending = false;
    let manualSearchSuspended = config.manualSearchSuspended === true;
    let captureMode = config.captureMode === 'photo' ? 'photo' : 'live';
    let photoRestState = ['ready', 'noMatch', 'failed'].includes(config.photoReviewState) ? config.photoReviewState : 'failed';
    let photoFramingRequested = captureMode === 'photo' && !['ready', 'noMatch', 'failed'].includes(config.photoReviewState);
    let photoGeneration = 0, photoOperation = null, photoState = 'off', imageCandidates = null;

    const validResourceMode = value => ['normal', 'reduced', 'cooling'].includes(value);
    let resourceMode = validResourceMode(config.resourceMode) ? config.resourceMode : 'normal';
    let foreground = config.foreground !== false;
    let thermalResumePending = resourceMode === 'cooling' || !foreground;
    let resumeRequested = false, startupFailed = false, retiredPlayback = false, retiredResourceAcquisition = false, preserveRetiredReview = false, loopGeneration = 0;
    let pack = null, backendPack = null, cacheWarning = false;
    let latestScan = null, heldScan = null;
    let running = true, stopLoop = null, stream = null, backend = null, overlay = null, starting = false, held = false, awaitingRemoval = false, beginLoop = null;
    const post = message => { if (running) window.webkit?.messageHandlers?.scanResult?.postMessage({ ...message, nonce: config.nonce }); };
    const diagnostic = (event, fields = {}) => post({ kind: 'diagnostic', event, ...fields });
    const clock = () => globalThis.performance?.now?.() ?? Date.now();
    const cooling = () => resourceMode === 'cooling';
    const coolingMessage = 'Cooling down… Scanning resumes when your iPhone is ready.';
    const eligible = () => running && foreground && !manualSearchSuspended && !cooling() && !document.hidden;
    const recognitionEligible = () => eligible() && captureMode === 'live' && !held && !manualPromptPending;
    const emitPhotoState = state => {
      if (!running || (captureMode !== 'photo' && state !== 'off')) return;
      photoState = state;
      if (['ready', 'noMatch', 'failed'].includes(state)) photoRestState = state;
      post({ kind: 'photoState', photoState: state });
    };
    const cancelPhoto = () => {
      photoGeneration++;
      // The worker can be stopped; a main-thread synchronous OpenCV pass cannot
      // be preempted, but its result is still fenced. Keep the already-loaded pack.
      const owner = photoOperation;
      if (owner && !owner.cancelled) {
        owner.cancelled = true; owner.backend?.dispose();
        if (backend === owner.backend) { backend = null; backendPack = null; }
      }
    };

    const stopRecognition = () => { loopGeneration++; stopLoop?.(); stopLoop = null; };
    // One active track operation and one latest pending request. Camera promises
    // cannot be cancelled; stream/owner fences prevent a retired completion from
    // changing a replacement stream or announcing a stale setting as applied.
    let cameraWorkload = null, pendingCameraWorkload = null, cameraWorkloadOwner = null, appliedCameraTarget = null;
    // A native sheet pauses recognition, not the camera visible behind it.
    // Keep its preview responsive while retaining the reduced-power policy.
    const previewFPS = () => resourceMode === 'reduced' ? 10 : 30;
    const workloadFields = (request, constraintState) => {
      const fields = { resourceMode: request.mode, captureState: request.state, targetFPS: request.fps,
        processingActive: request.processing, constraintState };
      try {
        const actual = request.track?.getSettings?.().frameRate;
        if (typeof actual === 'number' && Number.isFinite(actual) && actual >= 0 && actual <= 240) fields.cameraFPS = Math.round(actual * 1000) / 1000;
      } catch (_) { /* Optional camera facts must never interrupt scanning. */ }
      return fields;
    };
    const currentWorkload = request => running && cameraWorkload === request && stream === request.stream && request.track?.readyState !== 'ended';
    const drainCameraWorkload = async () => {
      if (cameraWorkloadOwner) return;
      const owner = {}; cameraWorkloadOwner = owner;
      try {
        while (cameraWorkloadOwner === owner && pendingCameraWorkload) {
          const request = pendingCameraWorkload; pendingCameraWorkload = null;
          if (!currentWorkload(request)) continue;
          if (appliedCameraTarget?.stream === request.stream && appliedCameraTarget.track === request.track && appliedCameraTarget.fps === request.fps) {
            diagnostic('camera_workload', workloadFields(request, 'applied')); continue;
          }
          if (typeof request.track?.applyConstraints !== 'function') {
            diagnostic('camera_workload', workloadFields(request, 'unsupported')); continue;
          }
          try {
            // A rejected change leaves its effective state uncertain. A later
            // request must not reuse a successful target from before that try.
            appliedCameraTarget = null;
            await request.track.applyConstraints({ frameRate: { ideal: request.fps, max: request.fps } });
            if (cameraWorkloadOwner === owner && running && stream === request.stream && request.track.readyState !== 'ended') {
              appliedCameraTarget = { stream: request.stream, track: request.track, fps: request.fps };
            }
            if (currentWorkload(request)) diagnostic('camera_workload', workloadFields(request, 'applied'));
          } catch (_) {
            if (currentWorkload(request)) diagnostic('camera_workload', workloadFields(request, 'failed'));
          }
        }
      } finally {
        if (cameraWorkloadOwner === owner) cameraWorkloadOwner = null;
      }
    };
    const updateCameraWorkload = () => {
      const state = !running || !stream || cooling() || !foreground || document.hidden ? 'stopped'
        : manualSearchSuspended ? 'manual' : held ? 'review' : manualPromptPending ? 'prompt' : 'live';
      const fps = state === 'stopped' ? 0 : previewFPS();
      const processing = !!stopLoop && recognitionEligible();
      const key = [resourceMode, state, fps, processing].join('|');
      if (cameraWorkload?.stream === stream && cameraWorkload.key === key) return;
      const track = stream?.getVideoTracks?.()[0] ?? stream?.getTracks?.()[0] ?? null;
      const request = { stream, track, mode: resourceMode, state, fps, processing, key };
      cameraWorkload = request; pendingCameraWorkload = fps > 0 ? request : null;
      diagnostic('camera_workload', workloadFields(request, fps > 0 ? 'pending' : 'inactive'));
      if (fps > 0) void drainCameraWorkload();
    };
    // The existing frame seam bounds capture, motion analysis, recognition and
    // overlay work together. Normal mode keeps the runtime's own scheduler.
    const reducedFrame = (source, callback) => {
      let cancelled = false, cancelFrame = () => {};
      const timer = setTimeout(() => {
        if (cancelled || !recognitionEligible()) return;
        if (typeof source.requestVideoFrameCallback === 'function') {
          const id = source.requestVideoFrameCallback(callback);
          cancelFrame = () => source.cancelVideoFrameCallback(id);
        } else {
          const id = requestAnimationFrame(callback);
          cancelFrame = () => cancelAnimationFrame(id);
        }
      }, 200);
      return () => { cancelled = true; clearTimeout(timer); cancelFrame(); };
    };
    // Follow a continuously observed card, not camera-open time. Brief tracking
    // gaps retain the attempt; a longer absence begins another physical attempt.
    const clearManualAttempt = () => { manualAttempt = null; manualPromptPending = false; };
    setSteadyCardBorder = enabled => {
      if (!running || typeof enabled !== 'boolean' || held || manualPromptPending || enabled === steadyCardBorder) return;
      steadyCardBorder = enabled;
      // The option can be changed during startup, before a loop exists. Later
      // changes re-arm geometry in the same already-authorized camera stream.
      if (recognitionEligible() && stream && beginLoop && backend) {
        pending = null; clearManualAttempt(); stopRecognition(); backend?.reset?.(); stopLoop = beginLoop(); updateCameraWorkload();
      }
    };
    const endRemovalWait = (rearm = false) => {
      if (!awaitingRemoval) return;
      awaitingRemoval = false; removalRef = null; removalAbsentSince = null;
      if (rearm) {
        // The upstream loop can still hold the saved art for 2.5 seconds and
        // emit only same:true for the next copy/reprint. A verified absence is
        // a new physical episode: require a fresh full candidate payload.
        pending = null; stopRecognition(); backend?.reset?.();
        if (recognitionEligible() && stream && beginLoop) { stopLoop = beginLoop(); updateCameraWorkload(); }
      }
      post({ kind: 'hide' });
    };
    const observeCard = () => {
      if (!eligible() || !stream || held || awaitingRemoval) return;
      const now = clock();
      if (!manualAttempt || now - manualAttempt.last > 1000) manualAttempt = { since: now, last: now, offered: false, queued: false };
      manualAttempt.last = now;
      if (manualPromptPending || manualAttempt.offered || manualAttempt.queued || now - manualAttempt.since < 4000) return;
      const attempt = manualAttempt;
      attempt.queued = true;
      // Stats precede onShow in a scan callback. Let a settled recognition from
      // that same callback take priority over showing the manual-search prompt.
      Promise.resolve().then(() => {
        if (manualAttempt !== attempt) return;
        attempt.queued = false;
        if (!eligible() || !stream || held || awaitingRemoval || manualPromptPending || clock() - attempt.last > 1000) return;
        attempt.offered = true; manualPromptPending = true; pending = null;
        stopRecognition(); updateCameraWorkload();
        post({ kind: 'manualSearchSuggested' });
      });
    };
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
      startupFailed = true;
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
    root.style.cssText = 'position:fixed;inset:0;overflow:hidden;z-index:2147483647;background:#000;color:white;font:16px system-ui;box-sizing:border-box';
    const button = document.createElement('button');
    button.textContent = 'Open Game Database & Start Camera';
    // Native UI already shows startup progress. Keep the camera surface clear;
    // this page button is needed only for explicit manual startup or recovery.
    button.hidden = config.autoStart === true;
    button.style.cssText = 'position:absolute;top:42%;left:24px;right:24px;z-index:2;font:600 17px system-ui;min-height:52px;border-radius:12px';
    const hint = document.createElement('div'); hint.setAttribute('role', 'status'); hint.style.cssText = 'position:absolute;top:calc(42% + 68px);left:24px;right:24px;z-index:2;text-align:center;pointer-events:none';
    const frame = document.createElement('div'); frame.style.cssText = 'position:absolute;inset:0;overflow:hidden;background:#000';
    const video = document.createElement('video'); video.muted = true; video.autoplay = true; video.playsInline = true;
    // Resolve the preview box before metadata/first playback; intrinsic video
    // dimensions and the inline baseline must never size the camera surface.
    video.style.cssText = 'position:absolute;inset:0;display:block;width:100%;height:100%;object-fit:cover;object-position:center;background:#000';
    const canvas = document.createElement('canvas'); canvas.style.cssText = 'position:absolute;inset:0;display:block;width:100%;height:100%;pointer-events:none';
    const still = document.createElement('canvas'); still.hidden = true;
    still.style.cssText = 'position:absolute;inset:0;display:none;width:100%;height:100%;object-fit:contain;background:#000;pointer-events:none';
    frame.append(video, canvas, still); root.append(frame, button, hint); document.body.append(root);
    const clearStill = () => { still.hidden = true; still.style.display = 'none'; still.width = still.height = 1; };

    const report = value => { value = cooling() ? coolingMessage : value; hint.hidden = config.autoStart === true || !!stream; hint.textContent = text(value); post({ kind: 'status', message: text(value) }); };
    const stopCamera = (preserveReview = false) => {
      loopGeneration++;
      const promptPending = preserveReview && manualPromptPending;
      clearManualAttempt(); manualPromptPending = promptPending; removalAbsentSince = null;
      if (!preserveReview) { heldRef = removalRef = null; heldScan = null; }
      stopRecognition(); stream?.getTracks().forEach(t => t.stop()); stream = null;
      // A hung browser operation on a stopped track cannot block its replacement.
      cameraWorkloadOwner = null; pendingCameraWorkload = null; appliedCameraTarget = null;
      video.srcObject = null; overlay?.destroy?.(); overlay = null; latestScan = null; updateCameraWorkload();
    };
    const visibility = () => {
      if (document.hidden) {
        diagnostic('camera_backgrounded'); pending = null;
        if (captureMode === 'photo') { cancelPhoto(); if (photoState === 'processing') photoRestState = 'failed'; }
        stopCamera(); post({ kind: 'hide' });
        if (captureMode === 'photo') emitPhotoState(photoFramingRequested ? 'off' : photoRestState);

        button.disabled = false; button.hidden = false; button.textContent = 'Resume Camera';
      } else if (eligible() && (resumeRequested || thermalResumePending) && !starting) {
        resumeRequested = false;
        void resumeAfterManualSearch(config.nonce);
      }
    };
    document.addEventListener('visibilitychange', visibility);
    dispose = () => { diagnostic('bridge_stopped'); cancelPhoto(); clearStill(); pending = null; stopCamera(); running = false; backend?.dispose(); backend = null; pack = null; root.remove(); document.removeEventListener('visibilitychange', visibility); window.removeEventListener?.('error', onError); window.removeEventListener?.('unhandledrejection', onRejection); };
    suspendForManualSearch = expectedNonce => {
      if (!running || (expectedNonce !== undefined && expectedNonce !== config.nonce)) return false;
      manualSearchSuspended = true; resumeRequested = false; loopGeneration++;
      clearManualAttempt(); pending = null; held = false; heldRef = removalRef = removalAbsentSince = null;
      heldScan = latestScan = null; awaitingRemoval = false;
      stopRecognition(); backend?.reset?.(); overlay?.clear(); updateCameraWorkload();
      if (captureMode === 'photo') {
        cancelPhoto(); if (photoState === 'processing') photoRestState = 'failed';
        stopCamera(); emitPhotoState(photoFramingRequested ? 'off' : photoRestState);
      }
      // Startup can still be awaiting camera playback. Retire that acquisition;
      // a ready preview stays mounted and keeps its already-authorized stream.
      if (starting) { retiredPlayback = stream !== null; stopCamera(); }
      return true;
    };
    resumeAfterManualSearch = async expectedNonce => {
      if (!running || startupFailed || (expectedNonce !== undefined && expectedNonce !== config.nonce)) return false;
      manualSearchSuspended = false;
      if (cooling()) { thermalResumePending = true; report(coolingMessage); if (captureMode === 'photo') emitPhotoState('cooling'); return true; }
      if (captureMode === 'photo' && !photoFramingRequested) { emitPhotoState(photoRestState); return true; }
      // Sheet dismissal can precede WebKit's visibility notification. Remember
      // this explicit resume, without acquiring a camera in a hidden document.
      if (document.hidden || !foreground) { resumeRequested = true; return true; }
      if (starting) { resumeRequested = true; return true; }
      if (stream && beginLoop && backend) {
        stopRecognition(); backend.reset?.(); if (recognitionEligible()) stopLoop = beginLoop(); updateCameraWorkload();
      } else await button.onclick();
      return true;
    };
    setResourceMode = (mode, expectedNonce, isForeground = foreground) => {
      if (!running || !validResourceMode(mode) || expectedNonce !== config.nonce || typeof isForeground !== 'boolean') return false;
      const previous = resourceMode, wasForeground = foreground;
      resourceMode = mode; foreground = isForeground;
      if (cooling() || !foreground) {
        if (captureMode === 'photo') {
          cancelPhoto(); if (photoState === 'processing') photoRestState = 'failed';
          emitPhotoState(cooling() ? 'cooling' : (photoFramingRequested ? 'off' : photoRestState));
        }
        thermalResumePending = true; pending = null;
        if (starting) retiredResourceAcquisition = true;
        if (starting && stream) { retiredPlayback = true; preserveRetiredReview = true; }
        stopCamera(true); backend?.reset?.(); if (cooling()) report(coolingMessage);
      } else if ((previous === 'cooling' || !wasForeground) && thermalResumePending) {
        if (eligible() && !startupFailed) void resumeAfterManualSearch(config.nonce);
      } else if (previous !== mode && eligible() && stream && beginLoop && backend) {
        pending = null; stopRecognition(); backend.reset?.(); if (recognitionEligible()) stopLoop = beginLoop();
      }
      updateCameraWorkload();
      return true;
    };
    const photoCurrent = (token, sourcePack) => running && captureMode === 'photo' && eligible() &&
      photoGeneration === token && pack === sourcePack;
    capturePhoto = async expectedNonce => {
      if (!running || expectedNonce !== config.nonce || captureMode !== 'photo' || !eligible() || starting ||
          photoOperation || !photoFramingRequested || !stream || photoState !== 'framing' || !backend || !imageCandidates) return false;
      const token = ++photoGeneration, sourcePack = pack, owner = { backend, cancelled: false }; photoOperation = owner;
      let bitmap = null;
      photoFramingRequested = false; pending = null; held = false; awaitingRemoval = false;
      clearManualAttempt(); post({ kind: 'hide' });
      try {
        // Copy pixels before stopping tracks: decoding a bitmap from a stopped
        // video element races its availability on WebKit. This canvas is bounded.
        const w = video.videoWidth, h = video.videoHeight;
        if (!Number.isFinite(w) || !Number.isFinite(h) || w < 1 || h < 1) throw new Error('No frame');
        const scale = Math.min(1, 2048 / Math.max(w, h));
        still.width = Math.max(1, Math.floor(w * scale)); still.height = Math.max(1, Math.floor(h * scale));
        const context = still.getContext('2d', { alpha: false });
        if (!context) throw new Error('No canvas');
        context.drawImage(video, 0, 0, still.width, still.height); still.hidden = false; still.style.display = 'block';
        stopCamera(true); emitPhotoState('processing'); report('Scanning photo…');
        bitmap = await createImageBitmap(still);
        if (!photoCurrent(token, sourcePack)) return false;
        const result = await owner.backend.scanImage(bitmap, { maxCards: 1 });
        // The backend owns/closes the submitted bitmap. close() below is also
        // safe on a detached bitmap and covers a backend throwing before transfer.
        if (!photoCurrent(token, sourcePack)) return false;
        const match = result?.cards?.[0]?.result;
        const cands = match?.best ? imageCandidates(sourcePack, match, 5) : [];
        const winner = cands[0];
        const update = winner ? normalizeView({ ref: winner.tuple, cands,
          confidence: winner.confidence ?? match.confidence ?? match.best.confidence,
          accepted: match.accepted === true, printing: { state: winner.printingState ?? match.best.printing?.state } }) : null;
        if (!update?.candidates?.length || update.confidence < 50) {
          emitPhotoState('noMatch'); report('No clear match. Take another photo or search manually.'); return true;
        }
        // A finite still-image pass is its own observation. Do not synthesize
        // repeated live frames or raise acceptance/confidence from a single image.
        held = true; heldRef = update.candidates[0].ref;
        heldScan = { at: clock(), fields: scanMetadata({ matchDistance: match.best.d, matchGap: match.gap }) };
        diagnostic('recognition_snapshot', issueFields());
        emitPhotoState('ready'); post(update); report('Photo ready for review.'); return true;
      } catch (_) {
        if (!photoCurrent(token, sourcePack)) return false;
        stopCamera(true); emitPhotoState('failed'); report('Photo could not be scanned. Take another photo or search manually.'); return true;
      } finally {
        try { bitmap?.close(); } catch (_) { /* Detached/closed bitmaps own no pixels. */ }
        if (photoOperation === owner) photoOperation = null;
      }
    };
    retakePhoto = async expectedNonce => {
      if (!running || expectedNonce !== config.nonce || captureMode !== 'photo' || !eligible() || starting || photoOperation) return false;
      cancelPhoto(); clearStill(); photoFramingRequested = true;
      held = false; heldRef = removalRef = null; awaitingRemoval = false; pending = null; clearManualAttempt();
      post({ kind: 'hide' }); backend?.reset?.();
      if (stream) { emitPhotoState('framing'); return true; }
      await button.onclick(); return !!stream && photoState === 'framing';
    };
    setCaptureMode = (mode, expectedNonce) => {
      if (!running || expectedNonce !== config.nonce || !['live', 'photo'].includes(mode)) return false;
      if (mode === captureMode) return true;
      cancelPhoto(); clearStill(); stopRecognition(); backend?.reset?.();
      captureMode = mode; photoFramingRequested = mode === 'photo';
      held = false; heldRef = removalRef = null; awaitingRemoval = false; pending = null; clearManualAttempt(); post({ kind: 'hide' });
      if (mode === 'photo') emitPhotoState(cooling() ? 'cooling' : stream && !starting ? 'framing' : 'off');
      else emitPhotoState('off');
      if (eligible() && !starting) {
        if (stream && beginLoop && backend) { if (recognitionEligible()) stopLoop = beginLoop(); updateCameraWorkload(); }
        else void button.onclick();
      }
      return true;
    };
    // These remain safe even if a restored photo review needs no camera startup.
    resetRecognition = () => {
      if (captureMode !== 'photo') return;
      held = false; heldRef = null; pending = null; post({ kind: 'hide' }); emitPhotoState(photoRestState);
    };
    releaseReview = () => {
      if (captureMode !== 'photo') return;
      held = false; heldRef = null; pending = null; awaitingRemoval = false;
      if (!photoFramingRequested && !photoOperation) emitPhotoState(photoRestState);
    };
    report('Ready. Saved databases are reused; the first download may be large.');
    button.onclick = async (options = {}) => {
      if (starting || !running) return;
      if (cooling()) { thermalResumePending = true; report(coolingMessage); return; }
      if (!foreground || document.hidden) { thermalResumePending = true; return; }
      starting = true; startupFailed = false; retiredPlayback = false; retiredResourceAcquisition = false; preserveRetiredReview = false; button.disabled = true; button.hidden = true;
      let stage = 'modules', began = clock(), lastStats = -Infinity;
      diagnostic('startup_started');
      try {
        report('Loading scanner modules…');
        const base = '/newscanplus/assets/js/';
        const [packs, backends, overlays, quick, shared, imageResults] = await Promise.all([
          import(base + 'core/pack.js'), import(base + 'app/scan-backends.js'), import(base + 'core/overlay.js'),
          import(base + 'app/quickscan.js'), import(base + 'app/shared.js'), import(base + 'app/desk-results.js')
        ]);
        if (!running) { pack = null; return; }
        diagnostic('modules_ready', { elapsedMS: clock() - began });
        shared.useScope('price'); imageCandidates = imageResults.candidatesFrom;
        if (!pack || options.refreshDatabase) {
          stage = 'pack'; began = clock();
          report(options.refreshDatabase ? 'Checking for database updates…' : 'Opening saved game database…');
          let packStats = null;
          pack = await packs.loadPack(config.game, (loaded, total, stats) => {
            if (!running) return;
            if (stats) packStats = { ...stats };
            if (stats?.downloaded === 0 && stats?.total === 0) report('Using saved game database');
            else report(stats?.label || `Downloading database: ${Math.round(100 * loaded / Math.max(1, total))}%`);
          }, { cacheFirst: !options.refreshDatabase });
          if (!running) { pack = null; return; }
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
          cacheWarning = ['failed', 'unavailable'].includes(cacheFields.cacheState);
          if (cacheWarning) diagnostic('pack_cache_warning', cacheFields);
        }
        stage = 'backend'; began = clock();
        if (!backend) { backend = await backends.createBackend(); backendPack = null; }
        if (!running) { backend.dispose(); return; }
        // A retained backend already owns its pack. Reopening the framing
        // camera must not recopy all recognition shards for each photo.
        if (backendPack !== pack) { backend.setPack(pack); backendPack = pack; }
        diagnostic('backend_ready', { elapsedMS: clock() - began, backend: backend.kind });
        if (!eligible()) { if (cooling()) { report(coolingMessage); if (captureMode === 'photo') emitPhotoState('cooling'); } return; }
        if (captureMode === 'photo' && !photoFramingRequested) {
          emitPhotoState(photoRestState); diagnostic('scanner_ready');
          button.hidden = true; report('Take another photo when you are ready.'); return;
        }
        stage = 'camera'; began = clock(); diagnostic('camera_requested');
        report('Starting rear camera…');
        const acquisitionFPS = previewFPS();
        const cameraOptions = { audio: false, video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 }, frameRate: { ideal: acquisitionFPS, max: acquisitionFPS } } };
        let captured;
        try { captured = await navigator.mediaDevices.getUserMedia(cameraOptions); }
        catch (error) {
          // Older camera implementations may reject a maximum frame rate. Only
          // that constraint may relax; permission/device failures still fail.
          if (error?.name !== 'OverconstrainedError' || error.constraint !== 'frameRate') throw error;
          if (!eligible()) return;
          captured = await navigator.mediaDevices.getUserMedia({ ...cameraOptions,
            video: { ...cameraOptions.video, frameRate: { ideal: acquisitionFPS } } });
        }
        if (!eligible()) { captured.getTracks().forEach(t => t.stop()); return; }
        diagnostic('camera_acquired', { elapsedMS: clock() - began });
        stage = 'video'; began = clock();
        stream = captured; updateCameraWorkload();
        for (const track of stream.getTracks()) track.addEventListener?.('ended', () => {
          if (stream !== captured) return;
          diagnostic('camera_interrupted'); recover();
        }, { once: true });
        video.srcObject = stream; await video.play();
        if (!eligible() || stream !== captured) { stopCamera(preserveRetiredReview || cooling()); return; }
        diagnostic('video_playing', { elapsedMS: clock() - began });
        stage = 'scan';
        overlay = overlays.createOverlay(canvas, { fit: 'cover' });
        // The camera outlines a detection; only the candidate sheet names a card.
        // Avoid flashing an upstream tentative name or cached NM price over video.
        const scanOverlay = {
          setSource: (...args) => overlay?.setSource(...args),
          clear: () => overlay?.clear(),
          draw: options => { if (options?.quad) observeCard(); overlay?.draw({ ...options, label: null }); }
        };
        beginLoop = () => {
          const generation = ++loopGeneration;
          const current = () => recognitionEligible() && generation === loopGeneration;
          const liveOverlay = {
            setSource: (...args) => { if (current()) scanOverlay.setSource(...args); },
            clear: () => { if (current()) scanOverlay.clear(); },
            draw: options => { if (current()) scanOverlay.draw(options); }
          };
          return quick.startQuickScan({ video, overlay: liveOverlay, backend, pack, fetchDetails: null, resolveCandidates: false, retainAcceptedBorder: steadyCardBorder,
          ...(resourceMode === 'reduced' ? { frame: reducedFrame } : {}),
          onShow: view => {
            if (!current() || held || manualPromptPending) return;
            const update = normalizeView(view);
            if (!update.same && !update.candidates?.length) return;
            if (awaitingRemoval) {
              if (update.confidence < 50 ||
                  (!update.same && update.candidates[0].ref === removalRef)) { pending = null; return; }
              if (!removalRef || (update.same && (!pending || pending.ref === removalRef))) return;
            }
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
            // Another card can replace the saved one without an empty frame.
            // Use the normal accepted/guess settling gates for this different
            // full reference; saving must not disable tentative-card review.
            if (awaitingRemoval) endRemovalWait();
            held = true;
            heldRef = pending.ref;
            heldScan = latestScan ? { at: latestScan.at, fields: { ...latestScan.fields } } : null;
            stopRecognition(); updateCameraWorkload();
            diagnostic('recognition_settled', { elapsedMS: now - pending.since, frames: pending.observations });
            diagnostic('recognition_snapshot', issueFields());
            post(pending.result);
            pending = null;
          }, onHide: () => {
            if (!current()) return;
            if (!held) {
              pending = null;
              // Motion or an expired guess can hide the upstream panel without
              // removing the physical card. Only observed absence or another
              // settled accepted card releases the post-save wait.
              if (!awaitingRemoval && !manualPromptPending) post({ kind: 'hide' });
            }
          },
          onHint: value => { if (current()) report(value); }, onStats: stats => {
            if (!current()) return;
            const now = clock();
            const fields = scanStats(stats);
            if (awaitingRemoval) {
              if (fields.solid === false) {
                if (removalAbsentSince === null) removalAbsentSince = now;
                else if (now - removalAbsentSince >= 300) endRemovalWait(true);
              } else if (fields.solid === true) removalAbsentSince = null;
            }
            if (fields.solid === true) observeCard();
            if (!Object.keys(fields).length) return;
            latestScan = { at: now, fields };
            if (fields.borderRetry === true) diagnostic('border_retry', fields);
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
        };
        resetRecognition = () => {
          if (captureMode === 'photo') { held = false; pending = null; emitPhotoState(photoRestState); return; }
          clearManualAttempt(); pending = null; held = false; heldRef = removalRef = removalAbsentSince = null; heldScan = null; latestScan = null; awaitingRemoval = false; stopRecognition(); backend?.reset?.();
          if (recognitionEligible() && stream) stopLoop = beginLoop();
          updateCameraWorkload();
        };
        releaseReview = ref => {
          if (captureMode === 'photo') {
            held = false; heldRef = null; pending = null; awaitingRemoval = false;
            if (!photoFramingRequested && !photoOperation) emitPhotoState(photoRestState);
            return;
          }
          if (awaitingRemoval) return;
          clearManualAttempt(); pending = null;
          removalRef = typeof ref === 'string' && referencePattern.test(ref) ? ref : heldRef;
          heldRef = null; removalAbsentSince = null;
          held = false; heldScan = null; awaitingRemoval = true;
          // Re-arm full payloads after the frozen review without reopening the
          // mounted, already-authorized camera or reloading the database.
          stopRecognition(); backend?.reset?.();
          if (recognitionEligible() && stream) stopLoop = beginLoop();
          updateCameraWorkload();
        };
        resumeAfterManualSearchPrompt = () => {
          manualPromptPending = false; pending = null;
          // A match reached while the popup was open may now emit only partial
          // same:true updates. Re-arm the loop for a full payload, retaining this
          // attempt's offered flag and the already-authorized camera stream.
          stopRecognition(); backend?.reset?.();
          if (recognitionEligible() && stream) stopLoop = beginLoop();
          updateCameraWorkload();
        };
        if (recognitionEligible()) stopLoop = beginLoop();
        updateCameraWorkload();
        thermalResumePending = false;
        diagnostic('scanner_ready');
        if (captureMode === 'photo') emitPhotoState('framing');
        button.hidden = true; report(cacheWarning ? 'Camera ready. Database could not be saved; it may download again next time.' : captureMode === 'photo' ? 'Frame one card, then take a photo.' : 'Live camera ready — hold a card steady.'); hint.hidden = true;
      } catch (error) {
        if (!running || (retiredPlayback && stage === 'video' && error?.name === 'AbortError') ||
            (retiredResourceAcquisition && stage === 'camera' && error?.name === 'NotAllowedError')) return;
        startupFailed = true; resumeRequested = false;
        diagnostic('startup_failed', { stage, errorKind: errorKind(error), elapsedMS: clock() - began });
        stopCamera(); backend?.dispose(); backend = null;
        if (captureMode === 'photo') emitPhotoState('failed');
        report(`Scanner unavailable: ${text(error?.message) || 'Check your connection and camera permission.'}`);
        button.hidden = false; button.textContent = 'Retry Scanner';
      } finally {
        starting = false; button.disabled = false;
        if (!running || stream) resumeRequested = false;
        if ((resumeRequested || thermalResumePending) && eligible() && !stream && !startupFailed && (captureMode !== 'photo' || photoFramingRequested)) {
          resumeRequested = false;
          await button.onclick();
        }
      }
    };
    refreshDatabase = () => {
      if (!eligible() || starting || held) return;
      stopCamera(); pending = null; awaitingRemoval = false;
      backend?.dispose(); backend = null;
      return button.onclick({ refreshDatabase: true });
    };
    if (captureMode === 'photo') emitPhotoState(cooling() ? 'cooling' : (photoFramingRequested ? 'off' : photoRestState));
    if (config.autoStart) await button.onclick();
  }
  globalThis.CardShowBridge = { install, stop: () => dispose(), resetRecognition: () => resetRecognition(), releaseReview: ref => releaseReview(ref), resumeAfterManualSearchPrompt: () => resumeAfterManualSearchPrompt(), suspendForManualSearch: nonce => suspendForManualSearch(nonce), resumeAfterManualSearch: nonce => resumeAfterManualSearch(nonce), setResourceMode: (mode, nonce, foreground) => setResourceMode(mode, nonce, foreground), refreshDatabase: () => refreshDatabase(), markScanIssue: reason => markScanIssue(reason), setSteadyCardBorder: enabled => setSteadyCardBorder(enabled), setCaptureMode: (mode, nonce) => setCaptureMode(mode, nonce), capturePhoto: nonce => capturePhoto(nonce), retakePhoto: nonce => retakePhoto(nonce), normalizeView };
})();
