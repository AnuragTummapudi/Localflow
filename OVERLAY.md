# Native transient island

The existing `OverlayWindowController` and `WaveformOverlayView` now implement
one native SwiftUI/AppKit island. No competing overlay controller, settings
redesign, website change, speech-engine change or new action tool was introduced.

## Design decisions

The direct-build reference lock is the requested native notch/capsule interaction,
the existing LocalFlow typography/ink tokens, and Refero's bundled typography,
motion and accessibility craft references. Live Refero research was unavailable
in this session (the prior query returned `NO_SUBSCRIPTION`). No generated bitmap
assets are needed for this code-native surface.

| Decision | Source and role | Implementation |
| --- | --- | --- |
| Black capsule below the notch | User's notch/native brief | Black surface, continuous 24 pt corners, thin border, restrained shadow; no gradients. |
| Typography and contrast | LocalFlowDesign + typography/craft references | Existing sans helper; 13.5 pt primary, 12 pt status detail, 11 pt hands-free label; light text on black. |
| Compact live hierarchy | User's waveform/text/stop brief | 11 real microphone bars, replacement transcript, Stop; Cancel added for hands-free. |
| Controlled expansion | User's maximum width + performance brief | 16 pt width steps, grow-only within a recording, 560 pt cap further constrained by display width. |
| Long/revised transcript | User's streaming/revision brief | Latest 240 characters with head truncation, complete hypothesis available to accessibility; no append-only UI. |
| Small spring transitions | User's motion brief + Refero motion reference | SwiftUI springs for size/state/waveform, no animated transcript replacement; Reduce Motion removes these and freezes bars. |
| Explicit confirmation | User's confirmation brief | Resolved action/target plus Cancel and Confirm, sharing the existing coordinator pending intent. |
| Truthful action feedback | Existing command API and AGENTS rules | Show Opening/Searching/etc. as acting requests; do not label fire-and-forget execution as verified success. |

## Ownership and display geometry

`Shared/OverlayState.swift` defines hidden, listening, handsFree, thinking, acting,
success, confirmation, error and cancelled phases. Partial transcripts update only
recording states. Terminal transitions clear partials and control availability.
Undo is shown only for the existing hands-free cancellation recovery window.

The panel retains screenSaver level / all Spaces / full-screen auxiliary behavior.
It has the nonactivating style and explicitly cannot become key or main.
The hosting view accepts the first mouse click without needing a key panel;
buttons are not keyboard-focus targets. UI callbacks never activate LocalFlow.
Command execution and text injection retain their existing target activation.

The display under the pointer is selected when the island first appears and stays
anchored through recording/action/confirmation. Screen-parameter notifications
recompute placement; an unplugged display falls back to a current display.
Public `NSScreen.safeAreaInsets` and auxiliary top rectangles identify the physical
notch gap in global coordinates. Missing/empty/inconsistent rectangles use a
centered virtual island below the visible menu-bar boundary. There is no fallback
hardcoded display resolution. The pill sits below safe notch/menu geometry,
with a 12 pt transparent shadow margin included in its panel frame.

Listening uses 48 pt height; status feedback 52 pt; errors 72 pt; confirmation
96 pt. The frame follows the actual visible surface size. Geometry tests cover
physical notches, invalid/missing notch geometry, external-display offsets,
negative coordinates and small display bounds.

## Integration and validation

The coordinator consumes the existing typed streaming events. Stop closes the
same capture/transcription flow. Final results alone resolve commands. Transient
stages show Transcribing, Deciding, Formatting and Sending text. Existing rewrite
messages use the same thinking/success/error surface.

Escape cancels pending confirmation, preserves recording cancellation semantics,
and dismisses idle feedback. Hands-free cancellation retains its 3.5 second Undo
window; Undo starts a fresh session as before. A new recording clears an old
unconfirmed command. Dismissal tasks are cancelled/versioned so old timers cannot
hide a newer presentation.

Build/test commands from the workspace parent:

```sh
swift test --package-path LocalFlow --filter OverlayStateTests
swift test --package-path LocalFlow
xcodebuild -project LocalFlow/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug CODE_SIGNING_ALLOWED=NO build
git -C LocalFlow diff --check
```

The native visual smoke app under ignored `.build/island-validation/` compiles the
actual overlay/design sources and uses test-owned presentation fixtures. It does
not capture microphone audio, access production models/history/settings, inject
text or execute commands. Native click checks exercise Cancel, Undo, Stop and
Confirm; focus reports check unchanged foreground PID, non-key/non-main status
and public screen geometry. The target is smooth native rendering near 60 fps;
tests do not establish a measured frame rate. Multi-monitor hot-plug, VoiceOver
speech and Reduce Motion should also be checked on the corresponding hardware /
accessibility configuration; unit tests and native AX inspection cover their
state/label/geometry boundaries.
