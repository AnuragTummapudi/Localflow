> Historical evidence from the preceding architecture. Current macOS 26+ speech and decision behavior is documented in STREAMING.md, VOICE_AGENT.md and CORE_ARCHITECTURE_REPORT.md. Removed speech engines described here are not available in the current app.

# Native app baseline — 3 October 2026

This audit read `../PROJECT_GUIDE.md` first and verified the native Swift source,
manifests, Xcode project/scheme and installed package source. It concerns only
this checkout. No agent, Laya, streaming integration, notch UI, redesign,
dependency upgrade, commit, push, PR, remote modification or deployment was made.

## Git and validation evidence

Initial state: branch `main`, commit `83290ea` (Spotify search behavior and
documentation/assets refresh), with an empty `git status --short` and diff.
There were no existing tracked or untracked user changes in the native repo.

Host inspected: Apple Silicon, macOS 26.6 (`25G72`), Xcode 26.5 (`17F42`),
Swift 6.3.2, macOS 26.5 SDK. LocalFlow specifies tools/language version 5.9
and macOS 14 deployment; FluidAudio itself requires Swift tools 6.0. A macOS
26 SDK is needed to compile named SpeechAnalyzer/FoundationModels APIs even
though execution is availability-gated on older systems.

Commands run from the workspace parent, before any edits:

```sh
swift test --package-path LocalFlow
xcodebuild -project LocalFlow/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

| Check | Original baseline | After test hardening |
| --- | --- | --- |
| Swift XCTest suite | PASS: 87 tests, zero failures | PASS: 93 tests, zero failures |
| Unsigned Xcode Debug build | PASS: BUILD SUCCEEDED | PASS: BUILD SUCCEEDED |
| Dependency locks | Same identity/version/revision pins in both locks | Unchanged |

**Environment failure, separately recorded:** the first sandboxed Swift attempt
exited 1 before compiling application source. It could not write
`~/.cache/clang/ModuleCache` (`Operation not permitted`), then reported an
invalid manifest/unable to load the standard library. Retrying with approved
normal local compiler-cache access passed. This was not a source failure or
an introduced regression. The Xcode builds used normal local build access.

Existing non-fatal diagnostics: SwiftPM reports the dependency's unhandled
`ASR/Parakeet/Unified/benchmark.md`; the original Xcode build reports skipped
App Intents metadata extraction because there is no AppIntents dependency.
Neither warranted a dependency upgrade or unrelated source change.

The four full logs are retained in the ignored directory
`.build/baseline-2026-10-03-0u2bsegy/`. These are local artifacts, not committed files. No app was
launched or microphone capture, editor paste, Spotify control or FoundationModels
generation performed by the audit. The original suite did invoke production
engine preparation; that test could install assets and accepted any thrown error.
It was replaced before final verification. No claim of model-inference or
permission verification is made from the passing test count.

## Build graph and package resolution

`Package.swift` has one executable (`LocalFlowApp`), ten libraries and two test
targets. Xcode has one app target, references the local package at `.`, links
its ten libraries and includes App files/resources in explicit build phases.
Its shared scheme's `Testables` section is empty: use SwiftPM for these tests.

```text
Shared
  <- AudioCapture, HotkeyManager, TextInjection, CommandMode,
     SpeechCleanup, SmartFormatting, Engines
Engines <- FluidAudio + WhisperKit; links Speech
ModelManager <- Shared + Engines
PrivacyDashboard <- Shared + ModelManager
LocalFlowApp <- all ten internal libraries
SharedTests <- Shared + AudioCapture + HotkeyManager + ModelManager + Engines
FeaturesTests <- Shared + CommandMode + SpeechCleanup + SmartFormatting + TextInjection
```

Root `Package.resolved` uses schema 2. Xcode's
`LocalFlow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
uses schema 3 with an origin hash. All nine package pins agree:

| Identity | Version |
| --- | --- |
| fluidaudio | 0.15.5 |
| argmax-oss-swift (WhisperKit product) | 0.18.0 |
| swift-argument-parser | 1.8.2 |
| swift-asn1 | 1.7.1 |
| swift-collections | 1.6.0 |
| swift-crypto | 4.5.1 |
| swift-jinja | 2.4.2 |
| swift-transformers | 1.1.9 |
| yyjson | 0.12.0 |

Manifest `from:` constraints (FluidAudio 0.12.4; argmax 0.9.0) are lower
bounds, not the installed versions. FluidAudio's installed SwiftPM and Xcode
checkouts both have clean working trees and HEAD
`19600a485baa4998812e4654b70d2bab8f2c9949`, matching both locks. WhisperKit's
pin is `e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef`.

## Complete runtime path

