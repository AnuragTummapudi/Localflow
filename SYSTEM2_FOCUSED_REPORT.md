# Focused System-2 next-action iteration

Implemented native Qwen3.5 framed parsing, one action per turn, immutable `GoalEnvelope`, scoped registry schemas, host-resolved IDs, compact context and tail-action rejection. Exact host-known search/workflow equivalents are accepted; arbitrary values remain rejected. Decision tokens never create effects, and FINISH requires host satisfaction evidence. Native risk and confirmation remain authoritative. Automatic voice fallback remains off.

The pinned [native Qwen3.5 parser](https://github.com/ml-explore/mlx-swift-lm/blob/3.32.3/Libraries/MLXLMCommon/Tool/Parsers/Qwen35ToolCallParser.swift) accepts XML and Hermes JSON **inside `<tool_call>` framing**. Bare JSON, prose recovery and multi-action execution are rejected. No dependency upgrade, vision, Accessibility computer control, speech change or Laya training was added.

| Requested result | Measured result |
| --- | --- |
| 1. Parseability | Original phase 82/92 (89.1%); focused cohort **24/30 (80%)**. Same focused first pass was also 24/30. Different original corpus; no demonstrated parseability improvement. |
| 2. Tools exposed | Previously 25; **4.67 average, 8 observed maximum**, including three no-effect decision functions. Host maximum 12. |
| 3. Prompt tokens | Earlier warm samples averaged **3,221**; focused valid replies averaged **1,007**. After count covers 24 replies; rejected replies did not export token metrics. |
| 4. Correct next tool | **20/30 (66.7%)**, using authored acceptable tool sets. |
| 5. Arguments | **18/30 (60%)** exact after permitted host resolution; **13/30 (43.3%)** exact raw stable-ID dictionaries. |
| 6. Unrelated accepted actions | No accepted unrelated capability domains; **four redundant project-resolution decisions accepted** instead of the expected next action. |
| 7. GoalEnvelope escapes | **Zero accepted escapes** through the scoped validator. Unknown tools were never accepted. |
| 8. Injection / safety | Malicious result detail is removed before prompting and cannot enlarge domains, subjects, workflows or URLs. Unit escape attempts rejected; no unrelated workflow/browser effects. Existing confirmation/ownership tests pass. **FINISH remains 0/6**, so semantic reliability is not qualified. |
| 9. Real read-only missions | All four requested missions executed verified project/search reads, with zero unrelated effects. Each subsequently stopped on invalid decision output; none finished cleanly. |
| 10. Warm first-tool latency | Simple search **3.83 s p50 / 4.01 s p95**, roughly the old 3.86 s p50. File-goal and failure/replan results below; no overall speedup claim. |
| 11. Footprint | One active Qwen installation **3.061 GB**; runtime **182.586 MB**; planner development build/cache **2.006 GB**; evaluation artifacts **3.47 MB**. |
| 12. Disk cleaned | **3.884 GB logical files removed**: verified duplicate model staging, obsolete Python comparator and failed native helper build. Free disk observed **7.083 → 4.459 GB**; deletion did not translate into an observed free-space increase during this run. Active Qwen/Laya, user data, source/history and prior final summaries retained. |
| 13. Regression | **One** full Swift run: 316 tests, 15 skipped, zero failures. Unsigned Debug build succeeded; diff check passed. No push/deployment/release package. |

Five warm samples per workload, after separate prefix preparation:

| Workload | TTFT p50 / p95 | Complete call p50 / p95 | First real read p50 / p95 | Prompt tokens |
| --- | --- | --- | --- | --- |
| Project search | 1.58 / 1.81 s | 3.83 / 4.01 s | 3.97 / 4.27 s | 1,144 |
| Project + file goal, initial search | 1.98 / 3.95 s | 6.04 / 11.96 s | 6.20 / 12.25 s | 1,377 |
| Replan after failed search | 4.26 / 4.72 s | 6.96 / 8.47 s | 7.31 / 8.87 s | 1,050 |

Actual first reads for the four missions: find project **11.58 s** (`project.resolve`); find VoiceAgentCoordinator **17.22 s** (`file.search`); planner files **14.75 s** (`file.search`); continuation implementation **13.08 s** (`project.search`). These include scope-prefix preparation. No editor/workflow/browser actions were executed by the model tests. Cancellation measured **14.93 ms** in one sample.

Evidence: [summary](Evaluation/System2Focused/summary.json), [model/read results](Evaluation/System2Focused/results.json), [gold slots](Evaluation/System2Focused/authored-gold.json), [full suite](Evaluation/System2Focused/full-swift.log), [Debug build](Evaluation/System2Focused/debug-build.log), [cleanup audit](Evaluation/System2Focused/disk-cleaned.json).

The cohort retains 11 successful initial rows and rechecks 19 failed/tightened cases; this is not a full final model qualification. Known value equivalents are scored separately from raw IDs. The six FINISH failures remained strict rejections. Later clause scoping prevents mere search topics such as “workflow/browser code” granting those capabilities; the authored corpus scopes are unchanged by that hardening. The 108-case legacy benchmark was archived behind an opt-in flag and was not rerun. Fifteen default skips include optional integrations, that legacy benchmark and the focused model test run separately.

The recheck's recorded wall duration unexpectedly reached 63 minutes; its individual inference timings were much shorter. No further model run was launched, and these small latency samples should not be treated as controlled comparative performance. Four successful reads do not establish clean mission completion. Lexical scope derivation remains conservative; next-action selection, raw identifiers and termination still need improvement. No 9B model was downloaded.

**RUN QWEN3.5-4B VS QWEN3.5-9B BAKEOFF**
