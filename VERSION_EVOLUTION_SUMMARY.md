# LocalFlow new-version context and iteration summary

**Snapshot:** 3 October 2026, approximately 23:00 IST (Asia/Kolkata).  
**Native repository:** `/Users/anuragtummapudi/Localflow-project/LocalFlow`.  
**Purpose:** establish the complete review/handoff context before further development.

This summary reconciles the current Git working tree, committed source, iteration documents, saved machine-readable validation, recent chat history, and final test/build logs. It records existing behavior separately from new work and separates measured results from unverified product behavior. No implementation, model, permission, or user-data change was made while writing this summary. Tests/builds described below are the recorded implementation checks; they were not rerun for this documentation-only request.

## 1. Where the current version starts

The native app is on branch **`main`**, at the same last commit as before the new-version work:

```text
83290ea1a2797c2df662afa1afbe5822417386b8
23 September 2026, 12:02:13 IST
refactor: update Spotify command to open native search results and refresh documentation with new assets
```

That commit changed eight files, with 223 insertions and 86 deletions, plus two image assets. Its important product change made the ordinary Spotify song-command route open native search results; it did not promise automatic playback of the top result. It also refreshed documentation/assets and removed the old coordinator autoplay path.

**There are no new commits for these iterations.** Every baseline/streaming/overlay/Laya/native-tool/agent/memory change below is still local and uncommitted. The staged diff is empty. Git cannot provide an independent commit diff for each iteration; historical boundaries come from saved iteration reports and snapshots. Current file inventories are exact relative to `HEAD`; historical per-iteration counts are labeled separately.

The workspace root has no Git repository. The native app and `localflow-blueprint/` have separate repositories. The marketing site, launch video, existing DMGs, and release distribution were outside this native-app work. The bundle version remains `0.1.0`, build `1`; “new version” here means the developing working tree, not a newly numbered or packaged release.

## 2. What already existed at the last commit

| Area | Existing implementation retained |
| --- | --- |
| Application | Swift-native SwiftUI/AppKit app, Dock/menu-bar presence, onboarding, Settings, fonts/design system, launch sound. |
| Dictation | Hold Option/Fn recording, double-tap hands-free, Stop/Cancel/Escape, waveform, final transcription, insertion/fallback result UI. |
| Local STT | Apple SpeechAnalyzer when available, FluidAudio Parakeet TDT, WhisperKit, selected-engine routing and local cascade. |
| Text processing | Deterministic cleanup, spelling/punctuation/formatting, vocabulary and phrase shortcuts, technical-literal protection. |
| Explicit rewriting | Option+1 Smart Polish and Option+2 Prompt Engineer over selected text using local FoundationModels; validation and target/selection checks. |
| Storage | UserDefaults preferences, local dictation history JSON, vocabulary JSON, privacy/network setting and instrumented request counter. |
| Mac commands | Deterministic application/URL/provider/search parsing; app open/switch/quit, volume/mute-related routes, lock/display sleep, Spotify controls/search. |
| Text integration | Accessibility and clipboard insertion/selection handling through `TextInjection`. |
| Build/test | SwiftPM modules and XCTest targets, Xcode app project, unsigned Debug builds, release helper scripts that were not invoked in this work. |

The initial native checkout was clean. Its **87 existing Swift tests and unsigned Xcode Debug build passed** before new feature implementation.

The original runtime was principally:

```text
hotkey → capture complete audio → batch STT → vocabulary → CommandMode
  → execute command, or cleanup/format/history/insert dictation → teardown
```

It did not have the new streaming protocol/router, Laya runtime, typed tool registry/results, incremental agent ledger, or operational memory store.

## 3. Iteration chronology: baseline plus six feature iterations

All recorded implementation phases occurred on **3 October 2026**. The earlier chat is titled **Establish LocalFlow baseline**; it contains the successive feature requests and continuation turns. This chat, **Add LocalFlow operational memory**, contains the final feature iteration. The project-guide inspection preceded them. Continuation turns are not counted as independent product features.

| Stage | What was delivered | Full Swift suite at that stage | Evidence |
| --- | --- | --- | --- |
| Baseline audit | Verified real architecture/dependency APIs; added `AGENTS.md`; isolated test settings; removed a test that could prepare production models; added cascade coverage. | Original 87; hardened 93; zero failures. | [BASELINE.md](BASELINE.md) |
| 1. Streaming STT | Live immutable PCM feed, replacement partials, EOU adapter/router, final-only ordinary dictation and batch recovery, cancellation/reset ownership. | 107 total: 106 passed, 1 opt-in skip. | [STREAMING.md](STREAMING.md), `.build/streaming-validation-2026-10-03/verification.json` |
| 2. Native island | Reused the overlay as one nonactivating island with nine states, live text, capped sizing, public notch/display geometry and native controls. | 118 total: 117 passed, 1 opt-in skip. | [OVERLAY.md](OVERLAY.md), `.build/island-validation/verification.json` |
| 3. Laya decisions | Real pinned local native ONNX inference, typed decision protocol, explicit preparation/import/removal, integrity checks, evaluation/calibration and deterministic fallback. | 137 total: 133 passed, 4 opt-in skips. | [DECISIONS.md](DECISIONS.md), [Laya measurements](Evaluation/Laya/validated-baseline.json) |
| 4. Native tools | Extracted command effects into 25 typed native tool routes, one registry/executor, bound confirmation, verification and guarded Undo. | 167 total: 163 passed, 4 opt-in skips. | [NATIVE_TOOLS.md](NATIVE_TOOLS.md) |
| 5. Real-time Voice Agent | Explicit agent mode, stable-prefix app opens, command segmentation, deduplication, serial dependencies, corrections, lifecycle ledger and local timings. | 198 total: 193 passed, 5 opt-in skips. | [VOICE_AGENT.md](VOICE_AGENT.md) |
| 6. Operational memory and daily-use validation | Explicit local operational JSON, Agent Settings, aliases/macros, benchmark, full-recording agent-final validation, and additional cancellation/model/audio/batch ownership fixes. | Final 222 total: 216 passed, 6 opt-in skips; three consecutive complete runs. | [OPERATIONAL_MEMORY.md](OPERATIONAL_MEMORY.md), [final validation](Evaluation/Agent/VALIDATION.md) |