1. `LocalFlowApp` and `AppDelegate` use `AppServices.shared`. It shares one
   history and vocabulary store across `DictationCoordinator` and Settings.
   Launch installs the menu bar and onboarding, or prepares already available
   models. Closing windows leaves the app running.
2. The coordinator starts `HotkeyManager`, subscribes to its Combine events,
   and dispatches handling on the main actor. Global/local NSEvent monitors
   observe Option/Fn modifier changes and Escape. Carbon owns Option+1/2;
   an optional Fn event tap suppresses the physical system Fn action.
3. Right Option is the default. Down begins push-to-talk only from idle.
   A second tap within 0.38 seconds starts/promotes hands-free. Up ends
   push-to-talk; holds shorter than 0.35 seconds get a 350 ms grace period.
   Hands-free ignores release and finishes on another down or Finish.
4. `beginDictation` prepares a router engine if needed, then remembers the
   current external app or last external app. Readiness currently means engine
   metadata was selected, not that Core ML weights have loaded. Onboarding
   separately requests microphone and Accessibility permission; `start()`
   itself does not run an authorization prompt/check.
5. `AudioCaptureSession.start` tears down prior resources, creates a fresh
   AVAudioEngine and taps 1024-frame input buffers. Channel 0 is accumulated
   at the hardware input rate in `[Float]` under NSLock. Published levels
   update on the main queue. Stop returns samples plus a reconstructed mono
   PCM buffer; reset clears buffers, counters, waveform and engine state.
6. `OverlayWindowController` reuses a nonactivating NSPanel, at screenSaver
   level across Spaces, anchored 12 points above the bottom of the display
   containing the pointer. `WaveformOverlayModel` smooths capture levels into
   11 bars. This is a waveform/status UI, with hands-free Cancel/Finish,
   cancellation Undo and processing/rewrite/terminal states.
7. Recording has a 30-minute limit. Hands-free polls continuous silence each
   second: after 45 seconds, captured speech finishes; untouched silence
   tears down. Capture energy uses normalized amplitude/frame counts; the
   stopped `CapturedAudio` also checks peak/RMS. These are energy heuristics,
   not FluidAudio VAD. Empty/silent capture bypasses transcription/history.
8. `endDictation` stops recording, enters processing, displays progress and
   starts a 120-second timeout. `TranscriptionRouter` actor forwards the
   complete captured audio to the selected `STTEngine`. There are no partial
   transcript events in LocalFlow's protocol or coordinator.
9. Selection policy: explicit model override first; otherwise macOS 26 Apple
   Speech asset preparation; optional already-on-disk Parakeet/Whisper cascade;
   older macOS uses Parakeet on arm64 or Whisper on Intel. Apple preparation
   failure throws rather than automatically downloading another engine.
   `resolvedModelTier()` maps an Intel Parakeet override to Whisper, but
   `prepareEngine()` passes explicit overrides directly to `prepareLocalEngine`.
10. Apple Speech converts PCM to analyzer format, writes a temporary CAF,
    consumes results concurrently and removes the file with `defer`. It returns
    confidence 1.0, with nominal 20-second analysis and 3-second final-result
    deadlines. Parakeet lazily loads FluidAudio v3 models and returns SDK text/
    confidence; Whisper lazily loads with `download: false`, resamples via
    FluidAudio and derives confidence from words or segment scores.
    `CascadingSTTEngine` uses its local fallback on primary error or blank text.
11. Vocabulary replacement runs first. The nonempty corrected transcript
    enters `CommandMode.resolve` before cleanup/formatting. Parsing order is
    fixed system commands, Spotify controls/song search, provider search,
    URL navigation, then fuzzy application matching. Application confidence
    is capped by available ASR confidence; threshold 0.82 chooses execution
    versus confirmation. Other recognized commands execute immediately.
12. Commands bypass ordinary history/insertion. Execution uses NSWorkspace,
    terminate, osascript mute, pmset display sleep, Control-Command-Q lock
    events and Spotify AppleScript. `execute` returns no verified outcome.
    Pending confirmation survives teardown and is presented by the Settings
    root popover; confirm executes, cancel clears it.
13. Ordinary dictation resolves the remembered live external app, chooses a
    destination profile, runs `SpeechCleanup` (corrections, fillers, repeats,
    casing), then `SmartFormatting` (protected literals, spelling/contractions,
    punctuation/questions/casing, neutral/Gmail/Slack profile). Coordinator
    does not supply a browser active domain; browser dictation normally gets
    the neutral profile. No FoundationModels generation runs in this path.
14. Formatted text is appended to history before insertion. `TextInjection`
    checks Accessibility, activates the target if needed, waits briefly for
    held modifiers and sends clipboard Command-V at the annotated session
    tap. Observed AX editability is a hint, not a gate. AX verified insertion
    is attempted if paste throws. Lack of Accessibility opens Settings and
    leaves text on the clipboard; the coordinator retains history and error.
