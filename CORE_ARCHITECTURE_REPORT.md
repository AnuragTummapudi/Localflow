# LocalFlow core architecture lock — 4 October 2026

Implemented on the local checkout. The Apple-only speech architecture builds and passes regression. **This core is not production-qualified for System-2 planning:** Laya-v2 quality and exact speech payload results are insufficient. Its authority policies remain disabled. No push, PR, commit, remote modification, deployment or release packaging was performed.

Validation host: macOS 26.6 (25G72), Mac16,12, 16 GiB RAM. Unsigned Debug executable records minimum macOS 26.0 and SDK 26.5. Measurements below are actual results from this machine; synthetic audio, human reports and real native API effects are distinguished.

## 1. Final speech architecture

Microphone PCM → one Apple SpeechAnalyzer / SpeechTranscriber → volatile range replacements and authoritative Apple finals → deterministic command bypass or narrow Laya decisions → exact parser-owned slots → Native Tool Registry → macOS APIs / Accessibility / Apple Events → verified, unverified or failed receipt → island. Ordinary dictation, Smart Polish, Prompt Engineer, injection, hands-free, history, vocabulary, operational memory, confirmation and guarded Undo retain their subsystem boundaries. Voice Agent captures bounded streaming PCM without retaining the whole recording. Minimum deployment is macOS 26+ in SwiftPM, Xcode and Info.plist.

## 2. Exact files and dependencies removed

Before deletion, imports, constructors, UI use and model ownership were audited. Removed files:

