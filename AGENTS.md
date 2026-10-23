# Working on LocalFlow

## Scope and Git rules

Work in this native macOS repository only. The workspace parent is not a Git
repository; `localflow-blueprint/` and `videos/` are separate projects and are
outside native app tasks. Read `../PROJECT_GUIDE.md` first, then verify claims in
the actual Swift source. The source and installed dependency revision are the
authority when documentation differs.

The remote repository/fork is a backup. Do not push, create PRs, modify remotes,
deploy, or commit unless the user explicitly requests the relevant action.
Inspect `git status --short`, branch, and diff before editing. Preserve all user
changes. Do not reset, clean, discard unrelated work, or overwrite user edits.
Do not upgrade dependencies just to obtain an API from an online example.

Deliver actual, validated changes within the requested scope. Report what
changed, files, commands, results, limitations, and the final Git diff summary.

## Architecture and ownership

LocalFlow is SwiftUI/AppKit, targeting macOS 26+ only. Apple SpeechAnalyzer,
SpeechTranscriber and AssetInventory are the sole speech implementation. `Package.swift` defines the executable, ten internal libraries,
and two XCTest targets. The Xcode app target compiles `App/` files and links the
local package libraries; it provides app metadata, permissions and resources.
New App files must be included in `LocalFlow.xcodeproj/project.pbxproj` as well
as compiling through SwiftPM. Library/test directories are discovered by SwiftPM.

| Area | Important files and responsibilities |
| --- | --- |
| Lifecycle | `App/LocalFlowApp.swift`, `AppDelegate.swift`, `MenuBarController.swift`: entry, onboarding, menu/status/settings windows. |
| Service ownership | `App/AppServices.swift`: one coordinator, history store and vocabulary store shared with Settings. Extend this container instead of creating competing instances. |
| Runtime flow | `App/DictationCoordinator.swift`: hotkeys, targets, shared capture/transcription, ordinary final command branching, formatting, history, insertion, selection rewrites and teardown. Explicit agent traffic is routed separately. |
| Incremental agent | `Features/CommandMode/VoiceAgentCoordinator.swift`, `IncrementalSpeech.swift`: stable-prefix evidence, typed lifecycle ledger, deterministic segments/slots, installed Laya decisions, serial verified dependencies, deduplication, correction confirmation and bounded local timing samples. `VOICE_AGENT.md` documents scope and calibration limits. |
| Existing live UI | `App/OverlayWindowController.swift`, `WaveformOverlayView.swift`: one reusable non-key/nonactivating top island, waveform, streaming text, action/confirmation controls and terminal/Undo states. `Shared/OverlayState.swift` owns presentation/geometry policy. See `OVERLAY.md`. |
| Result/confirmation UI | `App/FloatingResultCardController.swift`, `FloatingResultCardView.swift`, `CommandConfirmationView.swift`, `SettingsRootView.swift`. |
| Capture | `Core/AudioCapture/AudioCaptureSession.swift`: fresh AVAudioEngine per session, mono channel samples at input rate, bounded copied live PCM stream, no full-audio retention for Voice Agent, energy/silence state protected by NSLock. |
| Hotkeys | `Core/HotkeyManager/HotkeyManager.swift`: Option/Fn flags, double taps, Escape, Carbon Option+1/2; optional Fn event tap. |
| Models | `Core/ModelManager/ModelManager.swift`: Apple Speech asset readiness/locale setup. `DecisionModelManager.swift`: explicit verified local Laya preparation/import/removal, readiness and native helper lifecycle; see `DECISIONS.md`. |
| Speech boundary | `Engines/AppleSpeechEngine/AppleSpeechEngine.swift`: only analyzer implementation. `StreamingTranscriptionRouter.swift`: session ownership, cancellation and fail-closed streaming. Captured audio uses the same engine through `STTEngine`/`TranscriptionRouter`. `Shared/StreamingSpeech.swift`: Apple phrase ranges, revisions and final-prefix authority. |
| Native insertion | `Core/TextInjection/TextInjection.swift`: activation, clipboard paste/AX fallback, selected-text capture/revalidation/replacement and UTF-16 splicing. |
| Commands | `Features/CommandMode/CommandMode.swift`, `SearchProviderRegistry.swift`, `NativeCommandParser.swift`: deterministic parsing and exact slot extraction. `NativeTools.swift` owns typed tool/risk/execution policy; `MacNativeToolSystem.swift`, `NativeUndoGuards.swift`, `SpotifyTransportPolicy.swift` own native effects/readback and guarded Undo; see `NATIVE_TOOLS.md`. `SpotifyPlaybackController.swift` retains proven transport and the separate autoplay helper. `DecisionEngine.swift`, `LayaDecisionEngine.swift`: typed decisions and optional native ONNX IPC; keep slot extraction deterministic. |
| Text processing | `Features/SpeechCleanup/` and `Features/SmartFormatting/SmartFormatting.swift`: local rules, technical literal protection, restrained destination profiles. `LocalWritingAssistant.swift`: explicit FoundationModels selection actions. |
| State/storage | `Shared/SharedTypes.swift`, `LocalFlowSettings.swift`, `DictationHistoryStore.swift`, `VocabularyStore.swift`, `NetworkActivityCounter.swift`, `AgentDebugLog.swift`. |
| Validation | `Tests/SharedTests/` and `Tests/FeaturesTests/`; see `BASELINE.md` for coverage and limitations. |