15. Normal completion/error/timeout uses `teardownSession`: cancel timeout,
    dictation, silence and delayed-release tasks, reset capture, hide/reset
    overlay, clear target/start time/mode and return idle. Cancellation in
    hands-free stops audio and offers a 3.5-second Undo window before full
    teardown. Undo starts a new recording; it does not restore discarded audio.

### Selection actions and Spotify boundary

Option+1/2 cancel accidental listening, suppress concurrent rewriting, capture
the live external selection by AX or bounded clipboard-copy fallback, and call
the shared FoundationModels request gate. Input is limited to 6,000 characters;
protected literals/vocabulary and output bounds are checked. Prompt Engineer
renders a guided blueprint and omits empty sections. No cloud fallback exists.

Replacement requires the original frontmost process and matching selected text
(clipboard selections are recopied). Outcomes distinguish verified AX changes,
sent-but-unverified paste, changed target/selection, unsupported and failure.
Successful/sent output enters history; changed selection gets a persistent
result card. Prompt replacement failure also gets a card; Polish failure uses
an error pill. These actions do not fall back to rewriting recent history.

Song requests resolve to Spotify search URLs/deep links and open results.
`CommandMode.playSpotify` and `SpotifyPlaybackController.searchAndPlayTopResult`
contain a separate bounded native Quick Search/AX/keyboard activation flow with
AppleScript playback observation. That helper is not invoked by ordinary song
resolution; it must not be described as the current autoplay experience.

## FluidAudio APIs verified from the pinned source

Paths below are relative to `.build/checkouts/FluidAudio/Sources/FluidAudio/`.
These are source/API availability findings, not latency, model-download or
inference benchmarks. No online example was used as an API contract.

| Source | Actual available surface / integration boundary |
| --- | --- |
| `ASR/Parakeet/SlidingWindow/TDT/AsrModels.swift` | `AsrModelVersion` includes v2, v3, tdtCtc110m, tdtJa; `decoderLayers`. `load(from:configuration:version:encoderPrecision:encoderComputeUnits:progressHandler:)`; `download(to:force:version:encoderPrecision:progressHandler:)`; `downloadAndLoad`, `modelsExist`, `defaultConfiguration`. v3 defaults to int8 encoder precision. |
| `ASR/Parakeet/SlidingWindow/TDT/AsrManager.swift` | Actor with `init(config:models:)`, `loadModels`, `transcribe` overloads for PCM buffer, URL and `[Float]`, using `inout TdtDecoderState` and optional language; `transcribeDiskBacked`, `reset`, `cleanup`. `transcriptionProgressStream` is numeric progress, not partial transcript text. |
| `ASR/Parakeet/SlidingWindow/TDT/Decoder/TdtDecoderState.swift` | Public throwing initializer and `make(decoderLayers:)`. v3 has two layers. `make` traps on allocation failure; state reset/internal fields are not public. |
| `ASR/Parakeet/AsrTypes.swift` | `ASRResult` contains text, confidence, duration, processingTime, optional token timings/performance/vocabulary metadata. LocalFlow currently keeps text/confidence only. |
| `Shared/AudioConverter.swift` | `resampleBuffer`, `resampleAudioFile`, `resample(_:from:)`. PCM conversion to 16 kHz mono is available; do not pass hardware-rate raw samples assuming they are 16 kHz. |
| `ASR/Parakeet/SlidingWindow/SlidingWindowAsrManager.swift` | Actor: load preloaded `AsrModels` or download/load, `startStreaming(source:)`, `streamAudio(_:)`, `transcriptionUpdates`, `finish`, `reset`, `cancel`, `cleanup`. Updates carry text, isConfirmed, confidence, tokens/timings. This uses offline TDT encoding over overlapping windows. It does not conform to `StreamingAsrManager`. |
| `ASR/Parakeet/SlidingWindow/SlidingWindowAsrSession.swift` | Shared-model session with `createStream` and `createEngine`. Convenience loaders can download automatically; they are not automatically governed by LocalFlow's policy or model directory. |
| `ASR/Parakeet/Streaming/StreamingAsrManager.swift` | Public Actor protocol: loadModels, appendAudio, processBufferedAudio, finish, reset, cleanup, partial callback/getter. Optional timestamp/raw-token/EOU provider protocols exist. |
| `ASR/Parakeet/Streaming/ParakeetModelVariant.swift` | `StreamingModelVariant` factory exposes EOU, Nemotron and Unified variants. These have distinct model assets/configuration; the existing TDT v3 folder is not an interchangeable streaming model. |
| `ASR/Parakeet/Streaming/EOU/StreamingEouAsrManager.swift` | Actor with 160/320/1280 ms chunk choices, EOU/partial callbacks, local `loadModels(from:)`, download/load convenience, process/finish/reset/cleanup. Local loader expects streaming_encoder.mlmodelc, decoder.mlmodelc, joint_decision.mlmodelc and vocab.json. |
| `VAD/VadManager.swift`, `VadManager+Streaming.swift` | Actor, 16 kHz samples, `makeStreamState()` and `processStreamingChunk(_:state:config:returnSeconds:timeResolution:)` returning next state/event/probability. Default and directory constructors may download; a preloaded MLModel initializer exists. None is currently integrated into LocalFlow capture. |
| `Shared/Download/DownloadTypes.swift` | `ProgressHandler` is `@Sendable (DownloadProgress) -> Void`; `fractionCompleted` is available and is what LocalFlow uses. |
| `Shared/Download/ModelHub.swift` | `offlineMode` exists. Loaders can fetch missing models or purge/re-download a failed cache unless offline mode blocks it. LocalFlow currently does not set this flag. |

