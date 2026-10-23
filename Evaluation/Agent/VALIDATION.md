# Operational agent validation — 3 October 2026

All changes remain in the local working tree. No commit, push, release packaging,
deployment, model installation/removal, or permission changes were performed.
The repository already contained substantial agent/streaming/native-tool changes
when this task started; those were preserved.

## What changed

- Added a shared main-actor JSON operational memory store with explicit preferences,
  app aliases, named folders, website aliases, workflows, approved successful mappings,
  bounded metadata activity, atomic replacement, stale-file conflict detection, and reset.
- Added Settings → Agent / Mac Control, with model status/disk usage/preparation/removal,
  cancellation, enablement, application pickers, alias/workflow entry, editable JSON,
  confirmation policy, successful-command approval, activity, reset, and live benchmark.
- Routed exact configured aliases through the existing native executor. Macros wait
  for final speech, retain serial dependencies, and never waive consequential confirmation.
- Fixed cancelled-agent ownership before immediate new sessions, in-flight Laya unload /
  reload / removal ownership, reset ownership, idle microphone teardown, and stale tap /
  waveform callbacks. Added a release-after-draining regression check.
- Preserved explicit HTTP URLs (the old normalizer changed them to HTTPS) and accepted
  deterministic ASR punctuation/articles at command headers without weakening blank-note
  title validation or altering the remaining payload.
- Added final full-recording STT validation for explicit agent sessions after real streaming
  ASR exposed slot errors. Ordinary dictation retains its prior final policy. Cancellation
  during validation cannot publish a stale final.
- Serialized batch inference across suspended SDK calls, including cancellation and
  queued requests, with tests proving that cancelled predictions drain before reuse.
- Recorded first action at native execution, rather than confirmation preparation, and
  total completion only after final decisions and terminal action states.

Implementation and usage: [OPERATIONAL_MEMORY.md](../../OPERATIONAL_MEMORY.md).

## Automated checks

The complete Swift suite passed **three consecutive final runs: 222 tests per run,
zero failures, six opt-in checks skipped**. The skipped tests need explicit real-model packages /
audio fixtures; the separate real streaming runs below exercised available test fixtures.

Commands (from the workspace parent):

```sh
swift test --package-path LocalFlow
xcodebuild -project LocalFlow/LocalFlow.xcodeproj -scheme LocalFlow \
  -configuration Debug CODE_SIGNING_ALLOWED=NO \
  -derivedDataPath LocalFlow/.build/AgentDebug build
git -C LocalFlow diff --check
```

The final unsigned Xcode Debug build succeeded. The Python Laya calibration suite
passed **5 tests**. SwiftPM and Xcode FluidAudio checkouts are clean and remain at
`19600a485baa4998812e4654b70d2bab8f2c9949` (0.15.5); dependency lockfiles were preserved.

An initial restricted-sandbox run could not access native dictionaries/audio/file
coordination; normal local test access resolved those failures. The header-punctuation
change initially violated the existing blank-note-title fixture; that regression was
corrected before the clean final runs. No production native actions were used in tests.

## Benchmarks and measured limits

The scripted benchmark repeats all ten daily scenarios five times and sends repeated
partial notifications. **50 scenario runs, zero duplicate actions, zero incorrect
actions, zero missing expected actions**. Its timings are event/control-flow overhead,
not a measurement of microphone speech recognition or real Mac completion.

Real inference used test-owned APFS clones of existing streaming and full-recording
Parakeet assets plus fixed synthetic speech files. No model downloads occurred. All
effects were mocked, and decisions used the deterministic fallback; these runs do not
measure Laya inference, TCC, or native UI completion. Audio was fed at its original rate.
Model loading/initial ANE compilation happened before the timed sessions.

Final agent-path measurements across the ten fixtures:

| Metric | Median |
| --- | ---: |
| First partial STT | 637.6 ms |
| Segment decision | 0.27 ms |
| Time to first native invocation | 1,803.2 ms |
| Total session completion | 2,356.1 ms |

The run invoked all **12 expected tool kinds**, with **zero duplicates**, but had
**5 exact-slot mismatches in 12 invocations (41.7%)**, across scenarios 2, 3, 8, 9,
and 10. The comparator includes exact URL, note/body/title, reminder, and search
arguments, including casing/punctuation. These are real measured quality failures,
not hidden by the passing benchmark-runner tests. Full-recording final validation
improved the person search and Wikipedia navigation compared with streaming-only
finals, and command-header parsing recovered previously unsupported note/reminder
requests. Remaining exact-slot quality needs live-speech evaluation; daily reliability
has not been established by these synthetic fixtures.

Reports contain only timings, sources/tool IDs, counters, and scenario numbers:

- [Scripted results](scripted-results.json)
- [Streaming-only baseline](streaming-results.json)
- [Final refinement results](refined-results.json)
- [Measured summary](summary.json)

Metrics count sent invocations. Missing expected slots, failed effects, unverified
effects, out-of-order actions, and cancellation are reported separately. A browser
accepting a URL is not proof that the requested page loaded.

## Local launch / smoke check

An unsigned Debug build launched locally. The Settings window visibly contained the
new **Agent / Mac Control** navigation item. On clicking it, the computer-control
service returned `Sky Computer Use native pipe closed before response`; reconnecting
after resetting the tool session returned the same error. No LocalFlow crash report
was found at that point. This establishes launch/navigation visibility, not that the
Settings pane or ten real native scenarios passed a UI smoke test. Later source fixes
were rebuilt and tested, but a final interactive relaunch could not be verified through
the failed UI service.

The live spoken benchmark remains available in Settings. Microphone/TCC, actual Notes
and Reminders effects, Photo Booth/camera state, full-screen overlay focus, third-party
editor behavior, and browser page readiness remain manual-validation boundaries. No
permissions, existing notes/reminders, history, vocabulary, or production models were
changed to obtain passing results.

## Working-tree review scope

Task additions: `Shared/AgentMemoryStore.swift`, `Features/CommandMode/AgentBenchmark.swift`,
`Tests/SharedTests/AgentMemoryTests.swift`, `Tests/SharedTests/BatchOwnershipTests.swift`,
`Tests/FeaturesTests/AgentOperationalTests.swift`,
`OPERATIONAL_MEMORY.md`, and this evaluation directory. Updates are concentrated in the
shared service container / Settings, command parser/coordinator/native execution,
decision-model lifecycle, audio capture, serialized batch ownership, streaming final routing, and their regression
tests. Many other modified/untracked files predate this task.

At final inspection the tracked Git diff (including prior work) covered **22 files,
1,496 insertions and 677 deletions**; untracked additions are reported separately by
`git status --short`. No files were staged or committed. See the working tree itself
for the complete review, since a tracked diff alone excludes the pre-existing and new
untracked agent sources/tests.