The recording path uses one Apple Speech implementation (see `STREAMING.md`):

```text
Hotkey/Voice Agent -> verify installed Apple assets -> microphone PCM
  -> SpeechAnalyzer + SpeechTranscriber -> volatile range replacements
Finish -> finalizeAndFinishThroughEndOfInput -> authoritative final
  -> vocabulary -> CommandMode -> native registry / formatting / insertion
```

Ordinary dictation never executes, persists or injects partial hypotheses.
Explicit Voice Agent sessions feed Apple revisions into `VoiceAgentCoordinator`.
Only safe, exact uniquely matched commands pass stable volatile gates. Payloads
wait for authoritative Apple final ranges; confirmations remain registry-owned.
Use Apple’s natural finalized ranges during capture; do not force acoustic pause finalization (the real continuation fixture found later speech loss). Preserve consumed source
ranges, segment identity, dependencies, cancellation and final trailing flush.
Unavailable speech fails clearly; never add a speech fallback. Setup alone may
request Apple asset installation; microphone startup must not download assets.

Option+1 Smart Polish and Option+2 Prompt Engineer are selection-only actions,
separate from ordinary dictation. Keep selection capture, protected-literal
validation, duplicate generation gating, revalidation, and truthful replacement
outcomes. Preserve history before dictation insertion, including paste failures.
Keep the existing Spotify song path: open search results; the separate verified
autoplay helper is not the normal coordinator path.

## Local-first and deterministic behavior

Audio transcription and semantic rewriting must run locally. Do not add cloud
inference or remote transcript/audio submission. Downloads are explicit model
setup operations; keep policy and observable progress. Never log transcript,
selection or model-output contents. `AgentDebugLog` is intentionally a no-op;
do not turn it into a transcript logger.

Retain deterministic cleanup, vocabulary, technical-literal protection, command
parsing and formatting when optional AI functionality is unavailable. Retain
the single Apple Speech stack and honest unsupported/error states. Do not claim an AI rewrite,
insertion or native action succeeded merely because a request was sent. The
existing selected-text rewrite actions throw if FoundationModels is unavailable;
do not relabel a deterministic formatting pass as an AI polish.

`NetworkPolicy` is not a firewall. Apple owns its system-managed speech assets;
do not duplicate them in Application Support. The speech path has no remote
transcript/audio submission. Readiness and real installation progress use
AssetInventory, with locale reservations owned by AppleSpeechAssets.

Preserve dictation, hands-free, Smart Polish, Prompt Engineer, history,
vocabulary, settings, Spotify and injection behavior unless the task explicitly
changes them. Extend existing subsystem boundaries rather than duplicating
capture, routing, storage, selection or automation services. Keep the local Laya System-1 model and island. Do not add System-2, Qwen,
visual computer use or redesigns without a new explicit task.

## Observed coding conventions

- Four-space Swift indentation; UpperCamelCase types and lowerCamelCase members.
  Public APIs commonly have `///` documentation; related code uses `// MARK:`.
- Use `@MainActor` for AppKit/SwiftUI coordination and window controllers,
  Combine `ObservableObject`/`@Published` for observable state, and weak captures
  for long-lived observers/callbacks. Remove/cancel resources at teardown.
- Use actors for asynchronous routing/generation gates. Existing
  `@unchecked Sendable` wrappers are not proof of thread safety: explain access
  ownership for new mutable state and keep UI publication on the main queue.
- Use typed enums/results and `LocalFlowError` for recoverable failures.
  Keep exhaustive outcome handling and bounded waits. Preserve cancellation
  checks around async work and avoid stale work affecting a later session.
- Use UTF-16 indices for Accessibility/NSRange, and keep protected vocabulary,
  paths, URLs, flags, identifiers and numbers intact during text processing.
- Inject settings, stores, catalogs or engines through existing initializers
  for tests. Use unique UserDefaults suites and temporary paths, then clean
  test-owned state. Unit tests must not prepare production models, request
  permission, perform Mac commands or drive another application.
- Add meaningful regression tests at the affected boundary. Test doubles are
  appropriate in tests; production paths must remain real implementations.

## Build and dependency validation

Run from the workspace parent:

