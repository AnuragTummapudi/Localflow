# Semantic macOS control substrate

Implemented locally; Qwen3.5-4B and its existing native MLX runtime remain unchanged. No vision, coordinates, speech changes, automatic voice fallback, downloads, push or release.

| Item | Result |
| --- | --- |
| Architecture | One AX service owned by `MacNativeToolSystem`, behind the existing registry/executor/ledger. Public [Apple AX APIs](https://developer.apple.com/documentation/applicationservices/axuielement_h); no keyboard/coordinate fallback. |
| Tools | `ui.observe`, `ui.focus`, `ui.press`, `ui.setValue`, `ui.select`, `ui.scroll`, `ui.raiseWindow`. |
| Observation | Running/frontmost app metadata, windows and semantic elements. Depth 12, 400 visited nodes, 80 returned elements, 128-character labels/values; planner sees at most 16 relevant elements. Secured fields excluded. UI trees are not logged or persisted. |
| Actions | Supported AX press/selection/focus/value/raise/scroll operations only. Window raising also uses native application activation. Unsupported actions fail closed. |
| Verification | Fresh readback verifies selected/focused/value/window state. Acceptance alone is UNVERIFIED; scrolling without readable completion remains UNVERIFIED. |
| Staleness | Observation generation IDs expire after 30 seconds and are invalidated on replacement, action or cancellation. Fresh app identity, topology and element state are checked before sending; window/dialog/app/element changes reject old IDs. |
| Safety | Frozen app/goal atoms, scoped IDs and schemas. UI strings cannot grant apps/tools/policy. Structural navigation can be safe; unknown buttons, ordinary text writes and consequential labels require frozen confirmation. Confirmation displays the host-frozen target label. UI Undo is not advertised. |
| Redundancy | Delivered resolution disappears from scope; equivalent UI effects are filtered/collapsed. Existing selected/focused/readback state can satisfy an atom without another effect. |
| FINISH | The host ends before another model turn when all supported goal atoms have native evidence. Premature model FINISH is rejected. |
| Native tests | Finder and System Settings observed; Downloads and Accessibility navigation verified in an earlier native run. Owned test app field focus, harmless text readback and window raising verified; expired IDs and unsupported actions rejected. Later Finder sends also rejected stale observations. |
| Qwen qualification | 12/12 fixture outputs parseable, correct tools and accepted scoped arguments; 8/8 element calls correct. Two actual shared-ledger missions observed UI but did not finish. Zero unrelated real actions; injection/foreign-app/unknown-tool/confirmation protections passed targeted tests. Fixtures are not evidence of real mission completion. |
| Storage | 4.22 GB logical generated artifacts removed. Free space 8.54 GB before → approximately 9.27 GB after (APFS varies). Active Qwen 3.061 GB; runtime 0.183 GB. Active Laya, source, Git and final evidence preserved. |
| Regression | One full Swift run: 330 tests, 17 skips, zero failures. Final refinements: 21 targeted tests, four opt-in skips, zero failures. Final unsigned Xcode Debug build succeeded. `git diff --check` passed. |

Evidence: [summary](Evaluation/SemanticAX/summary.json), [native results](Evaluation/SemanticAX/real.json), [earlier native successes](Evaluation/SemanticAX/native-history.json), [12 Qwen fixtures](Evaluation/SemanticAX/qwen.json), [two real Qwen missions](Evaluation/SemanticAX/qwen-live.json), [AX boundary diagnostic](Evaluation/SemanticAX/boundary.json), [storage audit](Evaluation/SemanticAX/storage.json).

Limitations: headless/background follow-up AX observations inconsistently expose sidebar targets. Strict whole-observation freshness can reject a usable target when another part of the UI changes. Planner app grounding currently covers Finder/System Settings and their frozen foreground context; the AX backend can inspect other running apps. Custom/canvas/inaccessible UI remains unsupported. Permission readiness uses the existing Settings link without prompting or self-authorization. Unknown application UI needs further qualification before visual fallback.

Reproduce opt-in checks with `LOCALFLOW_AX_REAL=1`, `LOCALFLOW_QWEN_AX=1`, `LOCALFLOW_QWEN_AX_LIVE=1` or `LOCALFLOW_AX_DIAGNOSTIC=1` and the corresponding `SemanticAccessibilityTests` filter. The small AppKit fixture is built from `Tests/Fixtures/SemanticAX` if absent; its process is owned and stopped. Ordinary tests use an injected backend.

NOT READY FOR LOCAL VISUAL FALLBACK ITERATION
