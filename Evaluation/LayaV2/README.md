# LocalFlow-Laya-v2 evaluation

This is an English synthetic utterance-state corpus and a local, non-generative
decision experiment. The pinned multilingual backbone does not establish
multilingual voice quality. No person has reviewed or approved this corpus.
`human-review.csv` contains 240 examples with blank reviewer, approval and
correction columns.

The four outputs are `actionable_command`, `needs_more_speech`, `correction_or_replacement`, and
conditional `coarse_family`. There are no risk, tool, application, URL, query,
title, body, text, workflow or other generated execution values. Native parsing
and tool metadata remain authoritative. Unsupported direct requests can be
actionable and incomplete simultaneously; actionability is not an execution grant.

## Frozen corpus

`split-manifest.json` records the generator hash, split hashes, label counts,
diagnostic slices, prefix word lengths, removed duplicates and limitations.
There are 2,400 training states, 400 calibration states and 600 held-out states.
Each split is exactly balanced on needs-more-speech. Complete commands may be
streaming states; incomplete commands may be final states. The final flag cannot
replace the more-speech decision.

Scenario families and their prefix states stay in one split. Grammar templates
and scenario entities are assigned before expansion; exact and normalized
duplicates are removed before freezing. Short application prefixes and compound
prefix chains receive extra training sampling weight. Missing note, reminder,
query, correction and conjunction slices remain explicitly represented. Arbitrary
truncations of free text are not labeled incomplete: a short body/query may
already be exactly what the user intended.

Operation semantics remain shared across splits. These synthetic families do not
prove generalization to unscripted microphone speech or unseen kinds of commands.
Human review is still needed for semantic labels and natural language coverage.

A generator audit corrected repeated narrative correction labels and truncated app-name
completeness before the final freeze. The interrupted pre-audit run and its
original corpus are retained under `.build/laya-v2/audited-pilot-*`; they are not
the final training checkpoint or quality evidence.

## Training and calibration

`model_pipeline.py` reuses the proven RealityGate loader, official SDK sequence
construction, batching and proper reward implementation. The base is
`convaiinnovations/laya-multilingual` at immutable revision
`e4e9ddf21a7b1903b7acffd8814ad4307bf63a67` (321,908,998 parameters).
Training uses FP32 MPS; measurements use FP16 MPS. No silent CPU fallback occurs.

The [official fine-tuning guide](https://nandhakishorm.github.io/laya/finetune/)
and [official MPS typed-decision recipe](https://github.com/NandhaKishorM/laya/blob/main/notebooks/laya_finetune_typed_decisions_mps.py)
describe soft supervised targets with optional RLCD. Independent, defensible
teacher probabilities are unavailable for this corpus. This experiment therefore
uses one-hot supervised CE, with the official encoder/head learning rates,
gradient accumulation/checkpointing, clipping and separate temperature fitting.
The optional RLCD implementation is retained for a future controlled comparison;
no soft-target or RLCD improvement is claimed from this supervised run.

Executed source, base revision/hashes, dependency versions, seeds, dataset/split
hashes, optimizer/scheduler configuration, per-update losses and final checkpoint
hash are written to the test-owned experiment directory. No held-out result is
used for training, temperature fitting or threshold selection. Thresholds for
90%, 95%, 97% and 99% precision targets are selected from calibration only, with
at least 20 calibration acceptances; held-out coverage and Wilson intervals are
reported even when targets fail.

Joint routing measures actionable=yes, more=no, correction=no, using the minimum
calibrated desired-label probability. It measures decision eligibility, not
actual tool completion. The deterministic bypass population is not filtered
from this synthetic corpus and therefore these figures are not production
ambiguity-only precision estimates.

## Local reproduction

Run from the repository with the existing pinned research environment:

```sh
python3 -m unittest discover -s Evaluation/LayaV2 -p 'test_*.py'
PYTHONPATH="$PWD/.build/reality-gate/sdk" .build/laya-research/venv/bin/python \
  Evaluation/LayaV2/model_pipeline.py train \
  --model .build/reality-gate/models/multilingual --output .build/core-lock/laya-v2 --epochs 1 --loss ce
PYTHONPATH="$PWD/.build/reality-gate/sdk" .build/laya-research/venv/bin/python \
  Evaluation/LayaV2/model_pipeline.py evaluate --model .build/core-lock/laya-v2 --output Evaluation/CoreLock/LayaV2
python3 Evaluation/LayaV2/analyze.py Evaluation/CoreLock/LayaV2
PYTHONPATH="$PWD/.build/reality-gate/sdk" .build/laya-research/venv/bin/python \
  Evaluation/LayaV2/benchmark_heads.py --model .build/core-lock/laya-v2 --output Evaluation/CoreLock/LayaV2/latency-heads.json
```

Do not regenerate the corpus during a run. Benchmark latency after other
training/inference jobs finish. Only requested questions are tokenized and
evaluated, with one resident model. Measurements include tokenization, tensors,
transfers, synchronized forward execution and logit readback. MPS memory is
sampled after forward calls, not represented as a measured transient peak.

`prepare_native.py` exports the trained checkpoint through the already cached
official ONNX exporter and compares at least 100 native decisions to full
precision CPU PyTorch, including native tokenization. It never installs a model.
An export failure or parity failure cannot emit a validated manifest. Even a
successful package retains disabled policies while human review is pending.
`LOCALFLOW_LAYA_V2_PACKAGE=/absolute/test-owned/package swift test --filter NarrowLayaRuntimeTests`
exercises real requested-head IPC and the unreviewed-data authority gate.

The current schema replaces the earlier ambiguous head with explicit correction_or_replacement. Production asks only necessary heads, retains a resident native helper and never consumes legacy flat intent/risk scores. Install the parity-validated v2 package explicitly; policies stay disabled while human review is pending. See CORE_ARCHITECTURE_REPORT.md for actual completed-run metrics.

Completed run: 2,400 / 400 / 600 states, one epoch, 285 accumulated updates. Held-out actionable accuracy 92.33%, needs-more precision 92.70% / recall 84.67%, correction recall 30.56%, family accuracy 72.51%. The calibration-selected 95% joint routing point achieved only 76.19% held-out precision at 14% coverage. This checkpoint is not production-qualified; all authority policies remain disabled. Native conversion parity and model quality are distinct gates.
