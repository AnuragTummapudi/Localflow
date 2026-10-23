# LocalFlow reality gate experiments

**NOT READY FOR SYSTEM-2 PLANNER.** See [the factual report](../../REALITY_GATE_REPORT.md).
This directory contains experimental data, source, provenance and measured results.
It is not an app model install. Production checkpoint, question schema, calibration
and disabled semantic gates remain unchanged.

## Frozen data and measurements

`corpus.tsv` is explicit assistant-authored, manually reviewed synthetic speech.
`build_corpus.py` freezes 234 train, 40 calibration and 72 held-out utterances,
with separate family manifests and SHA256 hashes. Independent human sign-off is
pending. Do not regenerate or change these splits while comparing saved results.
The held-out data is neither trained on nor used to fit temperatures/thresholds.
`test_pipeline.py` checks split isolation, hashes, calibration rejection, precision
statistics and partial gradient accumulation. Run it from the repository root:

```sh
python3 -m unittest discover -s Evaluation/RealityGate -p 'test_*.py' -v
bash -n Evaluation/RealityGate/run_gpu.sh
```

Each `results/*/report.json` includes the same five categorical questions and
raw plus calibrated held-out metrics. Its sibling `predictions.json` contains
logits from real inference. Gates fitted on calibration remain separate from
held-out outcome measurements. None enables an app safety gate.

Latency measures five questions batched per utterance, a single resident load
across 112 calibration/test utterances, synchronized GPU execution and 111 warm
samples. Cold load and first prediction are separate. These differ from the
historical native three-question benchmark. Public runs were not fully isolated
from builds; report comparisons as indicative. RSS is process high-water RSS;
MPS driver/allocation figures overlap unified memory and must not be added to it.

## Reproduce the completed local training

The actual full two-epoch MPS run completed: 74 updates, 2,340 micro-steps. The
retained checkpoint is at `.build/reality-gate/localflow-laya-v1/` in the repository.
`training/` preserves the run configuration, seeds, hashes, metrics, calibration
and exact executed source copies. Those copies are provenance, not entry points:
their relocated paths do not point to the frozen corpus. The current entry point
also corrects Linux RSS units for future CUDA runs; training arithmetic is unchanged.

The verified local environment used the existing Python virtual environment with
`laya==0.3.26` and conversion tools in an isolated SDK directory. From repository
root, use separate output paths to preserve the recorded experiment:

```sh
PYTHONPATH="$PWD/.build/reality-gate/sdk" .build/laya-research/venv/bin/python \
  Evaluation/RealityGate/model_pipeline.py train \
  --model .build/reality-gate/models/multilingual \
  --output .build/reality-gate/reproduction-v1 --device mps --epochs 2 --grad-accum 32
PYTHONPATH="$PWD/.build/reality-gate/sdk" .build/laya-research/venv/bin/python \
  Evaluation/RealityGate/model_pipeline.py evaluate \
  --model .build/reality-gate/reproduction-v1 \
  --output .build/reality-gate/reproduction-results --device mps --dtype float32
```

A full CUDA entry point is `run_gpu.sh`, using the pinned base revision and exact
`requirements-training.txt`. It requires an already provisioned compatible CUDA
Python environment, runs tests, downloads only official pinned public assets,
trains and evaluates locally in that environment. No external GPU job was run;
CUDA execution and compatibility remain unverified. No uploads, credentials,
automatic installs, publication or paid service requests are included.

## Inference experiments and parity

`inference_candidates.py` runs ONNX CPU or requested CoreML EP, direct Core ML
conversion, and isolated per-tensor dynamic INT8 conversion. Failed conversions
are recorded in `conversion-status.json`, with no invented performance results.
INT8 was rejected: 75/560 answer changes including 11 demotions relative to FP32 consequential predictions (three had consequential
held-out gold labels). FP16 MPS
had zero answer changes on the frozen 560 calibration/test decisions for both
the multilingual base and trained checkpoint; quality and latency still failed.
Direct Core ML's future successful branch measures loading its saved artifact,
not the source PyTorch load. That branch has not run successfully on this toolchain.

## Native reality workflow

Use [GUIDED_VALIDATION.md](GUIDED_VALIDATION.md) in the actual unsigned Debug app.
Diagnostic payloads are opt-in, bounded, in memory only. The saved `live-results.json`
records the failed UI-control boundary and all 16 unverified live steps.
`asr-before.json`, `asr-after.json` and `asr-final.json` use real streaming and batch
ASR on paced synthetic audio with **mocked** native tools. `payload-final.json`
traces source transcripts through exact arguments. `audio-qc.json` includes fixture
hashes and waveform checks; it cannot prove microphone or phonological correctness.