Every stage has a recorded successful unsigned Xcode Debug build. All final stage results above have zero test failures. Test counts include skipped tests; a passed runner with mocked effects is not proof that real Mac workflows succeeded.

### Baseline: what was learned and hardened

The audit checked installed FluidAudio source rather than online examples. It established that the existing TDT sliding-window APIs and the separate cache-aware EOU streaming models are different systems; TDT assets cannot be substituted for EOU assets. It documented weak existing boundaries such as sent-but-unverified paste, model-readiness labels preceding actual loading, general command effects without uniform receipts, and async teardown needing session ownership.

Tests were made safer through unique temporary UserDefaults suites and test-owned support directories. Production model preparation that swallowed errors was replaced with policy/missing-model assertions. Four cascade tests covered primary success, primary error, blank output and fallback errors. Baseline hardening changed tests/documentation, not production app behavior.

### Iteration 1: streaming speech

`AudioCaptureSession` now sends copied, immutable PCM chunks from its existing microphone tap while retaining complete audio for final recovery. A bounded 128-chunk feed fails live processing on overflow rather than silently dropping speech. `StreamingSTTEngine`, `StreamingTranscriptionRouter`, `ParakeetStreamingEngine`, and shared speech types were added.

Partials replace the previous hypothesis. Only an authoritative final enters ordinary dictation formatting/history/insertion or final command routing. Failure, missing streaming assets, overflow or empty final uses the existing selected batch engine. Cancelled non-interruptible Core ML work drains before decoder reuse. Explicit model preparation can download the separate EOU assets; recording itself cannot.

Thirteen streaming unit tests passed at that stage. One opt-in real Core ML check passed two paced-audio sessions on the same adapter, including partial delivery before input closed and decoder reset. This was synthetic audio, not microphone/editor integration. The model’s 160 ms chunk size and 80 ms stride are configuration, not measured product latency.

### Iteration 2: island and focus

The existing overlay controller/view became one island with hidden, listening, hands-free, thinking, acting, success, confirmation, error and cancelled states. It uses public screen geometry, caps width at 560 pt subject to display bounds, truncates long visible text while retaining accessibility content, and supports Reduce Motion behavior.

The panel cannot become key or main; controls do not activate LocalFlow. Dismissal tasks are cancelled/versioned so old feedback cannot hide a new session. Eleven state/geometry tests passed. A native fixture harness verified Cancel, Undo, Stop and Confirm clicks preserved foreground focus and panel non-key/non-main state. This did not test full live spoken flows, external-monitor hot-plug, VoiceOver speech or measured 60 fps rendering.

The saved **overlay-only** diff was eight files, +681/−570 lines. This is a historical isolated snapshot, unlike later cumulative Git summaries.

### Iteration 3: Laya runtime and its actual quality

The model-independent decision boundary accepts typed fixed-choice questions. Laya classifies intent, risk and whether more speech is needed; it never generates executable app names, URLs, note bodies, reminders or plans. Deterministic parsers extract exact slots.

Normal inference is a persistent native Swift helper using ONNX Runtime CPU and stdin/stdout JSON. There is no inference HTTP server, cloud API, Jev, or Python inference process. Python/Xcode tooling is required for explicit preparation/export/evaluation. Prepared packages have pinned provenance, checksums, schema/calibration evidence and import validation. Loading/inference does not silently download.

The runtime works, but **the official base checkpoint failed all LocalFlow semantic quality gates**. All three production policies remain disabled/abstaining. Existing deterministic routing remains authoritative; installation must not be mistaken for validated semantic reliability or a fast sub-100-ms decision layer.

At that stage, 12 opt-in real Laya tests passed, including temporary install/remove/reinstall; five Python calibration tests passed. The implementation’s IPC buffering regressions were repaired. A test-owned interrupted artifact transfer was resumed and digest-verified. Production model directories were not installed into or removed as test convenience.

### Iteration 4: one typed native execution system

CommandMode retains its parsers and maps intents to `AgentAction`. `ActionExecutor` enforces typed arguments, risk and confirmation before `ToolRegistry` enters `MacNativeToolSystem`. Production operations use NSWorkspace, Accessibility/TextInjection, EventKit, typed Apple Events/fixed AppleScript handlers, ScreenCaptureKit and pasteboard APIs.

| Tool group | Implemented routes |
| --- | --- |
| Applications | Open, focus/switch, quit. |
| Web | Open URL, general search, provider search, known website. |
| Text | Type at cursor, replace selected text, copy. |
| System | Volume up/down/set, mute/unmute, display sleep, lock. |
| Productivity | Create reminder; create note; append/write current note. |
| Media | Spotify transport and search. |
| Utility | Screenshot and Finder reveal. |

SAFE tools execute immediately. REVERSIBLE tools offer Undo only with verified ownership and reliable guarded restoration. CONSEQUENTIAL tools require explicit single-use confirmation bound to frozen arguments; aliases/model scores cannot waive it. Confirmation expires after 120 seconds, Undo tokens after 60 seconds; the island offers action Undo for eight seconds. A sent native request cannot be unsent by cancellation.

Native receipts distinguish verified, unverified and failed outcomes. Browser opening does not prove page loading; opaque-editor paste, Finder selection, lock/display state and quit/save-dialog completion may remain unverified. Notes rejects unsafe shared/locked/attached content, and current-note writes revalidate captured identity/body. Reminder creation uses the user’s native default writable list. Native account sync remains whatever macOS already uses.

This stage added 30 tests and recorded 20 changed files: seven new and thirteen edited. Permission strings/Automation entitlement and package target wiring changed. Test effects were injected/mocked; real production implementation exists. No arbitrary shell/terminal execution was introduced. Spotify retains normal search-results behavior; it does not silently autoplay.

### Iteration 5: incremental Voice Agent

Agent sessions are explicit: **Command+Shift+Space** or **Start Voice Agent** in the menu. Ordinary Option/Fn dictation remains final-only. Unsupported agent speech is not inserted as dictation.

The stable-prefix tracker requires distinct ASR revisions; duplicates, case/punctuation changes and timer ticks are not new stability evidence. Only exact, uniquely installed app opens with a following command boundary can speculate. The fitted settling interval is **700 ms**, from eight synthetic labeled safety samples plus held-out regression assertions. A lone open-ended “Open Notes” waits for final speech. This is not empirical human-speech calibration.