```sh
swift test --package-path LocalFlow
xcodebuild -project LocalFlow/LocalFlow.xcodeproj \
  -scheme LocalFlow -configuration Debug CODE_SIGNING_ALLOWED=NO build
git -C LocalFlow diff --check
git -C LocalFlow status --short
git -C LocalFlow diff --stat
```

Focused tests may be run first with `--filter SharedTests`, `--filter
FeaturesTests`, or the changed test class. The Xcode scheme has no testables;
`xcodebuild build` is compile/link verification, not the XCTest suite.
Sandboxed compiler-cache failures are environment failures, not source failures;
use approved normal local build access or documented writable cache locations.
Do not erase caches or change dependencies to hide a failure.

The app Package.swift has no external dependencies and no app lockfile.
The native Laya helper has an independent lockfile; its ONNX/tokenizer packages
are decision dependencies. Audit actual imports before removing any dependency.

Validate each architectural change before continuing to the next: inspect the
affected runtime path, run its relevant regression checks, then the complete
Swift suite and unsigned Xcode build. Separate pre-existing failures from new
regressions. Fix introduced regressions before expanding scope. Tests/builds
do not establish microphone/TCC, model inference, full-screen overlay,
third-party editor or action-verification behavior; report manual checks and
unverified boundaries explicitly. Never change the user's permissions, real
history, vocabulary or downloaded models as a test convenience.

## Local decision validation

Laya was explicitly authorized in the decision-layer task. Use the pinned official
checkpoint and native helper described in `DECISIONS.md`; do not replace them with
a server, cloud call or Python inference process. Python is an explicit build-time
export/evaluation tool only. Preparation resources are bundled in ModelManager.
The helper's independent lockfile does not change the app's speech dependencies.

LocalFlow-Laya-v2 uses only actionable_command, needs_more_speech,
correction_or_replacement and coarse_family. Known exact commands bypass it.
Only necessary follow-up questions run. It cannot supply slots, tools, plans or
risk classifications; registry metadata remains authoritative. Preserve calibrated
abstention. Human review is pending; do not claim it occurred or enable reviewed
policies without evidence. See Evaluation/LayaV2 for the frozen corpus, hashes,
review sheet, MPS training and evaluation pipeline. Changing schema requires
matching resources, retraining, parity validation and a verified import.

Run `python3 -m unittest discover -s Evaluation/Laya -p 'test_*.py'` from the native
repo for calibration policy checks. Real inference/install tests are opt-in with
`LOCALFLOW_LAYA_PACKAGE=/absolute/prepared/package swift test --filter LayaRuntimeTests`.
They use temporary model directories. Never install/remove production assets as a
test convenience. See `Evaluation/Laya/validated-baseline.json` for measured accuracy,
latency, memory and official PyTorch/native ONNX parity.

## Native tools

All ordinary CommandMode actions must enter `ActionExecutor` through `ToolRegistry`.
Do not add OS effects to the parser, model decision engine, or coordinator. The
coordinator reuses its TextInjection service inside the native tool boundary.
`AgentAction`/`ToolArguments` carry exact deterministic slots. Only the explicit
agent coordinator may authorize narrowly gated stable-prefix app opens. Add a stable `NativeToolID`, typed argument validation, risk metadata,
production native effect/readback and focused injectable-boundary tests together.

SAFE actions execute immediately. REVERSIBLE actions expose Undo only with a
verified receipt and a reliable, guarded restoration. CONSEQUENTIAL actions
require a single-use confirmation bound to frozen arguments. Capture selected
text/current-note identity before confirmation; revalidate before writing. Never
weaken this policy based on Laya scores, fuzzy matching or an arbitrary caller flag.
Confirmations expire after two minutes; Undo tokens after one minute (the island
shows action Undo for eight seconds). New recording/Escape invalidates pending
presentation/confirmation ownership. A sent OS request cannot be retracted by
cancelling its Task; distinguish unverified requests from verified effects.

Do not implement arbitrary shell/terminal execution. The sole display-sleep
process is the existing fixed `/usr/bin/pmset displaysleepnow` utility, with no
user arguments and a bounded wait. Notes/audio use fixed compiled AppleScript
handlers and typed Apple Event descriptors; never interpolate user text into
script source. Notes HTML must escape exact user text. Reject shared, locked,
attached or unsafe current notes. Retain native permissions and truthful errors.
Do not broaden account/sync behavior silently: native Notes and Reminders use the
user's existing default account/list, whose macOS sync settings remain in effect.

Use mocks at `NativeToolSystem`/`NativeScriptCalling` for unit tests. Trusted-script
compile and pure Apple Event descriptor echo tests execute no external commands.
File Undo tests operate only on temporary test-owned files. Do not exercise real
Notes, Reminders, clipboard, audio, lock, sleep or Spotify actions as test cleanup.
