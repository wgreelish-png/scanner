# Full-screen camera preview — build 59

The November 4 screen recording shows white bands at the top and bottom of
the scanner, including after live video appears. Their positions match the
iPhone safe areas. The bundled page lacked `viewport-fit=cover`, while the
WKWebView retained automatic scroll insets and its default white background.

The preview now uses the whole web-view viewport, with black page, web-view,
scroll-view and under-page backgrounds. Automatic content insets and bouncing
are disabled. The video and detection canvas share an explicitly positioned,
full-size box from startup; video metadata cannot introduce an inline baseline
or resize that box. Both retain the existing centered `cover` mapping.

Automatic startup uses the native status panel, keeping the duplicate web
button and progress message out of the middle of the preview. A failed startup
still exposes Retry Scanner. “Starting rear camera…” describes opening the
stream; the native iOS permission flow is unchanged. Pending playback cannot
announce readiness or start recognition after the stream has stopped or the
page has entered the background.

The build-58 diagnostic run used the saved Pokémon database with zero bytes
downloaded, taking 424–878 ms per opening. Camera authorization was already
granted. Repeated navigation entries do not establish an automatic restart
loop, and the log does not contain the viewport measurements needed to prove
the visual cause independently of the recording.

Recognition, source-frame capture, game packs, card matching, saved data and
pricing behavior are unchanged. Local validation is recorded after all edits.
Physical iPhone verification remains necessary: open a new scan, reopen an
existing scan, return from list review and resume after backgrounding. Confirm
the preview fills the screen from its first frame, the safe areas stay black
before playback, and card outlines remain aligned with the live image.

Local validation passed: 46 bridge cases (including four deferred-startup and
interruption regressions), 50 border/cache/maintenance cases, all 47 pinned
assets and their dependency closure, build/revision metadata and whitespace.
Both OpenCV builds retained the existing synthetic decision fingerprint and
source pixels. This Linux environment has no Xcode; native CI and the iPhone
visual checks remain pending. No recognition engine or pinned asset changed.