The serial ledger records proposed → stable → executing → verified/completed, failed or cancelled. Dependent actions wait for verified app readiness. Unknown/failed predecessors block successors; possibly sent effects are not automatically retried. Corrections revoke unsent grants; a correction after an app was already opened waits for final speech and confirmation, without silently quitting the earlier app. Text payloads consume the remainder of their clause to prevent embedded command words becoming unintended OS actions.

Final speech coalesces behind in-flight partial decisions instead of killing the warm helper. Escape cancels pending work and invalidates ownership. New capture drains cancelled native/inference work. The island shows transcript and action together. Local timing samples are bounded and do not persist transcript content.

At this stage, real Laya-to-agent inference passed with only the OS boundary mocked; the opt-in Laya suite had 13 passing tests. An introduced correction-ordering regression was fixed. The Debug app launched, but its Accessibility warning meant a real spoken multi-command demonstration remained unverified.

### Iteration 6: local operational memory and hardening

One main-actor `AgentMemoryStore` is shared by the service container, Settings and coordinator. Persistence is intentionally simple: versioned human-editable JSON, atomic writes, sorted/pretty output, owner-only file permissions (`0600`), bounded storage and stale-file conflict detection.

| File under `~/Library/Application Support/LocalFlow/Agent/` | Contents |
| --- | --- |
| `memory.json` | Preferred browser/editor/terminal, app aliases, absolute named folders, HTTP(S) website aliases, explicit workflows, explicitly approved mappings, enable flag and confirmation policy. |
| `activity.json` | At most 200 entries: tool ID, outcome, timestamp and duration. |
| `benchmark.json` | Explicitly exported live benchmark metadata. |

There is no background conversational learning. Successful commands become mappings only through explicit approval of a verified single non-consequential action. Consequential mappings are rejected. User-written macros can include consequential steps, but those steps still require confirmation. Invalid memory is preserved for repair and blocks agent execution. Reset drains pending work and resets operational memory/activity while preserving existing dictation history, vocabulary, models and exported benchmarks.

Session preferences/confirmation policy are frozen while a request runs. Named folders reveal in Finder. Configured browser controls URL delivery; a missing chosen browser gives an error. Macros execute only from final speech and reject unsupported/shell commands and cycles, with eight nested levels and 40 expanded actions maximum. Stored workflows have 1–20 steps; memory is limited to 2 MB and 500 alias names.

These are configurable capabilities, **not pre-populated personal preferences**. For example, “my editor” can map to VS Code and “placement portal” to a supplied URL. “start LocalFlow” can reveal the project, open the preferred editor/terminal and open an already-running localhost website. It **does not start the website server**, run shell commands, or guarantee the editor opened that folder as a project. Those tool capabilities have not been implemented.

Settings → **Agent / Mac Control** includes Laya installed/readiness status, disk usage, prepare/download/import/remove/cancel, enablement, preferred apps, alias/workflow editing, editable JSON Save/Reload/Reveal, stronger confirmation policy, approval preview, activity, reset and live spoken benchmark. Its controls were compiled; full live pane interaction was not verified because the computer-control service failed.

## 4. Current architecture after all iterations

```text
AppServices
  ├─ one history store + vocabulary store + operational memory store
  ├─ SettingsViewModel / Settings → Agent / Mac Control
  └─ DictationCoordinator
       ├─ shared microphone capture → waveform + bounded PCM + complete audio
       ├─ StreamingTranscriptionRouter → EOU partial replacements
       ├─ serialized TranscriptionRouter → existing batch engines/cascade
       ├─ ordinary dictation: final → vocabulary → command or format/history/insert
       └─ explicit agent: partial/final → VoiceAgentCoordinator
            ├─ frozen app catalog/preferences, stable prefix and segmentation
            ├─ installed Laya scores or deterministic fallback; exact parser slots
            ├─ final full-recording validation, action ledger and serial dependencies
            └─ ActionExecutor → ToolRegistry → MacNativeToolSystem → receipts/Undo
                 → island feedback + metadata-only activity/benchmark
```

There remains one capture path, one native executor, one shared operational store and one island. The agent lives in CommandMode with injected decision evaluation, avoiding a module cycle. Optional AI/model failures retain deterministic behavior. Ordinary dictation’s authoritative-final policy is unchanged by the new agent-only full-recording refinement.

Existing app/Xcode lockfiles both retain nine speech dependency pins. **FluidAudio remains 0.15.5 at `19600a485baa4998812e4654b70d2bab8f2c9949`.** Laya’s independent helper has its own lockfile: ONNX Runtime 1.24.2 and swift-transformers 1.1.9. Package target dependencies/resources changed; speech dependencies were not upgraded. The Xcode project itself has no diff. New Settings UI was added inside its existing registered file.

## 5. Measured results

### Laya provenance, accuracy and runtime cost

| Measurement | Recorded result |
| --- | --- |
| Checkpoint | `convaiinnovations/laya`, English root. |
| Revision | `55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851`. |
| Evaluation corpus | 136 fixed synthetic/manual fixtures: 91 calibration, 45 held-out. No user recordings/transcripts. |
| Held-out intent accuracy | 60.0%; production gate disabled. |
| Held-out risk accuracy | 44.4%; production gate disabled. |
| Held-out more-speech accuracy | 86.7%; production gate disabled. |
| More-speech threshold | 0.806175; accepted held-out precision 87.8%, below required 95%. |
| Official PyTorch/native ONNX parity | 42 decisions; maximum absolute logit difference 0.000038147; identical selected options. |
| Helper cold model load | 4,225.1 ms; 5,223.2 ms including process launch. An earlier cold-cache run took about 16 s. |
| Warm inference p50 / p95 | 824.2 / 1,047.9 ms. |
| First inference | 994.1 ms. |
| Peak resident footprint | 1,722,793,984 bytes, approximately 1.60 GiB. |

The developer prepared package exists at `.build/laya-production-package/` and currently occupies approximately **1.61 GiB of disk blocks** (`du -sk`: 1,688,004 KiB). That is a developer artifact, not evidence of production installation. Tests used temporary storage; this summary did not inspect personal production memory or infer whether the user installed the model afterward.