- `Package.resolved`
- `Engines/CascadingSTTEngine.swift`
- `LocalFlow.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- `Evaluation/STTBakeoff/fetch_whisper.py`
- `Engines/ParakeetEngine/ParakeetStreamingEngine.swift`
- `Engines/ParakeetEngine/ParakeetEngine.swift`
- `Engines/WhisperEngine/WhisperEngine.swift`
- `Tests/SharedTests/STTBakeoffTests.swift`
- `Tests/SharedTests/CascadingSTTEngineTests.swift`
- `Tests/SharedTests/ParakeetStreamingIntegrationTests.swift`
- `Features/CommandMode/AgentFinalSpeechPolicy.swift`

Removed the app’s FluidAudio and WhisperKit package/product dependencies, both app resolution files, EngineKind/ModelTier selection, modelOverride, advanced/fallback speech controls, old download/preparation paths and second-model final refinement. Root Package.swift now has no external dependencies. The separate Laya helper legitimately retains ONNX Runtime 1.24.2 and swift-transformers Tokenizers 1.1.9 plus their pinned transitive dependencies. Historical evaluation JSON/Markdown and dependency Git caches remain evidence/history, not active speech stacks. [Removal audit](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/SPEECH_REMOVAL_AUDIT.md); [zero-match runtime search](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/obsolete-runtime-reference-search.txt).

## 3. Apple Speech configuration

SpeechTranscriber uses general conversational transcription with transcriptionOptions `[]`, reportingOptions `[.volatileResults, .alternativeTranscriptions]`, attributeOptions `[.audioTimeRange, .transcriptionConfidence]`. `.fastResults` is disabled; no speed/accuracy justification was established. SpeechAnalyzer uses userInitiated priority, processLifetime model retention and its best compatible audio format. PCM conversion is sequential, timestamped and drained at EOF. Apple range identity, resultsFinalizationTime, isFinal, confidence and alternatives are preserved. Finalized ranges do not regress to volatile results. Stop calls finalizeAndFinishThroughEndOfInput with a 15-second cancellation deadline. Cancellation owns the analyzer and result task; a new session uses fresh analysis state. There is no SFSpeechRecognizer primary path or alternate STT fallback.

## 4. Apple Speech assets

AssetInventory inspects the supported equivalent locale and required asset status. Explicit setup requests installation only when necessary, displays real Progress/status and reserves the selected locale. The actor releases its previous reservation without evicting unrelated reservations. Recording startup only checks installed assets. Assets remain Apple-managed; no copies are placed under LocalFlow/Application Support. Unsupported hardware/locale shows UNAVAILABLE. English (India), en-IN, was used in real fixture runs. [API research and Apple primary links](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/APPLE_API_RESEARCH.md).

## 5. Volatile STT latency

Ten paced, test-owned Samantha recordings: first volatile result from input start p50 **4527.1 ms**, p95 **4640.7 ms**. Across 75 changed volatile ranges, emission minus range-end p50 603.5 ms / p95 1667.2 ms. These are different metrics; range lag is not first-command latency. Natural microphone latency was not instrumented. These results do not support an immediate/sub-100 ms STT claim.

## 6. Finalized STT latency and continuation

First Apple final from input start p50 **4568.0 ms**, p95 **4680.6 ms**. Across 33 finalized ranges, range-end lag p50 3547.8 ms / p95 5123.1 ms. Stop drain p50 62.8 ms / p95 79.4 ms. Real analyzer cancellation measured 0.34 ms.

Forced acoustic-pause finalize(through:nil) lost later speech in two controlled multi-command runs. That custom endpoint was removed; production relies on Apple’s natural finals during capture. The corrected continuous PCM fixture preserved all four commands and reached injected tool effects at 4,609 / 8,965 / 9,145 / 13,546 ms from input start, before capture closed at 18,382 ms. It used 1.6-second pauses and 7.43 seconds of final silence. A shorter-tail run preserved all commands but executed the last website command only at input closure; that failed timing assertion is retained. Transcript identity, consumed ranges, segments, deduplication, dependencies, trailing flush and cancellation remain explicit. The ten-fixture suite took 381.67 seconds overall; its separately timed fixture intervals total about 69 seconds. Setup/readiness overhead was not separately instrumented.

[Final Apple run](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/apple-final-quality.json); [controlled endpoint comparison](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/apple-continuation-no-forced-finalization.json); [short-tail failure](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/apple-quality-short-tail.json).

## 7. Exact payload accuracy

**2/5 exact deterministic slots (40%)** in the small synthetic speech sample: github.com resolved through the explicit GitHub website registry, and Norbert Wiener matched exactly. Title, body and reminder failed because Apple rendered “LocalFlow” as “local flow” and changed case/punctuation. No arbitrary payload was repaired using alternatives. These five examples are not a population accuracy estimate. Separately, real native creation/title/append/reminder handlers verified the exact developer-supplied strings; native write accuracy does not establish ASR accuracy. No human microphone title/body accuracy run was reported.

## 8. Application/entity alternative rescue

Rescue is limited to a clear open/launch grammar and a unique exact installed application name, CFBundleName/CFBundleDisplayName or explicit application alias. Ambiguous alternatives abstain; a valid primary entity is preserved. Domains, URLs, queries, note/reminder text and prose are not rewritten. Tests cover unknown primary → exact Safari, word-range context, conflicting alternatives and payload refusal. Final Apple fixtures returned 77 alternative strings; a live rescue rate was not measured. The current alternative resolver implements application rescue; broader saved-folder/project/macro alternative rescue is not implemented. Website aliases resolve deterministically in the registry. Debug retains original/selected interpretations and alternatives, without persisting user transcript contents.

## 9. Laya-v2 dataset

2,400 training states, 400 calibration states, 600 held-out states. Needs-more positives/negatives are exactly 1,200/1,200, 200/200 and 300/300. Coverage includes prefix chains, incomplete app/payload commands, conjunctions, pauses, repeated partials, dictation, quotes, negation, hypotheses, corrections, ASR noise, unknown speech, ambiguity and compound commands. Scenario families and their prefix states stay within a split; grammar templates and scenario entities are partitioned. Operation taxonomy remains shared; semantic generalization to natural speech is not proven.

Seven corpus audits passed. A calibration-only fixed correction destination overlapped a train app entity; it was changed from Safari to calibration-owned Firefox. Train/held-out hashes stayed unchanged. Original training manifest and the audited evaluation manifest are both retained. The 240-row human-review sheet has blank reviewer/approval columns: **no human review was performed**. [Corpus manifest](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/LayaV2/split-manifest.json); [human-review sheet](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/LayaV2/human-review.csv); [audit amendment](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/dataset-audit-amendment.json).

## 10. Laya-v2 training and provenance

Backbone convaiinnovations/laya-multilingual, 321,908,998 parameters, pinned revision `e4e9ddf21a7b1903b7acffd8814ad4307bf63a67`. Current upstream revision `1720e3e3357cfe1e281542e223f8273b0890ca34` was inspected; weights/tokenizer hashes and encoder/agent/tokenizer configuration bytes match the pinned base. Base weight SHA-256 `9d628fd971b700382ac6f65920a86f149777b2e748e0c955fb3b19695aa8f204`.

Full-model FP32 MPS, one epoch, supervised one-hot CE, seed 722041, microbatch 1, accumulation 32, AdamW encoder LR 2.5e-5/head LR 1e-4, decay .01, norm clip 1, cosine 285 updates/minimum LR 1e-6. Completed 9,099 microsteps in 4,085.51 seconds. No RLCD/teacher-probability improvement is claimed. Held-out data did not affect fitting or calibration threshold selection. Checkpoint saved in FP16; SHA-256 `b9a7d21a756740a11fe32d1ad44cba73898f96999b060fe437407a5c87c96e9a`.

Train hash `ba262b61ce837d54507639720b5213ca25a2f1bab8e6c4a685c95f5997fa8954`; audited calibration hash `e03fc18a16697dd5fcbc3740000d43a48d02ceb21374eebd47b346ff907bf980`; held-out hash `e4fefef8ec7cbe57e3c59e42bc84652d4350b1faf53f1db7cd5138a2a1a4a653`. Exact original/final manifest hashes, executed sources, versions, optimizer/config, losses and temperature calibration are retained in [training evidence](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/LayaV2/training-config.json) and [evaluation report](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/LayaV2/report.json).

## 11. Actionable accuracy

Held-out **92.33%** (600 states): TP 497, FP 41, FN 5, TN 57. Precision 92.38%, recall 99.00%. Actionability is not execution authorization; Laya generates no slot, tool call, plan or risk override.

## 12. Needs-more-speech precision/recall

Held-out precision **92.70%**, recall **84.67%**, F1 **88.50%**, accuracy **89.00%**. TP 254, FP 20, FN 46, TN 280 on 600 balanced states. The missed incomplete states prevent qualification.

## 13. Correction accuracy

Held-out accuracy **95.83%**, positive precision **100%**, recall **30.56%**, F1 **46.81%**. Only 11 of 36 positive corrections were detected; 25 were missed. The 95% Wilson lower bound on positive precision is 74.12%. Overall accuracy hides the poor correction recall.

## 14. Coarse-family accuracy

**72.51%** on 502 actionable held-out states. Families: application, web, productivity, system, text_file, media, other. No application/URL/query/content/tool value comes from this classifier.

## 15. Selective precision and coverage

The calibration-selected 95% joint routing target achieved **76.19% held-out precision at 14.00% coverage** (84 accepted/600), despite 95.65% calibration precision. At the 97% target, held-out precision was 87.18% at 6.50% coverage; no feasible 99% calibration point existed. All four authority policies are disabled. Importing or hashing an unreviewed package cannot enable them. The 322M experiment is not quality-qualified; a larger-backbone comparison was not run.

## 16. Laya latency by question count

| Requested work | Native CPU sequential p50 / p95 | FP16 MPS research sequential p50 / p95 |
| --- | ---: | ---: |
| one | 117.0 / 178.1 ms | 49.6 / 58.9 ms |
| two | 213.1 / 281.7 ms | 102.1 / 119.7 ms |
| three | 384.4 / 657.3 ms | 171.0 / 509.0 ms |
| family | 158.1 / 240.5 ms | 54.8 / 113.4 ms |

Native: 51 samples/workload; MPS: 101. Both retain one model and include requested-head tokenization, transfers/IPC, forwards and readback; the first sample is excluded from warm percentiles. Batched and individual times/sample IDs are preserved. CPU cold load wall 2,945.8 ms, first IPC result 84.9 ms; MPS cold load 8,894.1 ms, first inference 1,045.7 ms. Native CPU is the app runtime; MPS is a research pipeline. Exact known commands ask zero questions. Unaccepted actionability now stops after one question; more/correction/family follow-ups require accepted actionability and the relevant condition. No reload-per-command. [Native benchmark](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/LayaV2/native-latency.json); [MPS benchmark](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/LayaV2/mps-latency.json).

## 17. Laya memory, disk and runtime parity

Native loaded RSS 799,064,064 bytes; native package 1,360,965,277 bytes. Native inference peak was not separately measured. MPS host peak RSS 2,183,872,512 bytes, sampled MPS allocated 644,868,352 bytes, driver allocated 1,095,434,240 bytes. Sampling is not an intra-forward peak. Training peak host RSS 2,632,777,728 bytes. Saved checkpoint 643,835,524 bytes; checkpoint directory 678,298,857 bytes.

MPS FP16/FP32 arithmetic parity: 256/256 argmax agreement over 64 states, maximum probability delta .008653. Native ONNX parity: 128/128 decisions, maximum absolute logit difference .0000340343. Prompt Boolean descriptions and JSON key order were corrected before parity passed; failed preliminary parity evidence remains. Current package is imported at `~/Library/Application Support/LocalFlow/Models/laya-v2`, resident and diagnostic-only. The previous `Models/laya` remains intact; its generic decisions are not used by production. Current trained checkpoint and native package are retained locally under `.build/core-lock/laya-v2` and `Models/LocalFlow-Laya-v2-native`.

## 18. Live native-action validation

Human reported one continuous microphone session: “All four acted before stopping” for Notes, Safari, Chrome and github.com. No human timing or transcript was exported. A fresh repeat was requested after the endpoint fix; no result was reported for that repeat.

Real unsigned Debug harness verified application activation, exact note creation/title/append, guarded note/reminder Undo, exact reminder creation, volume/mute and Spotify pause. github.com and exact web search were UNVERIFIED because browser page completion was not read back. Unknown app was rejected and later Safari executed. Final deterministic correction selected Safari; the repaired real Apple correction fixture also selected Safari before capture closed, with injected native effects. Old unsent confirmation grants are revoked on revision; already sent effects still require explicit correction confirmation. Cancellation tests rejected stale grants; lock preview was cancelled and never locked the Mac. Stop/restart/cancellation were exercised by the real analyzer and unit suites. Developer-created mutated test notes from acceptance remain; unrelated notes were not removed.

Debug acceptance exposes volatile/final/original-selected transcripts, alternatives, Laya questions, parser output, exact tool/arguments, receipt, verification and latency. The 16 requested scenarios are available there; not every scenario received a human microphone run. [Final real native receipts](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/native-actions-plaintext-final.json); [microphone report](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/manual-microphone.json); [real correction fixture](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/apple-correction-preview-fixed.json).

## 19. Permission readiness

Microphone READY; Accessibility READY; Apple Speech assets READY for en-IN; Laya model READY/resident, authority disabled. Native Notes Automation status was 0/READY. Spotify’s nonprompting probe timed out (unknown/ACTION REQUIRED), although its actual pause command verified successfully. Reminders creation/Undo succeeded under native permission.

Readiness uses READY / ACTION REQUIRED / UNAVAILABLE. Automation is checked off the main thread with a three-second display deadline; stalled checks cannot freeze UI or accumulate probe threads. Only a real requested tool triggers native permission prompts. Errors identify the required Automation target/Accessibility/Microphone/Reminders action and offer the relevant System Settings link. LocalFlow does not pre-authorize Automation.

## 20. Disk before/after cleanup

Repository allocated footprint: **28,970,344,448 → 15,244,201,984 bytes** (28.97 → 15.24 GB) immediately after cleanup. LocalFlow-owned obsolete speech directories: 932,577,280 → 0 bytes. Filesystem free: 9,708,552,192 → 22,421,819,392 bytes; observed increase 12.71 GB.

Per-path manifest allocation sum deleted: 16,347,721,728 bytes; it is not the filesystem physical recovery measurement. After final gate verification regenerated current SwiftPM products, the project measured 15,536,414,720 bytes (15.54 GB). The manifest preceded deletion and records 60 paths with reasons and outcomes. No git clean, Git deletion, Apple asset deletion or user-data cleanup occurred. [Deletion manifest](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/deletion-manifest.json).

## 21. Remaining generated/cache directories

The exhaustive directory inventory is [remaining-generated-directories.txt](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/remaining-generated-directories.txt). Remaining groups include current SwiftPM products, current DebugDerived, current helper-final build, current v2 checkpoint/native package, research virtualenv/SDK/base checkpoints, protected v1 training/model evidence, historical results/logs, SwiftPM repositories/checkouts and old Xcode SourcePackages dependency histories. The superseded copied `stale-model-resource.bundle` and `pre-final-Debug.app` contain embedded Git repositories and remain protected under the no-Git-deletion constraint. Project Python reporting bytecode caches regenerated during verification are listed. Apple-managed assets and unrelated global caches were never candidates. Current operational memory/history/vocabulary/aliases/macros are preserved.

## 22. Tests and build

Three consecutive final `swift test --package-path LocalFlow` runs: **267 tests each, nine opt-in tests skipped, zero failures**, approximately 9–10 seconds each. Skips include live/installed-model prerequisites and are not claimed as passes. Real v2 requested-head/authority-gate tests: 2 passed, including the single-question abstention funnel. Dataset audits: 7 passed. Focused continuation/agent tests: 58 run, one skipped, zero failures. Focused native payload guards: 9 passed. Native/MPS parity passed as above. Final real Apple streaming fixture and subsequent correction fixture passed; preliminary endpoint, short-tail and parity failures are retained.

Unsigned Xcode Debug build succeeded with CODE_SIGNING_ALLOWED=NO. Native helper Release configuration was built only as an internal runtime component; no application Release, deployment or distributable was packaged. `git diff --check` passed. Current source contains zero removed speech imports/engine/model-selection references. [Final test logs](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/Logs/regression-3-final-core.log); [unsigned Debug build log](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/CoreLock/Logs/xcode-locked.log).

## 23. Known limitations

Laya-v2 is unreviewed and below the measured quality gate; policies are disabled. Native app inference is CPU, not MPS; MPS parity/benchmarks do not establish a production MPS provider. Synthetic ASR brand/payload accuracy is poor, first results took about 4.5 seconds, and the final website command needed a longer trailing pause to arrive during capture. Natural microphone payload accuracy, instrumented natural latency, hour-long soak and all 16 human live scenarios remain unverified. Cold Apple asset/readiness overhead is not separately measured. Browser page completion and arbitrary editor paste remain explicitly UNVERIFIED. Broader vocabulary/project/macro alternative rescue is not implemented. Human dataset review and stronger training/generalization are still required. Preserved pre-existing worktree changes make the cumulative Git diff larger than this iteration alone.

## 24. Ready for System-2 planning?

**No.** The single Apple speech core, continuation ledger, deterministic native tools, permissions and safety boundaries are implemented and tested. The measured decision quality, exact speech payload failures and unverified natural/long-session performance prevent a production-readiness claim. No Qwen, System-2 planner or visual computer-use capability was added.
