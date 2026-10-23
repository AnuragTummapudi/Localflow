> Historical evidence from the preceding architecture. Current macOS 26+ speech and decision behavior is documented in STREAMING.md, VOICE_AGENT.md and CORE_ARCHITECTURE_REPORT.md. Removed speech engines described here are not available in the current app.

# LocalFlow live multi-command continuation bugfix

4 October 2026. Repository: `/Users/anuragtummapudi/Localflow-project/LocalFlow`.
HEAD remains `83290ea1a2797c2df662afa1afbe5822417386b8`, branch `main`.

The continuation fix is implemented and regression-tested. Actual post-fix microphone → native
application effects remain **UNVERIFIED**. This is not a claim of proven daily-use reliability.
All existing working-tree changes were preserved. No Laya training/model changes, planner, Qwen,
visual-control feature, commit, push, PR, deployment or release packaging was performed.

## Root cause and reconstruction

The coordinator had no consumed source cursor. Segmentation recognized connectors followed by
command headers, but not successive bare headers or acoustic pauses. Consequently
`open notes open safari open chrome` remained segment 0. A completed record at segment 0 made a
later differently targeted segment-0 hypothesis look like a correction of the already sent Notes
request. The partial path explicitly held that correction until final speech. The recording and
transcript could continue while the ledger stopped admitting subsequent actions.

The dedup comparison already included tool arguments and app identity: it was **not** a tool-ID-only
collision. The faulty reuse of segment identity was the key problem. Every earlier action was also
implicitly a prerequisite, so failed/unverified predecessors blocked unrelated app opens. Final
unknown commands cancelled the suffix. The island selected old completed records indefinitely.

Before changing continuation logic, Debug-only tracing reconstructed the pipeline and two new
regressions failed: unpunctuated final commands and an independent command after an uncertain
middle command. The controlled fourth trace executes Notes at revision 2; later replacement
hypotheses reuse ordinal 0 and leave Notes as the completed record. The raw first/second traces
never create independent segments. The raw third trace replaces Notes with Safari before execution.

Your manual Notes success establishes that native app opening worked. There is no saved trace of
that microphone session, so its precise first-clause closure mechanism cannot be asserted. In the
pre-fix source, an isolated tail `open Notes` needed final speech; the controlled reproduction gives
the first command an explicit closing clause. This distinction avoids inventing your actual transcript.

Evidence: [before trace](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/Continuation/before-debug-trace.json),
[after trace](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/Continuation/after-debug-trace.json), [reproduction notes](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/Continuation/README.md).

## Consumption, segmentation and deduplication

- Snapshot tracks seen, stabilized and consumed word counts; ledger records source ranges and
  explicit dependency ordinals. Completed source text is skipped on subsequent revisions.
- The explicit-agent parser recognizes bounded application/navigation headers without punctuation,
  sentence separators, and acoustic boundaries. Ordinary command segmentation defaults are unchanged.
- Installed unique whole app names, approved configured targets, and complete navigation targets
  may execute at a stable boundary. Fuzzy app names, writes, macros and consequential requests
  retain their final/confirmation requirements.
- Parakeet's official EOU callback is relayed as boundary metadata without changing transcript text.
  Existing capture-energy silence supplies recurring boundaries: this SDK's EOU latch fires once per
  recording. Pause detection requires both silence and no transcript change for the existing fitted
  settle interval; ordinary repeated ASR notifications do not manufacture stability evidence.
- Acoustically closed or consumed utterances can be retained when an adapter sends a new independent
  command hypothesis. Revisions without such boundary evidence remain revisions, not guessed commands.
- App opens deduplicate by segment identity plus actual app ID/URL/PID, excluding confidence. Other
  invocations use typed argument equality. Later source segments targeting the same app remain distinct.
- Authoritative final speech flushes trailing commands. Same-segment completed invocations are not
  resent. Unsent revised actions are revoked synchronously; late corrections still need confirmation.
- Session cancellation/new begin resets cursor, boundaries, ledger, cached decisions and feedback;
  exclusive decision/native task ownership still drains before reuse.

The installed Chrome metadata exposed a second real-world blocker: `CFBundleDisplayName` is
`Google Chrome`, while `CFBundleName` is `Chrome`. The catalog now retains declared alternate whole
names. Matching and early-execution uniqueness check use those exact metadata names, not a guessed
substring alias. Ambiguous alternate names abstain early and require confirmation at final.

Text-bearing clauses and search payloads remain indivisible without an actual acoustic boundary;
embedded `open Safari` is not turned into another action. Semantic decisions do not rewrite payloads.

## Dependencies and island

Independent application/web commands have no irrelevant readiness dependency. Contextual note/text
operations depend on their application/note context. Failed/unverified context blocks them, and an
unsupported intervening instruction cannot silently reuse older context. Uncertain middle targets
remain unsent; they cannot prevent later exact independent partial commands. Consequential compound
barriers and late-correction confirmation barriers remain in place.