These measurements are local CPU pipeline observations on the recorded Apple Silicon host, not universal latency promises. Correct ONNX conversion does not imply the checkpoint is suitable for this voice domain.

### Daily-use benchmark: three different evidence levels

| Layer | What runs | Recorded outcome |
| --- | --- | --- |
| Scripted regression | Ten scenarios × five repetitions, synthetic partial events, deterministic decisions, mocked OS boundary. | 50 scenarios, 60 tool invocations; zero duplicates, incorrect slots/order, or missing expected actions. |
| Real local ASR fixture run | System-TTS audio paced at source rate; test-owned real EOU and batch models; deterministic decisions; mocked native effects. | Ten scenarios, 12 invocations; zero duplicates; five exact-slot mismatches. |
| Live Settings benchmark | Microphone, selected STT, installed Laya or fallback, permissions and real Mac effects. | Available in code/UI; not completed/verified in this session. |

**The real-ASR run is not a successful ten-step live Mac demonstration.** It exercised real speech inference but mocked the tools. Laya was not used in those daily benchmark timing measurements.

| Median metric | Streaming-only baseline | Agent with batch final refinement |
| --- | ---: | ---: |
| First partial STT | 668.5 ms (10 samples) | 637.6 ms (10 samples) |
| Segment decision | 0.0054 ms (6 available samples) | 0.2689 ms (10 samples) |
| Time to first invocation | 1,618.7 ms (7 available samples) | 1,803.2 ms (10 samples) |
| Total completion | 2,189.4 ms (10 samples) | 2,356.1 ms (10 samples) |

The runs occurred at different points in implementation and have different available action/decision samples; they are not a controlled speed comparison. Missing timing is unavailable, not zero. Streaming-only results predate the richer provenance/tool-ID export schema. The full-recording model’s cold load/ANE compilation happened outside timed sessions and took tens of seconds, including an initial run around 107 s. These medians are **warm model timings**.

The final fixture run matched the intended tool IDs but **5 of 12 invocations had different exact arguments (41.7%)**, affecting five scenarios. Seven invocations matched completely. Case/punctuation differences also count as errors because the comparator requires exact slots. A mismatch can count both as an incorrect invocation and as a missing expected exact action; these counters must not be added as independent failures. Zero failed/unverified mock receipts says nothing about real application readiness.

Final timings by scenario are provided below in the generated measurements appendix. Search and Wikipedia navigation improved relative to streaming-only results; header parsing recovered previously unsupported note/reminder commands. Remaining note/reminder/URL/query slot quality is unresolved. No raw transcript or mismatched payload is included in exported reports or this summary.

### How measurements are defined

- **Partial STT latency:** speech-energy onset to first delivered nonempty partial. Synthetic runs use the first speech-bearing audio chunk. Batch-only sessions have no partial timing.
- **Decision latency:** mean duration of segment decisions, including deterministic extraction/cache and optional inference. The daily run’s deterministic timing is not Laya timing.
- **First action:** speech onset to actual native `perform`, not confirmation preparation. User confirmation waiting is part of elapsed session time.
- **Completion:** speech onset until final decisions are ready and the ledger reaches terminal states. Pending confirmation is not completion. Mock terminal completion is not UI/page completion.
- **Duplicate rate:** excess expected invocations divided by performed invocations.
- **Incorrect rate:** unexpected arguments/tools or out-of-order effects divided by performed invocations. App confidence is ignored as a non-executable slot.
- **Separate counters:** missing exact actions, unverified effects, failures, ordering and cancellation.

## 6. Problems found, what changed, and what is still uncertain

| Problem/evidence | Implemented handling | Verification or remaining boundary |
| --- | --- | --- |
| Restricted compiler-cache/dictionary/audio/file coordination access caused early failures. | Retried tests/builds with approved normal local access; did not change dependencies or hide errors. | Clean normal-access baseline and final suites. Environment failures are separate from code regressions. |
| Streaming hypotheses rewrite previous words and repeat events. | Replacement partials, revision ownership, stable-prefix gates and per-segment deduplication. | Streaming/agent regressions; 50 repeated scenarios and real fixtures had zero duplicates. |
| Actor reentrancy permits another call while an SDK inference is suspended. | Explicit batch tail-task serialization; cancelled non-cooperative prediction drains before reuse; queued cancelled request never enters the SDK. | Two new batch-ownership regression tests. |
| Rapid cancel/new capture could reuse decision/helper/native ownership too early. | Retire/drain tasks before new queue ownership; recording/session IDs invalidate late work. | Rapid session, cancellation and release-after-draining regressions. |
| Final speech could cancel a warm partial Laya call unnecessarily. | Coalesce final evaluation behind in-flight partial work. | Agent regression and opt-in real Laya-to-agent integration. |
| In-flight unload/removal/load could overlap and stale inference could clear a replacement connection. | Unload/removal lifecycle gates, drain IPC/loads, same-connection cleanup checks. | Laya cancellation/reload and temporary model removal regressions. |
| Idle capture reset initialized microphone hardware; stale tap/waveform callbacks could affect a later session. | Track installed tap, avoid idle input-node access, generation-gate callbacks, weak queued publication. | Audio/streaming tests; actual microphone/TCC remains live-validation work. |
| Old overlay feedback/dismissal could replace a newer session or steal focus. | Presentation ownership, cancellable/versioned dismissal, non-key/non-main panel and nonactivating controls. | Native focus fixture passed; complete live/full-screen/hot-plug behavior not established. |
| Early correction could execute wrong app/order. | Revoke pending grants; final confirmation for corrections after a sent effect; serial readiness dependencies. | Introduced correction-ordering regression fixed before agent final suite. Delivered effects cannot be retracted. |
| Reset or Settings edits could race capture/actions or overwrite manual memory edits. | Drain before reset, capture gate, frozen session preferences and stale-byte conflict detection. | Memory/cancel/session tests. Settings pane interaction remains partially unverified. |
| Explicit `http://` was normalized to HTTPS. | Preserve captured explicit scheme. | HTTP alias/regression checks. |
| ASR punctuation/articles at command headers made valid commands unrecognized. | Narrow deterministic header parsing while preserving exact payload. | Tests pass; an introduced colon/blank-note-title regression was fixed. |
| EOU streaming finals contained wrong/missing executable slots. | Agent-only full-recording final STT refinement; fail closed on cancellation/failure. | Real ASR fixtures recovered some routes, but five exact-slot errors remain. |
| Model runtime quality was poor despite technically correct conversion. | Keep all Laya semantic gates abstaining and deterministic routing authoritative. | Held-out evaluation fails gates. No fine-tuning or replacement validated checkpoint delivered. |