## Source findings and remaining limits

The following pre-existing limits were documented, not silently changed:

- `TextInjection.insert` is paste-first despite its AX-first header comment.
  It returns `.inserted` when Command-V was posted; it does not verify that
  the destination consumed it. It currently never returns `.noFocusedTarget`,
  so the coordinator's no-target card branch is not reachable through this
  implementation. Legacy `replace(recent:...)` is not the selection action path.
- `.secureInput` is declared/handled but capture contains no explicit secure
  input detection returning that outcome. Selection snapshots store a range,
  but replacement compares text/process rather than range or element identity.
  The guide's stronger secure-input/revalidation claims are not established.
- Clipboard selection capture preserves all stored pasteboard item types and
  checks copy change count. Ordinary paste restores only the old string after
  a delay without checking whether another clipboard transaction intervened.
- Capture retains all samples in memory and creates a PCM copy at stop.
  Silence duration assumes 1024 frames per tap; actual buffer lengths are not
  accumulated for timing. `shouldStopForSilence` is not the coordinator timer.
- Engine metadata readiness precedes actual Parakeet/Whisper loading. Local
  preparation checks folder existence, not full validity. Whisper presence
  detection accepts any `.mlmodelc` or `.json` at the model directory level.
  Parakeet `unload` only resets its flag, retaining the AsrManager resources.
- LocalFlow's network block guards explicit local-model download entrypoints,
  not Apple asset installation, SDK loader recovery, or URLs opened in other
  apps. Model weights reference mutable Hugging Face `main` revisions. The
  network counter counts instrumented operations, not all underlying requests.
- `localRewriteEnabled` is persisted but not read by the rewrite execution
  path. Ordinary formatting is deterministic rules plus system spellchecker;
  spellchecker output can depend on installed language data.
- Coordinator async sessions lack an explicit session identity guard. Model
  preparation/late completion and cancellation deserve regression coverage
  before lifecycle changes. Cascade catches all primary errors, including
  cancellation. Swift task-group cancellation is cooperative; nominal Apple
  Speech deadlines are not proof of a guaranteed hard wall-clock timeout.
- Command execution has no general success/failure verification result.
  Low-confidence confirmation UI depends on Settings presentation. History
  uses queued atomic JSON writes with errors suppressed; no retention or
  persistence-error reporting exists. `DictationHistoryItem.text` is formatted
  output despite its raw-transcript comment. Vocabulary seeds on empty storage.

Tests cover rules, parsing, vocabulary, local settings/policy, UTF-16 splicing,
capture idle/reset state, rewrite-output validators and the real cascade.
Hotkey event tests manually publish events; they do not simulate global key
delivery. The NSTextView test applies splicing directly, not cross-process AX.
Insights tests mirror the file-private algorithm rather than invoking the UI
implementation. Actual Apple/Parakeet/Whisper inference, generation, TCC,
recording, full-screen panels, native actions and third-party editing remain
manual integration checks. Intel and older supported macOS were not tested.

## Implemented baseline hardening

- Feature tests now share a per-test unique UserDefaults fixture; formatting
  and vocabulary tests inject it. Cleanup no longer resets a fixed shared
  suite. Shared tests use/clean per-test settings and inject the hotkey manager.
- Replaced the production engine-preparation test that swallowed errors with
  assertions for automatic hardware policy, override policy and missing-model
  behavior with downloads disabled and a temporary support path.
- Added four tests of the existing `CascadingSTTEngine`: primary success skips
  fallback and preserves confidence; primary error and blank output use local
  fallback; fallback errors propagate. Only the engines in the tests are doubles.
- Added `AGENTS.md` with local-only rules, architecture, coding conventions,
  deterministic/local-first requirements and validation checkpoints.

No production Swift or dependency file changed. This is a verified compile/unit
baseline with explicit integration limits, not a claim that every live Mac
interaction or future streaming architecture is already verified.
