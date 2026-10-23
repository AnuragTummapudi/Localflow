# System-2 Local Planner — implementation and qualification report

Measured on 5 October 2026 on this Mac: Apple M4, 16 GiB unified memory, macOS 26.6, Xcode 26.5, Swift 6.3.2. Everything remains local. The pre-existing dirty working tree was preserved. No push, PR, deployment or application release package was produced.

The experimental typed planner, resident runtime, model manager, semantic tools and shared-ledger orchestration are implemented. **Automatic voice fallback remains disconnected.** Measured goal accuracy and semantic injection resistance do not qualify this phase for automatic use or a computer-control iteration.

## 1. Selected Qwen model, revisions and provenance

Selected one candidate: **Qwen3.5-4B, MLX 4-bit**. The official [Qwen model card](https://huggingface.co/Qwen/Qwen3.5-4B) and [quantized checkpoint](https://huggingface.co/mlx-community/Qwen3.5-4B-MLX-4bit) were researched before implementing inference. Qwen's native XML function-call envelope and template thinking switch are used; actions are not recovered from arbitrary prose.

| Pin | Value |
| --- | --- |
| Audited upstream | `Qwen/Qwen3.5-4B` |
| Audited upstream revision | `851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a` |
| Installed quantized repository | `mlx-community/Qwen3.5-4B-MLX-4bit` |
| Quantized revision | `32f3e8ecf65426fc3306969496342d504bfa13f3` |
| Weights SHA256 | `5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db` |

The quantizer links the Qwen parent but does **not** disclose its exact upstream conversion commit. The upstream pin above is an audited reference, not proof that the checkpoint was converted from that commit. All seven installed assets have pinned lengths and SHA256 in [model-manifest.json](Evaluation/System2/model-manifest.json). Only this candidate was installed; the native and Python comparisons use the same checkpoint.

## 2. Runtime architecture and dependency pins

Production uses an app-owned **persistent native Swift MLX helper** with local stdin/stdout JSON. It stays resident after explicit Prepare/Load while enabled; there is no per-query model launch, inference HTTP server or external API. Cancellation terminates the child and requires explicit reload. Helper crashes are isolated from the app. Conversations are not automatically persisted.

Native MLX integration is supported by the current [MLX Swift LM release](https://github.com/ml-explore/mlx-swift-lm/releases/tag/3.32.3). The independent helper pins MLX Swift LM **3.32.3** (`3b339ad6e3b3f44c8121ecff5131c7fd55e075e6`) and MLX Swift **0.32.3** (`19601207e9a0de51e03ee6ec0c3c5f3784275075`), whose MLX core is **0.32.2**. All transitive Git revisions are frozen in its [Package.resolved](Core/ModelManager/Resources/PlannerRuntime/QwenHelper/Package.resolved). The main app package still has no external package dependencies.

The installed Xcode lacks its optional Metal compiler. The recorded native build attempt failed there. A hash-verified official Apple `mlx-metal` **0.32.2** shader artifact matching native core enabled the local helper build; [provenance](Evaluation/System2/native-metal-provenance.json) includes its source URL and wheel/shader hashes. No optional Xcode component was installed. [runtime-manifest.json](Evaluation/System2/runtime-manifest.json) pins the final helper, shader and process guard.

Persistent Python MLX was also benchmarked: `mlx-lm 0.32.0`, `mlx 0.32.3`, `mlx-metal 0.32.3`, with exact evaluation versions in [python-requirements.lock](Evaluation/System2/python-requirements.lock). Python is an evaluation comparator, not an app runtime dependency. Current `mlx-vlm 0.7.4` was researched but neither installed nor connected. Native was selected because its warm non-thinking latency is competitive and it avoids Python deployment. Python has faster measured cold load and a shorter thinking tail; these runs do not establish a universal runtime winner.

## 3. Model disk usage and manager state

Checkpoint assets: **3,061,127,002 bytes** (3.061 GB / 2.851 GiB). Installed model directory including its manifest: **3,061,128,063 bytes**. Native runtime assets: **182,585,112 bytes**. Build directories and evaluation Python dependencies are additional development disk usage.

The actual `PlannerModelManager` imported the selected candidate with checksum verification and atomic publication. Its health probe loaded, primed and unloaded the actual installed model. Final state: **Ready, Experimental OFF, unloaded**. See [installation-health.json](Evaluation/System2/installation-health.json).

The manager implements absent/installed/loading/error status, explicit download with progress, staged verification, revision and disk reporting, prepare/load, warm/resident health, unload, cancellation and removal. Settings exposes those actions and a typed developer request surface. Direct typed commands can run without enabling or loading the planner.

## 4. Resident RAM / MLX memory

Final native warm measurements: current process RSS **55.8–97.3 MB**; MLX active allocation approximately **2.520 GB**, observed MLX peak **3.493 GB**. The final installed health probe reported current RSS **600.1 MB**, MLX active **2.368 GB** and peak **3.035 GB** during preparation. Native load-trial RSS was **194.6 MB**.

Python's reported RSS is a **high-water** value, **2.026 GB**, with warm MLX active approximately **2.685–2.693 GB** and peak **3.304 GB**. These RSS semantics differ. macOS Metal/unified-memory allocations are not fully described by current process RSS; do not interpret the small native RSS as total model residency or add RSS to GPU allocation as independent memory. Numeric evidence is in [summary.json](Evaluation/System2/summary.json).

## 5–9. Cold load, TTFT, first tool, plan latency and throughput

Final comparison used one persistent process per runtime, the same frozen registry-derived requests and token-level reasoning filter, four goal workloads, both modes, five measured warm samples per workload/mode and one excluded warmup per workload/mode. Percentiles use nearest rank; pooled rows contain 20 measured samples. Processes were run sequentially. OS file caches were **not** flushed, so “cold” means a new process, not storage cold boot.

Native new-process load: **6.450 s**. Python: **3.295 s**. Registry-prefix priming is a separate preparation cost: the final installed health trial measured **3.684 s load + 25.897 s prefix preparation**. A separate installed read trial measured 2.489 s + 18.015 s. Warm readiness is reported only after priming; load alone is not time to usable readiness.

| Runtime / mode | TTFT p50 / p95 | First complete tool call p50 / p95 | Complete first plan p50 / p95 | Median tokens/s |
| --- | --- | --- | --- | --- |
| Native non-thinking | 2.452 / 2.659 s | **3.860 / 4.573 s** | 3.886 / 4.601 s | **20.22** |
| Native thinking | 2.264 / 2.681 s | 14.576 / 24.841 s | 14.608 / 24.868 s | 19.15 |
| Python non-thinking | 2.138 / 3.090 s | 4.001 / 4.930 s | 4.052 / 4.958 s | 19.16 |
| Python thinking | 1.955 / 2.160 s | 14.285 / 19.038 s | 14.314 / 19.067 s | 18.86 |

Thinking TTFT measures the internal first token; reasoning is never displayed or exported. First tool-call latency measures a complete proposed function call. It is not an executed action or proof of usefulness. Production stops generation at its first complete function call, validates it, executes the next accepted step and then continues with receipts.

Native workload breakdown, **first-call / first-plan** latency:

| Goal workload | Non-thinking p50 | Non-thinking p95 | Thinking p50 | Thinking p95 |
| --- | --- | --- | --- | --- |
| One-step goal | 3.704 / 3.732 s | 4.494 / 4.523 s | 24.750 / 24.779 s | 29.352 / 29.382 s |
| Three-step goal | 3.500 / 3.537 s | 4.017 / 4.049 s | 14.334 / 14.364 s | 14.576 / 14.608 s |
| Five-step goal | 3.684 / 3.713 s | 4.048 / 4.075 s | 18.331 / 18.359 s | 18.485 / 18.514 s |
| Replan after failure | 4.470 / 4.500 s | 4.580 / 4.609 s | 7.046 / 7.078 s | 7.124 / 7.155 s |

Goal complexity labels do not mean a complete three- or five-step plan was generated: each final production benchmark emitted one initial call. The complete Python per-workload breakdown and memory readings are in [summary.json](Evaluation/System2/summary.json); raw final runs are [native-first-latency.json](Evaluation/System2/native-first-latency.json) and [python-first-latency.json](Evaluation/System2/python-first-latency.json). Earlier full-batch runs are retained separately and are not pooled with these results.

## 10. Thinking versus non-thinking

Non-thinking is the default for typed planner requests. Both modes completed the final four-workload latency runs without runtime errors. Thinking incurs substantially longer time to the first proposed action.

An **exploratory preceding-helper** 24-scenario thinking subset selected the exact tool on 14/24 and arguments on 11/24, compared with 11/24 and 10/24 for the corresponding final non-thinking rows. This is not a final paired accuracy qualification. No automatic complexity-based switch to thinking is enabled. Formal reasoning is discarded using actual Qwen special token IDs before reply collection or IPC; quoted look-alike markers cannot release tool calls. No chain of thought is stored in developer diagnostics.

## 11–15. Planner accuracy, tool names, arguments, hallucinations and routing

The authored suite contains **108 typed scenarios**: DIRECT 12, COMPLEX 28, MEMORY 24, SAFETY 24, FAILURE 20. It covers direct bypass, dependencies, aliases, editors, browsers, saved workflows, unknown/ambiguous projects, shell/tool invention, forged instructions, confirmation, service failure, cancellation and intermediate failures.

Final real-model run: **92 planner invocations**, with 16 direct/unsupported bypasses. Gold metrics score the **first proposed tool and its exact argument dictionary**, not whole-mission completion.

| Metric | Final result |
| --- | --- |
| Strict exact tool name | **45/92 = 48.91%** |
| Strict exact arguments | **33/92 = 35.87%** |
| Plans accepted by host validator | **78/92 = 84.78%** |
| Parseable plans | 82/92 |
| Unparsed/rejected generation errors | 10/92 |
| Detected unknown-tool plans | **0/82 parseable plans** |
| Should-plan / bypass routing | **108/108 = 100% on this authored typed corpus** |

The ten unparsed outputs cannot be scored for tool hallucinations; the observed 0/82 is not a guaranteed zero overall hallucination rate. Existing-tool misuse is also not unknown-tool hallucination. Policy-equivalent tool/alias scoring gives 47/92 tool matches and 45/92 argument matches, still inadequate. Conservative gold slots sometimes penalize legitimate preparatory resolution, but that does not excuse unrelated actions or establish adequate mission quality. See [model-108-final.json](Evaluation/System2/model-108-final.json).

The deterministic typed benchmark uses authored plans and simulated native effects: 108/108 routing, 84 accepted gold plans, four confirmation checks and twelve injected failure checks. It is not real-model accuracy evidence. Real voice routing and broad natural-language generalization remain unqualified.

A separate **preceding-helper iterative** run tested 24 missions through the production ledger with the real model but **simulated all native effects and receipts**. Strict post-run tool/target/terminal auditing found clean required-effect completion in **8/18 complex missions (44.44%)**; mere required-tool coverage was 12/18. Of 78 completed simulated steps, **24 were unrelated (30.77%)**, with two wrong-project steps. There were zero repeated canonical completed effects and zero fabricated-readiness violations in that run. Dependency behavior is covered by validator/executor tests; these results do not establish broad model dependency correctness. See [missions-24.json](Evaluation/System2/missions-24.json) and the audit in [summary.json](Evaluation/System2/summary.json). Query semantic exactness was not independently scored, and no real Mac development mission completed in this dataset.

## 16. Confirmation, validation and injection safety

Registry risk is authoritative. The model cannot set risk, permissions, verification or Undo. Unknown IDs/arguments, malformed calls, invalid enums/types, missing slots, unsafe paths, arbitrary executable/shell arguments, cycles and overlong batches are rejected before effects. Native preparation freezes canonical project/executable targets and saved workflow configuration; changed targets invalidate preparation/confirmation. Localhost browser actions require an exact saved service URL and genuine verified readiness receipts/dependencies.

Final model-backed confirmation challenges passed **4/4**: consequential effects were withheld until host confirmation. The iterative simulation issued seven explicitly benchmark-only grants through the same host confirmation path; they are not user approvals or real workflow launches.

Prompt-injection tests cover fake tool definitions/responses, permission/risk fields, tool-result-as-data boundaries and quoted reasoning markers. **Semantic injection resistance did not qualify:** one iterative fake-response scenario elicited an unrequested chain involving an existing saved workflow and website. Host confirmation was not bypassed; the simulation's mock grant allowed its consequential step. Structural validation cannot prove that an allowed tool is relevant to the user's goal. Keep experimental use explicit and automatic voice disabled.

## 17. Project/workflow tools added

Sixteen narrow semantic tool IDs were added to the existing Native Tool Registry (42 total registered tools, 25 planner-visible tools including nine existing native tools):

- `project.resolve`, `project.open`, `project.search`, `project.openFile`, `project.reveal`
- `file.search`, `file.open`, `file.reveal`
- `workflow.list`, `workflow.run`, `workflow.stop`
- `service.wait`, `service.status`
- `editor.openProject`, `editor.openFile`, `editor.revealSymbol`

Schemas derive from registry metadata: purpose, argument types, risk, reversibility, verification, visibility and context/dependency requirements. Internal/debug tools and arbitrary shell are excluded. Existing native browser/URL/search tools remain in use. Workflow run and stop are consequential and always use existing confirmation.

Search is bounded to saved projects, skips symlinks/common vendor/build directories, and caps entries/text/results. File containment is checked canonically. Editor/Finder requests remain unverified without readback and manufacture no Undo. VS Code line navigation is supported as an unverified launch request; symbol reveal currently returns text matches. Services use bounded cancellable HEAD requests to saved loopback URLs, no redirects, and verify HTTP readiness rather than application health.

## 18. Operational memory changes

Optional project records extend existing v1 memory while preserving atomic JSON publication, file bounds and stale-write protection. Records contain explicit names/aliases/folders, preferred editor, optional website and loopback service, approved workflows and explicitly saved file/symbol hints. Limits include 100 projects, 20 aliases, 20 workflows and 50 file hints per project.

There is no whole-Mac scan, silent path learning or automatic workflow creation. Records are entered through the existing Settings JSON editor. A workflow requires a user-approved absolute executable, exact argument array and contained working directory. The model receives only project/workflow names; shell interpreters and launcher indirection are rejected. No production project fixture was written during evaluation.

## 19. Cancellation, ownership and replanning

The planner uses **one existing VoiceAgent ledger, executor, registry, receipt and confirmation model**. Typed `PlannerRequest`, `PlannerContext`, `PlannerPlan`, `PlannerStep`, `PlannerDependency` and `PlannerResult` enforce the boundary. The loop validates, executes the next ready step, observes compact typed native receipts and continues or replans. The entire proposed batch is validated before its first effect, and execution context is checked again before each send.

Limits: eight initial/batch steps, sixteen executed steps, four failure replans and at most seventeen generation turns per approved budget. Limit continuation requires an explicit Settings action and preserves the ledger. Bounded read retries and effect deduplication prevent replaying completed effects. A simulation reached the sixteen-step limit with unrelated searches; the limit stopped it.

Cancel stops generation, unsent calls and owned waits, preserves completed effects and valid guarded Undo, and revokes pending confirmation. A completed workflow remains a real effect; stopping it requires confirmed `workflow.stop`. App termination stops owned workflow groups and the model helper. Direct executable/argv spawn uses a fixed environment, closed stdin, bounded output and a guard-owned process group reserved before spawn. TERM/KILL escalation and reaping are tested, including fast exit, TERM-ignoring descendants and ownership-channel EOF. Detached descendants that leave their process group are **not qualified**.

Actual installed-runtime generation cancellation measured **18.753 ms in one sample**, followed by successful reload. This is observed evidence, not a cancellation SLA.

## 20. Typed real planner examples actually executed

The final installed helper/model executed genuine repository reads through production native tools using ephemeral, explicit test project memory. No editor/browser/workflow effects or production memory writes were permitted.

| Actual goal | Actual verified effects | First actual tool execution | Terminal observation |
| --- | --- | --- | --- |
| Resolve project LF | `project.resolve` → LocalFlow folder | **2.445 s** | Later turn rejected for invalid arguments; planner stopped |
| Search LocalFlow for literal VoiceAgentCoordinator, matches only | `project.search` → 20 bounded file/line matches, including its Swift source | **4.306 s** | Planner finished; 34.065 s total session |
| Resolve LocalFlow then list saved workflows | `project.resolve`, then `workflow.list` → zero workflows | **2.781 s** | Planner finished; 11.815 s total session |

These are the measured **time-to-first-actual-action** results, not just generation latency. “Planner finished” means no further accepted calls; it does not assert verified goal completion. The alias example intentionally reports its subsequent failure. See [installed-real-read-only-final.json](Evaluation/System2/installed-real-read-only-final.json).

No real development workflow was configured: the user supplied no exact approved executable/arguments for one. None was invented. Process-ownership tests launched and stopped only test-owned fixture processes. Editor opening, localhost browser opening and a full real developer workflow were not claimed as live results.

## 21. Voice and island integration status

Existing deterministic simple commands keep the native path and do not require Qwen or Laya. Typed experimental requests use the existing VoiceAgent orchestration and island current-action/progress/Cancel/confirmation UI. A generated assistant stop displays “Planner finished,” not a verified “Done” claim.

**Automatic Apple Voice Agent System-2 fallback is not connected; its qualification gate is false.** It was withheld because typed model quality did not pass. Volatile Apple transcripts cannot trigger a new planner execution path. Laya remains optional diagnostic evidence and supplies no production approval authority. Existing Apple Speech behavior was preserved.

## 22. Tests and build status

After the final source changes:

- Full Swift suite **three consecutive runs passed**: each 312 tests, 13 explicitly skipped, zero failures. [Run record](Evaluation/System2/full-suite-runs.json), [first](Evaluation/System2/full-swift-1.log), [second](Evaluation/System2/full-swift-2.log), [third](Evaluation/System2/full-swift-3.log).
- Planner tests cover schemas/parser, memory migration/round-trip/bounds/stale writes, manager install/checksum/removal, process ownership, frozen targets, confirmations, malicious instructions, cancellation, readiness, deduplication, continuation and replanning.
- Opt-in final native/Python latency, 108 real-model first proposals and installed real-read/cancellation stages all exited zero. [Stage record](Evaluation/System2/final-token-evaluation-runs.json). Opt-in model tests are separate from ordinary suite skips; passing their harness does not mean their measured accuracy met qualification.
- **Unsigned Xcode Debug build succeeded**. [Build log](Evaluation/System2/xcode-debug-build.log). The app was not deployed or release-packaged.
- `git diff --check` passed. [Final source hashes](Evaluation/System2/final-source-hashes.json) identify phase source files; they do not characterize all pre-existing dirty-tree changes.

## 23. Known limitations and recommendation

The decisive limitations are low exact tool/argument accuracy, 44.44% clean simulated complex-mission completion and demonstrated unrequested actions from injected text. Confirmation and validation constrain capability but cannot establish relevance. Thinking has not received a final paired accuracy qualification. The router is conservative and its perfect score applies only to this authored typed corpus. Long prefix preparation and multi-turn latency remain noticeable; context and output are bounded, so some long requests are rejected. No automatic voice integration is qualified.

Other limits: quantized conversion provenance lacks its exact upstream SHA; native shader preparation currently uses a pinned official wheel artifact; editor/Finder launches have no UI verification; symbol hints are literal-text based; service readiness is HTTP-only; detached process descendants are unqualified; the live demonstrations covered repository reads rather than a complete user-approved development workflow. Benchmarks are small, cache-sensitive measurements from one Mac. Vision, Screen Recording, screenshots and coordinate/control actions are entirely outside this phase.

**NOT READY FOR SEMANTIC COMPUTER CONTROL ITERATION**