The island chooses executing/pending work, then brief terminal feedback. New speech clears old
success feedback; after 1.2 seconds without a revision it returns to listening. Recording stays active.
The existing non-key/non-main panel, controls, confirmation, Undo and Reduce Motion code are preserved.
Explicit Agent sessions are exempt from ordinary hands-free 45-second/30-minute auto-stop; ordinary
dictation retains those thresholds. Stop/Cancel explicitly ends the command stream.

Debug Settings → Agent / Mac Control → developer reality gate → Show transient live evidence exposes
up to 96 runtime trace entries: session/revision, full partial, stable prefix before/after, cursor,
remaining range, segments, parser/action/key, ledger/dependencies, execution start/receipt/consumption.
The app does not persist this transcript trace; clearing/closing evidence or starting a new session
clears it. Synthetic test exports are separate opt-in test artifacts.

## Regression coverage

All requested A–K are covered in `Tests/FeaturesTests/VoiceContinuationTests.swift` and existing
`VoiceAgentTests`: paused Notes→Safari; three ordered apps; bare-header partials; duplicate partials;
unknown middle with valid suffix; Notes→create→append dependency/confirmation; independent app after
unverified Notes; correction; final trailing flush; cancellation; new-session reset.

Additional coverage includes URL continuation, utterance-only replacements, same app in distinct
segments, exact LocalFlow Test title/body fusion, payload/search/correction header safety, bounded
opt-in diagnostics, blocked writes after unknown context, declared Chrome bundle names and ambiguous
bundle names. Shared streaming tests assert that an acoustic boundary with unchanged text is delivered.

The old assertion that an unsupported clause must suppress a later independent Safari open was
changed to the requested behavior. Dependent failures and confirmation/correction assertions remain;
the exact benchmark comparator is untouched.

## Checks and boundaries

Final check results and complete logs are recorded below. Full-suite skips are explicit: four
real-Laya/package checks; real-ASR daily fixtures; real decoder smoke; frozen decision corpus export;
synthetic trace export. The decoder, real-ASR fixtures and synthetic trace export were separately run.
Laya/corpus opt-in checks were not rerun; models/training were outside this iteration.

Real decoder inference passed twice through the same cached adapter, one XCTest, zero skips/failures.
Real streaming + final batch ASR on ten synthetic audio scenarios completed, one XCTest, zero failures,
with **5/12 exact mismatches (41.67%), zero duplicates**, unchanged from the prior reality-gate result.
Those mismatches remain scenarios 2, 3, 8, 9 and the third action of 10. A passing fixture runner is not
an exact-payload pass. Native effects are mocked in every automated command/ASR test.

The tests exposed and fixed punctuation-dependent app matching and a following search bypassing a
late correction grant. A new context test initially expected failure for a fuzzy target; the real
parser returns a confirmable app match. It now asserts no context write before that confirmation and
separately asserts terminal failure for a genuinely incomplete/unsupported `open` segment.

## Actual local smoke attempt

The Debug app was launched through computer control from this exact path:

```text
/Users/anuragtummapudi/Library/Developer/Xcode/DerivedData/LocalFlow-gmcywgwypiebqedpukgnaoopoyxb/Build/Products/Debug/LocalFlow.app
```

The pre-existing process was quit, and a process launched at 09:11:10 from that path was confirmed
by read-only process inspection. Computer control timed out selecting its window, then reported
inactive app control. Bundle-ID selection was ambiguous because several local builds/backups share
`dev.localflow.LocalFlow`. This is a control-infrastructure limitation, not evidence of LocalFlow
native failure. Later final safety/catalog fixes rebuilt the same bundle; restart it before testing.

| Post-fix real microphone scenario | Status |
| --- | --- |
| Notes → Safari → Chrome → github.com in one session | UNVERIFIED |
| Notes + exact LocalFlow Test title/body | UNVERIFIED |
| Unknown middle → valid suffix, correction, cancel, restart | UNVERIFIED |
| Actual native effects observed/read back in this iteration | None |

## Manual reality test

1. Quit LocalFlow through its menu, then open the exact Debug bundle above. Do not select another
   backup/build by bundle name. If Accessibility is denied, select that exact bundle in System
   Settings → Privacy & Security → Accessibility. Check microphone and Notes Automation as needed.
2. In Settings → Agent / Mac Control, check real-time Agent is enabled. Enable Debug transient live
   evidence, then start **Voice Agent** through LocalFlow's menu, not ordinary dictation.
3. Say “Open Notes”, wait about one second, “Open Safari”, wait about one second, “Open Chrome”,
   wait about one second, “Open github.com”. Keep the SAME session running throughout. Observe the
   foreground applications/browser and receipts; Notes/Safari/Chrome should each open once and the
   browser should navigate to GitHub. Website request acceptance alone stays UNVERIFIED.
4. Stop, start another Agent session, and say “Open Notes, create a new note called LocalFlow Test,
   and write hello from LocalFlow.” Stop to provide authoritative final speech for the text payload.
   Read the actual note back: exact title `LocalFlow Test`, body `hello from LocalFlow`.
5. In a fresh session test Notes → “open sapphiri” → Chrome → github.com, corrections before a
   pause, cancellation after the first completed command, and stop/start. Do not confirm an uncertain
   target merely to progress the test. Writes still require their existing grants.
