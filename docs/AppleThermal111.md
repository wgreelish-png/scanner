# Build 111: Apple’s recommended camera thermal threshold

Apple does not publish a single internal temperature or a universal thermal band
at which iOS blocks all apps. ProcessInfo thermal bands describe system thermal
conditions. The app reads the current OS band; charging status never selects the
scanner’s mode.

Apple’s documentation recommends:

- At [serious](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/serious), reduce CPU, GPU and I/O demand. Reducing frame rate is one suggested response.
- At [critical](https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum/critical), minimize resource use for interaction and, if possible, stop using peripherals such as the camera.

The scanner now follows that distinction:

| iOS state | Card scanner behavior |
| --- | --- |
| Nominal | Existing normal recognition scheduler and 30 FPS preview target |
| Fair or serious | Reduced recognition/outline scheduling, approximately 5 Hz, and 10 FPS preview target; scanning remains available |
| Critical | Stop recognition and camera capture until the state improves |

Low Power Mode uses reduced scanning. Critical overrides Low Power Mode. Review
and manual search still pause recognition independently of the preview, and
backgrounding still stops capture. Foreground recovery from critical to serious
or fair resumes reduced card scanning when eligible; nominal restores normal
scanning. User pause, an active manual screen and stale callbacks cannot force a
camera restart. The PSA camera shares the critical-only thermal pause and keeps
its existing explicit Retry flow.

This is the app’s implementation of Apple’s recommendation, not a claim that
ProcessInfo critical is the exact point where iOS disables apps. AVFoundation
also has a separate [camera system-pressure shutdown](https://developer.apple.com/documentation/avfoundation/avcapturedevice/systempressurestate-swift.class/level-swift.struct/shutdown)
that can interrupt capture. iOS controls actual camera availability regardless
of this policy. No public internal temperature cutoff is invented or exposed.
Nonessential bulk price work and automatic network polling may still defer at
serious heat, consistent with Apple’s instruction to reduce demand.

For diagnostic 22, iOS reported serious heat while the phone was charging before
scanning started. The earlier policy blocked camera startup there. With build
111 that state selects reduced scanning instead, unless the camera is otherwise
unavailable through iOS. Inventory, saved settings and transactions are unchanged.

The native policy regression covers every thermal band with Low Power Mode both
on and off. Existing bridge regressions exercise reduced startup and critical-mode
pause/recovery, including held review, manual entry, backgrounding and late
camera callbacks. Use injected thermal states for testing; do not intentionally
heat a phone. Sustained physical-device heat and battery results remain pending.

Local validation passed for the changed Swift grammar, Xcode source/resource
membership, build metadata, whitespace and the 47 pinned runtime assets. The
previous build 110 focused camera run passed on GitHub. Build 111’s updated native
thermal-policy cases are dispatched separately; pending checks are not passing
results. This Linux workspace cannot execute XCTest or physical camera APIs.
