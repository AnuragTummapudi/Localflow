# Guided reality validation — actual Debug application

Build the unsigned Debug app and open Settings → Agent / Mac Control →
**Developer reality gate · Debug only**. Enable transient evidence. This pane
uses the existing capture/coordinator/executor/readback paths, with no mocked
native effects. It does not install models, learn commands, log transcripts or
change permission settings automatically.

The pane retains, in memory only, the latest streaming transcript, authoritative
final transcript and speech source, bounded decision traces, exact action
arguments, actual receipt output, verification and timing events. Closing or
disabling the pane clears its diagnostic evidence. Normal metadata activity
contains no payloads. No new persistent conversational memory was introduced.

| Step | Procedure / exact speech | Completion evidence |
| --- | --- | --- |
| 1 | Check/request microphone permission | OS authorization status; separately prove captured speech in step 4 |
| 2 | Check Accessibility trust; open System Settings if needed | Trust status for this Debug process |
| 3 | Check Notes/Reminders Automation through subsequent native actions | Approved OS prompts and successful native readback, not generic permission assumption |
| 4 | Say `Reality gate transcript check` | Partial and final displayed; unsupported text produces no native action |
| 5 | `Open Notes` | Verified running/foreground application receipt |
| 6 | `Create a note called Reality Gate 2026` | Exact title, readback and created note ID |
| 7 | `Append to current note: Exact sentence for the reality gate.` | Prerequisite verified test note; captured note ID must match that receipt, confirmation and exact readback |
| 8 | `Open my browser` | Configured preferred browser identity, verified application receipt |
| 9 | `Search for tardigrade habitats` | Exact query/URL; navigation acceptance alone is UNVERIFIED |
| 10 | `Open https://example.org/RealityGate?Case=Exact` | Exact case/path/query preserved; a sent URL is UNVERIFIED page completion |
| 11 | `Create reminder Reality Gate follow-up` | Exact title and native reminder readback |
| 12 | `Open Photo Booth` | Verified app launch only; no photo/video capture |
| 13 | `Open Notes then open my browser then search for stellar spectra` | Ordered exact invocations, zero duplicates, independent verification for each |
| 14 | `Open Chrome actually Safari` | Correction timing and final selected target; no unapproved corrected replay |
| 15 | `Open Notes then search for cancellation reality gate`, cancel while executing | Cancellation phase and any already-sent effect reported honestly; cancellation cannot retract a request |
| 16 | Prepare real lock confirmation; confirm preview without effect | The real executor's single-use grant is consumed; native lock effect is never sent |

Keep **VERIFIED**, **UNVERIFIED**, and **FAILED** distinct. The exact invocation
comparator is separate from completion verification. Its payload gold for note
title/body, reminder and URL is explicit rather than extracted by the parser
under test. Receipt note IDs guard the append scenario against another selected
note. Settings interactions restore Notes focus for recording/Finish/confirmation;
the existing non-key island policy stays intact.

Step 16 tests the real confirmation machinery, not locking the computer. Cancelling
an old preview only revokes its own grant. A newer native confirmation survives.
The regression suite proves no effect and no grant replay at this boundary.

## Actual results in this iteration

An intermediate unsigned Debug build launched. Its Settings sidebar showed Agent / Mac
Control. A fresh UI control session also failed for the then-current rebuilt Debug
bundle. The later legacy capture payload fix was rebuilt again; that final binary
launch remains unverified because the UI service is unavailable. Selecting that pane failed in the UI control service:
`Sky Computer Use native pipe closed before response`.

The new crash report was for `SkyComputerUseService`, `EXC_BREAKPOINT / SIGTRAP`,
with `Array.remove(at:)` in the failing stack. The exact LocalFlow Debug executable
was still running. A later screenshot request hit the same closed pipe. This is
evidence of a failed automation boundary; it does **not** prove that LocalFlow's
pane, microphone, permissions or native sequence passed.

All 16 real validation steps therefore remain **UNVERIFIED** in the result file.
The observed launch/sidebar and the failed navigation attempt are recorded
separately. Unit confirmation/focus source checks and synthetic ASR benchmarks
cannot substitute for a real microphone → exact action → native verification run.
