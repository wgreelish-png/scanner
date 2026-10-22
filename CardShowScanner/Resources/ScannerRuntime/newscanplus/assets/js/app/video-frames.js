/**
 * video-frames.js - downscaled RGBA reads of the camera <video> for the main thread.
 * createFrameReader() -> {read(video, longSide) -> {data, width, height} | null}
 * Every read returns a fresh buffer, so it may be transferred to a worker.
 */
export function createFrameReader() {
    let canvas = null;
    let ctx = null;
    return {
        read(video, longSide) {
            const vw = video.videoWidth;
            const vh = video.videoHeight;
            if (!vw || !vh || video.readyState < 2) return null;
            const s = Math.min(1, longSide / Math.max(vw, vh));
            const w = Math.round(vw * s);
            const h = Math.round(vh * s);
            if (!canvas || canvas.width !== w || canvas.height !== h) {
                canvas = typeof OffscreenCanvas === 'function' ? new OffscreenCanvas(w, h) : Object.assign(document.createElement('canvas'), { width: w, height: h });
                ctx = canvas.getContext('2d');
                ctx.imageSmoothingEnabled = true;
                ctx.imageSmoothingQuality = 'high';
            }
            ctx.drawImage(video, 0, 0, w, h);
            return { data: ctx.getImageData(0, 0, w, h).data, width: w, height: h };
        },
    };
}