Production cleanup, SmartFormatting, `LocalWritingAssistant`, `TextInjection`, ordinary history/vocabulary stores, and batch engine adapters have no source diff from the last commit. They are retained components, not comprehensively repaired by this project evolution. Earlier baseline findings concerning opaque-editor paste verification, selection identity, clipboard restoration, broad speech-model readiness/privacy guarantees and persistence-error handling remain review items unless separately addressed by a new task. Local operational metadata must not be confused with existing dictation history, which still follows its prior text-storage behavior.

## 7. Final validation and local smoke status

The final complete suite passed **three consecutive runs** of the same source:

| Run | Completion time on 3 October, IST | Test duration | Result |
| --- | --- | ---: | --- |
| 1 | 22:47:02 | 8.856 s | 222 total, 216 passed, 6 skipped, 0 failures. |
| 2 | 22:47:12 | 9.633 s | 222 total, 216 passed, 6 skipped, 0 failures. |
| 3 | 22:47:25 | 8.602 s | 222 total, 216 passed, 6 skipped, 0 failures. |

The six skips are opt-in tests requiring real streaming audio/models or a prepared Laya package. Separate real inference checks ran during the iterations; skips do not mean all six were exercised on the final exact source. Intermediate memory-stage suites also passed repeated runs at 216 and 220 tests before the final batch-ownership additions.

Final unsigned Xcode Debug build: **BUILD SUCCEEDED**. Python Laya calibration: **5 tests passed**. `git diff --check`: clean. App/Xcode speech lockfiles unchanged; inspected FluidAudio SwiftPM/Xcode checkouts were clean at the pinned revision. No release packaging occurred.

Commands used for final validation, from the workspace parent:

```sh
LOCALFLOW_BENCHMARK_OUTPUT=/tmp/localflow-scripted-benchmark.json \
  swift test --package-path LocalFlow
# The complete suite above was run three consecutive times.

xcodebuild -project LocalFlow/LocalFlow.xcodeproj -scheme LocalFlow \
  -configuration Debug CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath LocalFlow/.build/AgentDebug build

python3 -m unittest discover -s LocalFlow/Evaluation/Laya -p 'test_*.py'
git -C LocalFlow diff --check
```

Saved final logs are `/tmp/localflow-complete-1.log`, `-2.log`, `-3.log`, `/tmp/localflow-complete-xcode.log`, and `/tmp/localflow-calibration-tests.log`. These temporary paths are local evidence, not durable versioned artifacts. The summaries/metadata in `Evaluation/Agent/` are reviewable working-tree files. Earlier `.build/…/verification.json` records are ignored build artifacts.

Current Debug app output:

```text
/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/AgentDebug/Build/Products/Debug/LocalFlow.app
```

Earlier iterations also used Xcode’s default DerivedData build at:

```text
/Users/anuragtummapudi/Library/Developer/Xcode/DerivedData/LocalFlow-gmcywgwypiebqedpukgnaoopoyxb/Build/Products/Debug/LocalFlow.app
```

These are distinct copies. Accessibility authorization/launching one is not evidence that the other copy, or the final source, was interactively tested.

A memory-stage unsigned Debug build launched locally. The Settings navigation visibly contained **Agent / Mac Control**. Clicking it returned `Sky Computer Use native pipe closed before response`; reset/reconnect returned the same service error. No LocalFlow crash report was found then. This is evidence of a computer-control failure, not proof of an app crash. Later fixes were rebuilt/tested, but the final exact build was not interactively relaunched through that failed service.

No real Notes/Reminders/camera/browser effects were executed by benchmark tests. No TCC, production memory/history/vocabulary, or installed production model changes were made to obtain passing results. Real streaming fixtures used test-owned APFS clones of available model assets and system-TTS files; no new model download was needed in the memory iteration.

## 8. Readiness and the next decision

**Implemented and regression-tested:** streaming ownership, typed tools/risk policy, conservative explicit agent control flow, operational memory, Settings integration, benchmark accounting, and unsigned Debug compilation.

**Measured but inadequate:** the base Laya checkpoint’s voice quality/speed and five exact-slot errors in the real synthetic-speech daily benchmark. All Laya semantic gates remain disabled; daily reliability has not been established.

**Not yet verified:** the complete live spoken sequence with real microphone/TCC, actual note/reminder readback, camera state, browser page readiness, global hotkey/full-screen focus, preferred editor behavior, real human-ASR stability calibration, Intel/older macOS, and clean-machine Laya preparation without developer environment state.

The safe supported action in scenario 8 is an ordinary website open. Photo Booth is opened in scenario 7; no camera photo/video capture tool or camera permission behavior is claimed. Current voice reminders preserve an exact title and do not infer spoken dates. This is constrained deterministic command execution with optional scoring, not an unrestricted natural-language planner.

Before widening speculation or enabling Laya gates, use live spoken evidence and a suitable calibrated checkpoint. Before calling the app dependable every day, complete the real Settings benchmark and investigate exact-slot failures without weakening the comparator or treating accepted native requests as verified completion. Further implementation is a separate task; this document makes no new code changes.

## 9. Working-tree review scope and evidence links

Before adding this summary, the native repository contained **22 modified tracked files** (+1,496/−677 lines) and **57 untracked files**. Together they are 79 changed/new file paths relative to the last commit. The untracked files contain 10,097 lines including code, tests, preparation resources, fixtures, metadata and documentation. Adding this summary makes 58 untracked paths and 80 changed/new paths; it does not change the tracked diff.

These counts are cumulative across all iterations. `git diff` alone excludes the untracked implementation, so it is insufficient for reviewing or preserving the new version. No files have been staged or committed. No push, PR, remote modification, force-reset, clean, deployment or new release package was made.

