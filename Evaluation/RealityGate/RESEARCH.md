# Official Laya research — 4 October 2026

Research assets and experiments are local. No production checkpoint or app dependency was replaced.
Pinned assets and hashes: [public-provenance.json](public-provenance.json),
[multilingual](results/multilingual-assets.json), [typed](results/typed-assets.json).

| Candidate | Pinned revision | Parameters | Role |
| --- | --- | ---: | --- |
| English | `55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851` | 421,293,830 | Existing backbone; current official revision matches our original pin |
| Multilingual | `e4e9ddf21a7b1903b7acffd8814ad4307bf63a67` | 321,908,998 | Smaller mmBERT backbone; evaluated rather than assumed superior |
| Typed decisions | `1a793eb568e6718f15941d08f85432581df534e3` | 421,293,830 | Specialized checkpoint, not a Mac voice-control model |

These identities and parameter counts come from the official repositories and pinned Hub metadata:
[English](https://huggingface.co/convaiinnovations/laya/tree/55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851),
[multilingual](https://huggingface.co/convaiinnovations/laya-multilingual/tree/e4e9ddf21a7b1903b7acffd8814ad4307bf63a67),
[typed decisions](https://huggingface.co/convaiinnovations/laya-typed-decisions/tree/1a793eb568e6718f15941d08f85432581df534e3).

The current SDK is pinned to `laya==0.3.26` in isolated experiment storage. The
official source/docs revision read is `2e4d9c87e8b1621deb344eac7de5c7258f32f849`.
The typed model targets invoice processing, security incidents, customer service
and agent trace observability; transfer to our voice domain needs separate evidence.
[Official source](https://github.com/NandhaKishorM/laya/tree/2e4d9c87e8b1621deb344eac7de5c7258f32f849).

The current recipe uses four noisy logit projections with proper-scoring-rule
rewards plus cross entropy, separate encoder/head learning rates, gradient
checkpointing and temperature calibration. Inherited option-count temperatures
must be removed when fitting new calibration. Our pipeline uses the official
model/sequence/reward primitives and isolated split manifests. It does **not**
copy upstream publication steps or train on upstream/LocalFlow held-out examples.
[Official fine-tuning documentation](https://nandhakishorm.github.io/laya/finetune/).

A standalone official MPS recipe now exists, with micro-batch one and accumulated
gradients for Apple Silicon. Our local experiment uses its RLCD loss and checkpoint
format. The actual execution status, not the existence of a script, determines
whether training is reported as complete.
[Pinned MPS script](https://github.com/NandhaKishorM/laya/blob/2e4d9c87e8b1621deb344eac7de5c7258f32f849/notebooks/laya_finetune_typed_decisions_mps.py).

The browser specialization example illustrates domain-specific categorical
decisions and evaluation, not transferable Mac reliability. We added neither its
browser environment nor its generative data-production dependencies. Our corpus
is explicit assistant-authored speech, without Qwen or personal user data.
[Pinned browser example](https://github.com/NandhaKishorM/laya/blob/2e4d9c87e8b1621deb344eac7de5c7258f32f849/docs/finetune_browser_agent.md).

Router exposes language/script-based routing with resident preload/attach APIs.
Adding a second resident model is unnecessary for this English-focused gate;
LocalFlow still sends only the relevant utterance, final flag and language to
its optional decision engine. No application catalog, history or memory is sent.
[Router reference](https://nandhakishorm.github.io/laya/reference/router/).

CoreML EP supports provider options for MLProgram, compute units, static input
requirements and subgraphs. Availability alone does not prove that this exported
graph can initialize or run on Core ML. Both actual initialization attempts failed,
including one with graph rewrites disabled; they have no invented latency result.
[ONNX Runtime CoreML EP](https://onnxruntime.ai/docs/execution-providers/CoreML-ExecutionProvider.html).

Direct Core ML conversion requires an explicit input contract and must be followed
by varied-input output checks. Actual coremltools 9.0 conversion attempts encountered
unsupported mask operations. A constant-one lowering was tried in isolated code;
mixed integer/boolean masking still failed. No Core ML package was accepted.
[Apple conversion API](https://apple.github.io/coremltools/docs-guides/source/new-conversion-options.html).

The per-tensor INT8 experiment retains ONNX's hardlink protection, uses separate
APFS clones, and regenerates stale intermediate shape annotations without changing
operators or weights. Acceptance depends on measured held-out parity, confidence
and safety results, not disk savings. Production gates remain disabled.