6. Review stream diagnostics: cursor advances, later segment IDs differ, keys contain actual targets,
   receipts correspond to current actions. Mark VERIFIED only after observing/readback of app state.

Remaining limitations: this Mac's complete spoken/native sequence still needs the manual test above;
existing ASR payload errors remain. A replacement of an unclosed hypothesis cannot safely be assumed
to be independent speech without pause/EOU evidence. No Laya upgrade or planner readiness is claimed.

## Final results and changed files

| Final check | Result |
| --- | --- |
| Full Swift suite, three consecutive runs 10/11/12 | 256 tests each, eight skips each, zero failures |
| Focused VoiceAgent/continuation/streaming/native/operational suite | 103 tests, one opt-in skip, zero failures |
| Opt-in synthetic continuation reconstruction | 24 tests, zero skips/failures; paused cumulative and replacement traces each execute four commands, cursor eight |
| Real local decoder reset smoke | One test, two real adapter passes, zero skips/failures |
| Unsigned Xcode Debug build | BUILD SUCCEEDED |
| git diff --check | Clean |

Commands ran from the workspace parent:

```sh
swift test --package-path LocalFlow
xcodebuild -project LocalFlow/LocalFlow.xcodeproj -scheme LocalFlow \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
git -C LocalFlow diff --check
```

The 256 XCTest entries include skips; 248 were executed without skipping in each full run.
Earlier full/focused passes and diagnostic failures are retained, including the initial invalid
OverlayPhase spelling caught by compilation. Final runs supersede earlier smaller suite counts.
The FluidAudio unhandled resource, AppKit activation deprecation and missing AppIntents metadata
warnings remain non-fatal. Dependency locks, project file and Laya sources/assets match task-start hashes.

Files changed/added in **this** iteration, against the preserved task-start file hashes:

- [App/DictationCoordinator.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/App/DictationCoordinator.swift)
- [App/SettingsRootView.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/App/SettingsRootView.swift)
- [Engines/ParakeetEngine/ParakeetStreamingEngine.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Engines/ParakeetEngine/ParakeetStreamingEngine.swift)
- [Evaluation/Continuation/README.md](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/Continuation/README.md)
- [Evaluation/Continuation/after-debug-trace.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/Continuation/after-debug-trace.json)
- [Evaluation/Continuation/before-debug-trace.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/Continuation/before-debug-trace.json)
- [Evaluation/Continuation/real-asr.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/Continuation/real-asr.json)
- [Features/CommandMode/CommandMode.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Features/CommandMode/CommandMode.swift)
- [Features/CommandMode/IncrementalSpeech.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Features/CommandMode/IncrementalSpeech.swift)
- [Features/CommandMode/VoiceAgentCoordinator.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Features/CommandMode/VoiceAgentCoordinator.swift)
- [LIVE_CONTINUATION_BUGFIX_REPORT.md](/Users/anuragtummapudi/Localflow-project/LocalFlow/LIVE_CONTINUATION_BUGFIX_REPORT.md)
- [STREAMING.md](/Users/anuragtummapudi/Localflow-project/LocalFlow/STREAMING.md)
- [VOICE_AGENT.md](/Users/anuragtummapudi/Localflow-project/LocalFlow/VOICE_AGENT.md)
- [Shared/StreamingSpeech.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Shared/StreamingSpeech.swift)
- [Tests/FeaturesTests/VoiceAgentTests.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Tests/FeaturesTests/VoiceAgentTests.swift)
- [Tests/FeaturesTests/VoiceContinuationTests.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Tests/FeaturesTests/VoiceContinuationTests.swift)
- [Tests/SharedTests/StreamingTranscriptionTests.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Tests/SharedTests/StreamingTranscriptionTests.swift)

Full working tree: 23 tracked modified files; 134 untracked files (includes earlier iterations); zero staged files. No task-start files were removed.

- [localflow-continuation-final-tests-10.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/continuation/logs/localflow-continuation-final-tests-10.log)
- [localflow-continuation-final-tests-11.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/continuation/logs/localflow-continuation-final-tests-11.log)
- [localflow-continuation-final-tests-12.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/continuation/logs/localflow-continuation-final-tests-12.log)
- [localflow-continuation-final-focused3.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/continuation/logs/localflow-continuation-final-focused3.log)
- [localflow-continuation-after-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/continuation/logs/localflow-continuation-after-tests.log)
- [localflow-continuation-real-decoder.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/continuation/logs/localflow-continuation-real-decoder.log)
- [localflow-continuation-final2-xcode.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/continuation/logs/localflow-continuation-final2-xcode.log)

The real-ASR fixture suite was rerun on the final catalog/dependency source: one XCTest
passed in 58.984 seconds, zero skips. It still produced 12 invocations, five exact mismatches,
zero duplicates, the same affected scenarios. The native boundary remained mocked. The
runner logged an MPSGraphExecutable loading warning after the passing suite; successful
tests do not establish speech-model compute placement or fix the remaining ASR errors.

- [Final real-ASR run log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/continuation/logs/localflow-continuation-real-asr-final.log)
- [Final real-ASR action results](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/Continuation/real-asr.json)