| Reference | Role |
| --- | --- |
| [Workspace project guide](../PROJECT_GUIDE.md) | Pre-evolution full workspace inventory; some runtime descriptions are historical. |
| [AGENTS.md](AGENTS.md) | Current native work rules and architecture. |
| [BASELINE.md](BASELINE.md) | Original clean checkout, tests and source limitations. |
| [STREAMING.md](STREAMING.md), [OVERLAY.md](OVERLAY.md) | Streaming/island implementation and integration boundaries. |
| [DECISIONS.md](DECISIONS.md), [validated Laya data](Evaluation/Laya/validated-baseline.json) | Real runtime provenance, calibration, measured quality/latency. |
| [NATIVE_TOOLS.md](NATIVE_TOOLS.md), [VOICE_AGENT.md](VOICE_AGENT.md) | Tool contracts, risk, exact grammar, incremental agent and historical checks. |
| [OPERATIONAL_MEMORY.md](OPERATIONAL_MEMORY.md) | Memory schema, supported examples, benchmark definitions and opt-in commands. |
| [Final validation](Evaluation/Agent/VALIDATION.md) | Final test/build results and candid live/accuracy limitations. |
| [Scripted data](Evaluation/Agent/scripted-results.json), [streaming baseline](Evaluation/Agent/streaming-results.json), [refined data](Evaluation/Agent/refined-results.json), [summary](Evaluation/Agent/summary.json) | Metadata-only measurements; no audio/transcript/payload exports. |

The appendices below are generated from the current repository and benchmark JSON, rather than inferred from remembered file counts.


## Appendix A. Final real-ASR scenario measurements

Source: `Evaluation/Agent/refined-results.json`. All timings are milliseconds,
all final sources are `batchRefinement`, all decision sources are deterministic,
and all native effects are mocked. Scenario 10 has three invocations; every other
scenario has one. Duplicate rate is 0% in every row. Missing exact slots are one
in scenarios 2, 3, 8, 9 and 10, and zero elsewhere. No run was cancelled. Fixture
confirmation is automatic in tests; real confirmation wait is not measured here.

| # | Target experience | Performed tool IDs | Partial | Decision | First action | Completion | Incorrect rate |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Open Notes | `application.open` | 611.3 | 1.9 | 1031.1 | 1031.4 | 0.0% |
| 2 | Create named note | `note.create` | 618.9 | 0.1 | 3576.7 | 3576.7 | 100.0% |
| 3 | Write dictated note text | `note.append_current` | 931.7 | 0.1 | 4006.8 | 4006.8 | 100.0% |
| 4 | Open preferred browser | `application.open` | 537.8 | 0.2 | 1108.6 | 1108.7 | 0.0% |
| 5 | Search person/topic | `web.open_url` | 636.4 | 0.5 | 1792.5 | 1792.6 | 0.0% |
| 6 | Open Wikipedia URL | `web.open_url` | 638.8 | 0.6 | 3605.2 | 3605.3 | 0.0% |
| 7 | Open Photo Booth | `application.open` | 532.0 | 0.5 | 1172.7 | 1172.7 | 0.0% |
| 8 | Safe example.com website action | `web.open_url` | 789.7 | 0.1 | 1813.8 | 1813.9 | 100.0% |
| 9 | Create reminder | `reminder.create` | 933.9 | 0.1 | 2898.4 | 2898.4 | 100.0% |
| 10 | Notes + browser + topic search | `application.open`, `application.open`, `web.open_url` | 688.9 | 0.3 | 1604.5 | 3883.8 | 33.3% |

The JSON `date` numbers use Swift Codable's default Date representation:
seconds since 1 January 2001, not Unix seconds since 1970. Timing samples are
monotonic elapsed durations. Benchmark IDs/date values identify runs, not a user
conversation. Scripted metrics represent sub-millisecond/millisecond test-event
overhead and must not be presented as speech recognition latency.

## Appendix B. Every modified tracked file relative to the last commit

Counts below are the current cumulative `git diff --numstat`, not isolated
iteration totals. A plus/minus line count includes formatting/replacement work.

| File | Added | Removed | What changed |
| --- | ---: | ---: | --- |
| [.gitignore](.gitignore) | 4 | 0 | Ignore build-time Python caches. |
| [App/AppServices.swift](App/AppServices.swift) | 8 | 2 | Share the operational store between coordinator and Settings. |
| [App/CommandConfirmationView.swift](App/CommandConfirmationView.swift) | 1 | 0 | Use typed native action summary in confirmation. |
| [App/DictationCoordinator.swift](App/DictationCoordinator.swift) | 402 | 38 | Streaming/decision/native/agent integration, session and presentation ownership, benchmark, final refinement, reset. |
| [App/Info.plist](App/Info.plist) | 3 | 1 | Notes/system Automation and Reminders permission descriptions. |
| [App/LocalFlow.entitlements](App/LocalFlow.entitlements) | 2 | 0 | Enable Apple Events Automation entitlement; existing sandbox policy retained. |
| [App/MenuBarController.swift](App/MenuBarController.swift) | 83 | 2 | Explicit decision setup/import/remove progress and Voice Agent entry points. |
| [App/OverlayWindowController.swift](App/OverlayWindowController.swift) | 173 | 147 | Reusable nonactivating island, public geometry, native result/confirmation/Undo, versioned dismissal. |
| [App/SettingsRootView.swift](App/SettingsRootView.swift) | 253 | 0 | Agent / Mac Control pane and operational/model/benchmark controls. |
| [App/SettingsViewModel.swift](App/SettingsViewModel.swift) | 6 | 2 | Main-actor ownership and shared operational store. |
| [App/WaveformOverlayView.swift](App/WaveformOverlayView.swift) | 175 | 361 | Island state/model/layout, transcript/action readouts and controls. |
| [Core/AudioCapture/AudioCaptureSession.swift](Core/AudioCapture/AudioCaptureSession.swift) | 76 | 10 | Bounded streaming PCM, speech onset, tap/reset ownership and stale callback guards. |
| [Core/HotkeyManager/HotkeyManager.swift](Core/HotkeyManager/HotkeyManager.swift) | 14 | 0 | Explicit Command+Shift+Space agent shortcut and cleanup. |
| [Core/ModelManager/ModelManager.swift](Core/ModelManager/ModelManager.swift) | 59 | 0 | Separate explicit EOU asset preparation/readiness with batch fallback preserved. |
| [Engines/TranscriptionRouter.swift](Engines/TranscriptionRouter.swift) | 21 | 1 | Serialize suspended batch calls and cancellation ownership. |
| [Features/CommandMode/CommandMode.swift](Features/CommandMode/CommandMode.swift) | 148 | 61 | Keep parser/catalog behavior, delegate effects to tools, snapshot aliases/preferences, expand macros and preserve HTTP scheme. |
| [Features/CommandMode/SpotifyPlaybackController.swift](Features/CommandMode/SpotifyPlaybackController.swift) | 6 | 3 | Bound Apple Events and reject automation errors rather than claim command acceptance. |
| [Package.swift](Package.swift) | 3 | 3 | Module dependencies and bundled decision/stability/preparation resources; speech pins unchanged. |
| [Tests/FeaturesTests/FeaturesTests.swift](Tests/FeaturesTests/FeaturesTests.swift) | 2 | 2 | Inject isolated local settings fixture. |
| [Tests/FeaturesTests/SmartFormattingTests.swift](Tests/FeaturesTests/SmartFormattingTests.swift) | 8 | 8 | Inject isolated local settings fixture. |
| [Tests/FeaturesTests/SpeechCleanupTests.swift](Tests/FeaturesTests/SpeechCleanupTests.swift) | 1 | 4 | Use shared per-test isolated fixture. |
| [Tests/SharedTests/SharedTests.swift](Tests/SharedTests/SharedTests.swift) | 48 | 32 | Isolate settings; replace production model preparation with explicit policy/missing-model checks. |

