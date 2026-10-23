# LocalFlow-Laya-v2: local System-1 decisions

LocalFlow targets macOS 26+. Apple supplies the only speech stack. Laya supplies
optional typed decisions; it never transcribes, generates payloads, plans, shell
commands or tools. ToolRegistry remains the authority for risk and confirmation.
No System-2, Qwen, cloud inference or visual computer use is present.

The narrow schema is actionable_command, needs_more_speech,
correction_or_replacement and conditional coarse_family (application, web,
productivity, system, text_file, media, other). Application names, URLs, queries,
note/reminder contents and filenames come only from deterministic parsing.

Known exact commands bypass Laya. Otherwise the manager asks actionability first,
more-speech only when the observation might be incomplete, correction only for
an explicit correction candidate, and family only when deterministic routing
has no intent. A resident native Swift helper serves JSON over local pipes,
using ONNX Runtime CPU and its pinned native tokenizer. There is no Python
runtime server and no reload per command. Cancellation terminates the owned
helper; a later explicit session may warm it again. Failed/missing decisions
preserve deterministic behavior and calibrated abstention.

The old base checkpoint can remain on disk until a replacement passes validation,
but production does not load or evaluate its flat intent/risk schema. The UI
imports a prepared LocalFlow-Laya-v2 package instead of downloading an unspecialized
base model. Build-time historical v1 export/evaluation sources are retained as
evidence and reusable pinned tooling, not as a production model-selection path.

## Training and qualification

Evaluation/LayaV2 contains 2,400 train, 400 calibration and 600 held-out synthetic
English states. Each split balances more-speech 50/50. Scenario families, their
prefixes, grammar templates and target/topic entities stay in their assigned
split. Shared operation semantics remain by design; these data do not prove
natural microphone generalization. The 240-row human-review.csv is **pending**.
No human approval is claimed.

The 321,908,998-parameter multilingual 322M backbone is pinned at
`e4e9ddf21a7b1903b7acffd8814ad4307bf63a67`; base weights SHA-256
`9d628fd971b700382ac6f65920a86f149777b2e748e0c955fb3b19695aa8f204`.
Current upstream revision inspection and file hashes are in
Evaluation/CoreLock/upstream-backbone.json. The local MPS pipeline uses seed
722041, supervised CE, full-model FP32 training and saved FP16 weights. FP16
inference arithmetic parity, native FP32 export parity and latency are measured
separately. All actual results and remaining gaps belong in
CORE_ARCHITECTURE_REPORT.md, not inferred from parameter size.

Dataset hashes, configuration, executed source, per-update training metrics,
checkpoint hash, calibration temperatures and held-out predictions are preserved.
Calibration fits only its split. Held-out labels never fit training or thresholds.
Benchmarks report 1/2/3-question and family passes, including separate sequential
calls matching hierarchical runtime behavior. MPS experiment timing is distinct
from native CPU production IPC timing.

## Installation and authority

Menu Local Decisions → Install LocalFlow-Laya-v2, or the Agent Settings import
button, validates the package, copies to a staging directory, validates again,
and atomically replaces only Application Support/LocalFlow/Models/laya-v2. The
previous Models/laya directory is preserved while v2 remains unqualified. A failed
import preserves existing model files. Normal microphone/inference startup
never downloads anything. A prepared package includes native helper, graph and
external weights, unchanged tokenizer, question schema, option order, runtime
specification, calibration, parity/validation and provenance. Every file is hashed.

Native parity requires at least 100 decisions and maximum logit delta ≤0.003.
Dataset minimums are 2,000/300/500. Enabled policies require explicit human-review
evidence and calibration/held-out Wilson lower bounds ≥0.95; more-speech also
requires precision, recall and F1 ≥0.9. Synthetic accuracy alone cannot enable
those policies. A parity-validated resident model can expose diagnostic scores
with all decision policies disabled. Readiness is not decision authority.

The helper's independent Package.resolved retains ONNX Runtime and tokenizer
packages. The app has no external speech/package dependencies. Do not remove
those legitimate decision dependencies when auditing speech removal.

## Reproduction

Use the pinned environment and official SDK described by training provenance.
Build/evaluation Python is tooling only. The current source commands are:

```sh
python3 -m unittest discover -s Evaluation/LayaV2 -p 'test_*.py'
python Evaluation/LayaV2/model_pipeline.py train --model /pinned/base --output /new/training --epochs 1 --loss ce
python Evaluation/LayaV2/model_pipeline.py evaluate --model /trained/model --output /evaluation
python Evaluation/LayaV2/analyze.py /evaluation
python Evaluation/LayaV2/fp16_parity.py --model /trained/model --output /fp16-parity.json
python Evaluation/LayaV2/benchmark_heads.py --model /trained/model --output /mps-latency.json
```

prepare_native.py exports with the pinned official exporter, then checks real
native IPC against official PyTorch CPU construction before emitting a hashed
manifest. benchmark_native.py measures that same resident native helper.
Real import/inference tests remain opt-in and use test-owned installations.

The hierarchical manager stops immediately when actionable_command is not accepted. Disabled diagnostic policies therefore run one question, while exact deterministic commands run none. The real native v2 test verifies no more/correction/family follow-up occurs after that abstention.
