# Continuous Voice Agent · macOS 26+

Start Voice Agent or press ⌘⇧Space. One capture session feeds Apple's SpeechAnalyzer/SpeechTranscriber. Volatile and finalized ranges both reach the existing deterministic segment ledger; authoritative phrase finals do not stop capture. Stop drains trailing finals. Escape cancels pending grants and owned tasks; sent native requests cannot be retracted.

The production path is microphone → Apple Speech range revisions → local Laya System-1 observations when needed → deterministic slots → ToolRegistry → native macOS APIs/Accessibility/Apple Events → readback receipt → the existing nonactivating island. There is no planner, generated tool call, arbitrary shell command or visual-control subsystem.

Exact known commands bypass Laya. Uncertain speech uses conditional actionable, more-speech, correction/replacement and coarse-family questions. Those scores can withhold work; native risk metadata owns confirmation. No model-generated identities, URLs, queries, note/reminder bodies, filenames or plans exist. Unreviewed model policies remain disabled.

## Continuation guarantees

The ledger retains transcript/Apple revision identity, phrase audio identity and finalization, stable/volatile state, source word ranges, consumed cursor, command ordinal, typed argument deduplication, dependencies and task ownership. Revisions revoke unsent proposals before asynchronous inference. Completed or possibly delivered actions are not retried. Independent app/web requests survive unrelated unsupported/failed predecessors. Contextual text/note actions require verified context. Unknown intervening context cannot reuse an earlier note.

Exact unique app names and complete navigation targets may execute at a closed stable volatile boundary with distinct observations and the existing fitted 0.7-second stable-prefix interval. This interval was fitted to synthetic regression traces, not demonstrated as population accuracy. Payloads and consequential actions require Apple's final ranges; consequential actions still require frozen single-use confirmation. Apple’s natural finalized ranges and stop finalization are described in STREAMING.md.

`Open Notes`, pause, `Open Safari`, pause, `Open Chrome`, pause, `Open github.com` can use one session. Text/search payloads remain indivisible without a real phrase/pause boundary, protecting embedded command words from becoming tools. Same app at a new segment is a new invocation; repeated revisions of the same segment are deduplicated. Recording final flushes trailing commands without replay.

`Open Chrome, actually Safari` resolves deterministically to Safari before sending. If Chrome was already sent, the corrected instruction needs authoritative speech plus confirmation. LocalFlow does not quit Chrome as an implied Undo.

## Notes and feedback

Compound `create a new note, call it Title, and write Body` can remain one exact create. Across separate finalized utterances, `Create a new note` uses the fixed title Untitled, `Call it <title>` requests a guarded current-note rename, and `Write <body>` requests an exact append. Rename/append are consequential and require confirmation. Rename supports only an existing simple heading and preserves body bytes; rich/unsupported titles are rejected. The current note must still be selected and foreground Notes at preparation and execution.

Native receipts distinguish VERIFIED, UNVERIFIED and FAILED. Browser request acceptance is UNVERIFIED page completion. Reversible actions offer Undo only when a verified receipt includes an owned restoration. The island returns to listening after brief terminal feedback and new speech supersedes old feedback.

Agent Readiness displays Microphone, Accessibility, Apple Speech Assets, Automation and Laya. Automation is observed without requesting permission in advance; each real tool triggers its native prompt. Errors identify the permission and Settings action. Reminders has separate EventKit permission.

Settings Debug mode contains one focused acceptance workflow and transient original/selected/alternative speech, final text, questions/results, parser, exact tool/arguments, receipts, verification and timing. Source-level fixtures use mock native effects. Actual microphone/native observations are separately recorded in CORE_ARCHITECTURE_REPORT.md and Evaluation/CoreLock.


## System-2 phase

Experimental typed System-2 execution is integrated with this coordinator’s existing ledger and executor. Direct typed commands bypass the model. Automatic voice fallback remains gated off pending measured planner qualification, independently of Laya authority. Existing Apple finality/correction and deterministic volatile execution rules are unchanged. See [SYSTEM2_PLANNER.md](SYSTEM2_PLANNER.md).