## Appendix C. Every new/untracked file relative to the last commit

These files are part of the review even though `git diff` omits them. “First added”
identifies the recorded feature phase; many were extended by later phases. This
list excludes only the summary itself, noted at the end. It contains all 57
previously untracked paths, including nested preparation/runtime resources.

| New file | First added / purpose |
| --- | --- |
| [AGENTS.md](AGENTS.md) | Baseline: local-work rules and architecture; subsequently updated. |
| [BASELINE.md](BASELINE.md) | Baseline: original audit/test results and implementation limits. |
| [Core/ModelManager/DecisionModelManager.swift](Core/ModelManager/DecisionModelManager.swift) | Laya: explicit setup/install/remove/readiness/integrity; later lifecycle hardening. |
| [Core/ModelManager/Resources/DecisionPreparation/Laya/evaluate.py](Core/ModelManager/Resources/DecisionPreparation/Laya/evaluate.py) | Laya: canonical bundled evaluation harness/frozen calibration utterances. |
| [Core/ModelManager/Resources/DecisionPreparation/Laya/utterances.json](Core/ModelManager/Resources/DecisionPreparation/Laya/utterances.json) | Laya: canonical bundled evaluation harness/frozen calibration utterances. |
| [Core/ModelManager/Resources/DecisionPreparation/LayaHelper/Package.resolved](Core/ModelManager/Resources/DecisionPreparation/LayaHelper/Package.resolved) | Laya: standalone native Swift helper source/manifest/dependency lock. |
| [Core/ModelManager/Resources/DecisionPreparation/LayaHelper/Package.swift](Core/ModelManager/Resources/DecisionPreparation/LayaHelper/Package.swift) | Laya: standalone native Swift helper source/manifest/dependency lock. |
| [Core/ModelManager/Resources/DecisionPreparation/LayaHelper/Sources/LayaHelper/LocalLaya.swift](Core/ModelManager/Resources/DecisionPreparation/LayaHelper/Sources/LayaHelper/LocalLaya.swift) | Laya: standalone native Swift helper source/manifest/dependency lock. |
| [Core/ModelManager/Resources/DecisionPreparation/laya-questions.json](Core/ModelManager/Resources/DecisionPreparation/laya-questions.json) | Laya: bundled pinned preparation/export tooling or copied decision schema. |
| [Core/ModelManager/Resources/DecisionPreparation/prepare-laya.py](Core/ModelManager/Resources/DecisionPreparation/prepare-laya.py) | Laya: bundled pinned preparation/export tooling or copied decision schema. |
| [Core/ModelManager/Resources/DecisionPreparation/prepare-laya.sh](Core/ModelManager/Resources/DecisionPreparation/prepare-laya.sh) | Laya: bundled pinned preparation/export tooling or copied decision schema. |
| [DECISIONS.md](DECISIONS.md) | Laya: runtime, quality and exact iteration inventory. |
| [Engines/ParakeetEngine/ParakeetStreamingEngine.swift](Engines/ParakeetEngine/ParakeetStreamingEngine.swift) | Streaming: real local EOU adapter and decoder ownership. |
| [Engines/StreamingSTTEngine.swift](Engines/StreamingSTTEngine.swift) | Streaming: model-independent live speech protocol. |
| [Engines/StreamingTranscriptionRouter.swift](Engines/StreamingTranscriptionRouter.swift) | Streaming: event/session/fallback ownership; later agent-final refinement. |
| [Evaluation/Agent/VALIDATION.md](Evaluation/Agent/VALIDATION.md) | Memory: metadata-only scripted/real-ASR measurements or final validation report. |
| [Evaluation/Agent/refined-results.json](Evaluation/Agent/refined-results.json) | Memory: metadata-only scripted/real-ASR measurements or final validation report. |
| [Evaluation/Agent/scripted-results.json](Evaluation/Agent/scripted-results.json) | Memory: metadata-only scripted/real-ASR measurements or final validation report. |
| [Evaluation/Agent/streaming-results.json](Evaluation/Agent/streaming-results.json) | Memory: metadata-only scripted/real-ASR measurements or final validation report. |
| [Evaluation/Agent/summary.json](Evaluation/Agent/summary.json) | Memory: metadata-only scripted/real-ASR measurements or final validation report. |
| [Evaluation/Laya/evaluate.py](Evaluation/Laya/evaluate.py) | Laya: developer evaluation/calibration entry point, tests or measured baseline. |
| [Evaluation/Laya/test_calibration.py](Evaluation/Laya/test_calibration.py) | Laya: developer evaluation/calibration entry point, tests or measured baseline. |
| [Evaluation/Laya/validated-baseline.json](Evaluation/Laya/validated-baseline.json) | Laya: developer evaluation/calibration entry point, tests or measured baseline. |
| [Features/CommandMode/AgentBenchmark.swift](Features/CommandMode/AgentBenchmark.swift) | Memory: ten scenarios, strict comparison and metadata/timing export. |
| [Features/CommandMode/DecisionEngine.swift](Features/CommandMode/DecisionEngine.swift) | Laya: typed decisions and deterministic policy; extended for tools. |
| [Features/CommandMode/IncrementalSpeech.swift](Features/CommandMode/IncrementalSpeech.swift) | Agent: prefix stability and exact clause/payload boundaries; extended for macros. |
| [Features/CommandMode/LayaDecisionEngine.swift](Features/CommandMode/LayaDecisionEngine.swift) | Laya: persistent native IPC inference; later unload/cancellation guards. |
| [Features/CommandMode/MacNativeToolSystem.swift](Features/CommandMode/MacNativeToolSystem.swift) | Native tools: production semantic/native effects and readback; extended for preferred browser. |
| [Features/CommandMode/NativeCommandParser.swift](Features/CommandMode/NativeCommandParser.swift) | Native tools: typed exact grammar; later ASR header/agent parsing. |
| [Features/CommandMode/NativeTools.swift](Features/CommandMode/NativeTools.swift) | Native tools: IDs/arguments/risk/results/registry/executor/confirmation/Undo. |
| [Features/CommandMode/NativeUndoGuards.swift](Features/CommandMode/NativeUndoGuards.swift) | Native tools: safe ownership/content guards for created files. |
| [Features/CommandMode/Resources/laya-questions.json](Features/CommandMode/Resources/laya-questions.json) | Laya: frozen fixed-choice decision schema. |
| [Features/CommandMode/Resources/voice-agent-stability.json](Features/CommandMode/Resources/voice-agent-stability.json) | Agent: synthetic stability calibration fixture/policy. |
| [Features/CommandMode/SpotifyTransportPolicy.swift](Features/CommandMode/SpotifyTransportPolicy.swift) | Native tools: verified transport/guarded Undo policy. |
| [Features/CommandMode/VoiceAgentCoordinator.swift](Features/CommandMode/VoiceAgentCoordinator.swift) | Agent: incremental ledger/decisions/dependencies/corrections; later memory/metrics/ownership. |
| [NATIVE_TOOLS.md](NATIVE_TOOLS.md) | Native tools: contracts, risk, supported grammar and validation. |
| [OPERATIONAL_MEMORY.md](OPERATIONAL_MEMORY.md) | Memory: schema/usage/limits and benchmark instructions. |
| [OVERLAY.md](OVERLAY.md) | Island: UI/focus/geometry and fixture validation. |
| [Runtime/README.md](Runtime/README.md) | Laya: native helper/preparation resource organization. |
| [STREAMING.md](STREAMING.md) | Streaming: model/session/final recovery contract. |
| [Scripts/prepare-laya.sh](Scripts/prepare-laya.sh) | Laya: explicit repository entry point to bundled preparation tooling. |
| [Shared/AgentMemoryStore.swift](Shared/AgentMemoryStore.swift) | Memory: versioned local JSON and bounded metadata activity. |
| [Shared/OverlayState.swift](Shared/OverlayState.swift) | Island: typed presentation and display/layout policy. |
| [Shared/StreamingSpeech.swift](Shared/StreamingSpeech.swift) | Streaming: immutable PCM, partial/final/events and source types. |
| [Tests/FeaturesTests/AgentOperationalTests.swift](Tests/FeaturesTests/AgentOperationalTests.swift) | Memory: aliases/macros/explicit approval/session policy/cancellation/benchmark checks. |
| [Tests/FeaturesTests/DecisionEngineTests.swift](Tests/FeaturesTests/DecisionEngineTests.swift) | Laya: probabilities/fallback/calibrated policy and preparation checks. |
| [Tests/FeaturesTests/LocalSettingsTestCase.swift](Tests/FeaturesTests/LocalSettingsTestCase.swift) | Baseline: unique per-test UserDefaults setup/cleanup. |
| [Tests/FeaturesTests/NativeToolTests.swift](Tests/FeaturesTests/NativeToolTests.swift) | Native tools: mocked native boundary, risk/results/Undo/grammar/scripts. |
| [Tests/FeaturesTests/VoiceAgentTests.swift](Tests/FeaturesTests/VoiceAgentTests.swift) | Agent: stability/dedup/dependencies/corrections/confirmation/cancellation. |
| [Tests/SharedTests/AgentMemoryTests.swift](Tests/SharedTests/AgentMemoryTests.swift) | Memory: JSON/permissions/conflicts/corruption/activity/reset. |
| [Tests/SharedTests/BatchOwnershipTests.swift](Tests/SharedTests/BatchOwnershipTests.swift) | Memory hardening: suspended/cancelled batch-call ownership. |
| [Tests/SharedTests/CascadingSTTEngineTests.swift](Tests/SharedTests/CascadingSTTEngineTests.swift) | Baseline: real cascade behavior with test engines. |
| [Tests/SharedTests/LayaRuntimeTests.swift](Tests/SharedTests/LayaRuntimeTests.swift) | Laya: native IPC/integrity/lifecycle and opt-in real integration; later agent/ownership checks. |
| [Tests/SharedTests/OverlayStateTests.swift](Tests/SharedTests/OverlayStateTests.swift) | Island: state/geometry/labels; extended for native actions and agent feedback. |
| [Tests/SharedTests/ParakeetStreamingIntegrationTests.swift](Tests/SharedTests/ParakeetStreamingIntegrationTests.swift) | Streaming: opt-in real paced inference/reset; extended for daily benchmark. |
| [Tests/SharedTests/StreamingTranscriptionTests.swift](Tests/SharedTests/StreamingTranscriptionTests.swift) | Streaming: replacement/final/recovery/session ownership; extended for refinement. |
| [VOICE_AGENT.md](VOICE_AGENT.md) | Agent: explicit mode, gates, lifecycle, validations and historical inventory. |

`VERSION_EVOLUTION_SUMMARY.md` is the additional new file created by this
context-summary request. Ignored model weights, helper binaries, caches, synthetic
audio, Debug build products and temporary logs are deliberately outside this
source inventory. No new release artifact was produced.
