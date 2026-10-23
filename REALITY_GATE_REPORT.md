> Historical evidence from the preceding architecture. Current macOS 26+ speech and decision behavior is documented in STREAMING.md, VOICE_AGENT.md and CORE_ARCHITECTURE_REPORT.md. Removed speech engines described here are not available in the current app.

# LocalFlow reality gate + Laya specialization — factual review

Date: 4 October 2026. Repository: `/Users/anuragtummapudi/Localflow-project/LocalFlow`. Branch: `main`.
Unchanged HEAD: `83290ea1a2797c2df662afa1afbe5822417386b8`.

**Recommendation: NOT READY FOR SYSTEM-2 PLANNER.**

This iteration implemented source-preserving payload handling, a deterministic fast path,
Debug-only guided validation and a reproducible LocalFlow Laya specialization. A real full
MPS training job completed. It did **not** qualify the model or prove daily-use completion.
The exact ASR fixture error rate remains **5/12 (41.67%)**; best measured trained FP16
latency is **343.33 ms p50 / 388.72 ms p95** for five batched decisions. Intent accuracy
is **58.33%**. More-speech recall collapsed to zero. All 16 microphone/native validation
steps remain **UNVERIFIED** after the computer-control service crashed.

[Prior baseline and six-iteration context](/Users/anuragtummapudi/Localflow-project/LocalFlow/VERSION_EVOLUTION_SUMMARY.md) was read
before changes and remains unchanged. Its historical metrics are kept separate from these
new measurements. Documentation was checked against current Swift source.

No production model was replaced, no semantic safety gate was enabled, and no new planner,
Qwen dependency or visual computer-use feature was added. No commit, push, PR, remote change,
deployment or release packaging was performed. All reviewable work remains local.

## 1. Exact ASR payloads: before and after

| Run | Invocations | Wrong exact payloads | Mismatch rate | Duplicates |
| --- | --- | --- | --- | --- |
| Before | 12 | 5 | 41.67% | 0 |
| Early after | 12 | 5 | 41.67% | 0 |
| Final source | 12 | 5 | 41.67% | 0 |

Ten fixed synthetic TTS scenarios produce 12 expected invocations. Real Parakeet EOU streaming
and final batch ASR run on input-rate paced audio; native effects are mocked. The exact
comparator in `Features/CommandMode/AgentBenchmark.swift` is byte-for-byte unchanged from
task start. Wrong executed arguments are not discounted because the XCTest runner passed.
Cancelled proposals are not counted as executed duplicates.

[Final action results](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/asr-final.json), [full layer trace](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/payload-final.json),
[mismatch diagnoses](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/payload-failures.json) and [audio QC](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/audio-qc.json)
contain inspectable synthetic evidence. No user audio/history was used.

| Scenario / slot | Expected payload | Authoritative batch / actual payload | Earliest observed failure | Diagnosis |
| --- | --- | --- | --- | --- |
| 2 · note title | `LocalFlow Benchmark` | `local flow benchmark.` | Streaming STT | Streaming says `local sobenchmark`; batch repairs words but changes join/case/punctuation. Title extraction preserves final source. |
| 3 · note body | `This is my dictated benchmark text.` | `this is my dictated benchmark text.` | Streaming STT | Streaming drops the header and begins lowercase; batch recovers header but leaves body lowercase. |
| 8 · website | `https://example.com` | `https://examblow.com` | Streaming STT | Streaming says `an examlocom`; batch yields a different domain. Parser adds the documented HTTPS default without correcting the domain. |
| 9 · reminder title | `Review LocalFlow benchmark` | `review local flow benchmark.` | Streaming STT | Streaming drops words; batch splits/cases the proper name and adds punctuation. Reminder extraction preserves it. |
| 10 · third compound action | `Swift actors` | `Swift Actors` | Batch final refinement for remaining error | Streaming query is `swift actors`; batch fixes Swift but introduces uppercase Actors. Segmentation/order are correct; query case remains source-aligned. |

Waveform QC found ten finite mono 16-bit PCM fixtures with zero clipped samples. It does not
prove pronunciation, orthographic casing or real microphone quality. Four mismatches are
already visible in streaming output; the remaining Actors capitalization is introduced by
batch refinement. Audio/synthetic pronunciation may contribute. These traces identify the
earliest observable layer, not an unsupported claim about the ultimate acoustic cause.

Every final argument was checked through transcript → segments → header/parser → action →
tool arguments. Vocabulary is absent from these fixtures. No classifier or tool argument
rewrite caused the five retained errors. Their intended spelling/case cannot safely be
reconstructed from this source alone. No hardcoded LocalFlow name, domain correction,
title-casing rule or gold-aware normalization was introduced.

Two avoidable source bugs discovered around this investigation were fixed with regressions:

- Operational commands could pass through ordinary vocabulary shortcut expansion. Explicit
  Voice Agent partial/final text now bypasses it. Legacy single-command capture also resolves
  raw transcripts first and applies vocabulary only after the result is dictation. Ordinary
  dictation vocabulary still works.
- Incremental note parsing could treat the word `write` inside a named title/body as a new
  header. Named title headers are recognized first; a body transition requires an explicit
  `and write` or comma boundary. Empty/incomplete body prefixes remain incomplete.

Regression cases preserve exact source strings, embedded header words, casing/accents,
all five observed bad-ASR payloads, and semantic disagreement without payload synthesis.
These parser/vocabulary fixes do not repair the five transcription failures by guessing.

| Median, milliseconds | Before | Early after | Final source |
| --- | --- | --- | --- |
| partialSTTMilliseconds | 665.531 | 667.157 | 675.743 |
| decisionMilliseconds | 0.278 | 0.220 | 0.204 |
| firstActionMilliseconds | 1797.645 | 1815.893 | 1936.663 |
| completionMilliseconds | 2353.237 | 2370.348 | 2517.799 |

These are per-scenario medians, not microphone/native completion benchmarks. Speech onset is
marked by fixture energy; decision time is deterministic planning; completion is mocked native
completion. Cold model loading is excluded. The final runner took 417.57 seconds including a
384.60-second batch encoder compilation. It logged an ANE compilation failure despite successful
inference/test completion; actual speech-model compute placement was not profiled. This cold-load
and platform-compiler behavior remains a limitation, not a measured fast startup success.

## 2. Current official Laya research and checkpoint identities

| Official candidate | Exact Hub revision | Parameters | Weight SHA256 |
| --- | --- | --- | --- |
| convaiinnovations/laya | `55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851` | 421,293,830 | `891102d372688fc2a094dac56a384bc537b87c63f21f9f3dac0be2b7cbc8d86c` |
| convaiinnovations/laya-multilingual | `e4e9ddf21a7b1903b7acffd8814ad4307bf63a67` | 321,908,998 | `9d628fd971b700382ac6f65920a86f149777b2e748e0c955fb3b19695aa8f204` |
| convaiinnovations/laya-typed-decisions | `1a793eb568e6718f15941d08f85432581df534e3` | 421,293,830 | `4fa56de72383a9d3efa9cfa78955733c81b9fc8067a587ca4beb82c78107a24e` |

SDK: `laya==0.3.26`; wheel SHA256 `edd049719af725712ae1ca0af2b2e8997287d49098ff47686945e26ab23c21f4`.
Official Git source/docs recipe pin: `2e4d9c87e8b1621deb344eac7de5c7258f32f849`.
[Official research and primary-source links](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/RESEARCH.md) covers current English,
multilingual, typed decisions, fine-tuning, browser specialization, Router and Apple MPS support.
The English revision still matches the original production pin; that was verified, not assumed.

The typed checkpoint targets invoice, security, customer-service and trace workflows. It is
not automatically a Mac-control specialization. Current Router supports language/script routing
and resident preload/attach. No second production resident model was added. The current official
MPS RLCD recipe made full local training practical; its compatible model/sequence/reward primitives
were reused. Upstream generative dependencies and publication steps were not copied.

## 3. Frozen LocalFlow decision corpus and provenance

| Split | Utterances | Decision examples | SHA256 |
| --- | --- | --- | --- |
| train | 234 | 1170 | `4a4cef924f2c7925dc93876aa5daeb1d395976de13375ddb3b68945a3cba291c` |
| calibration | 40 | 200 | `825e9f6567aa3d5530ec84ffec3a85e2bd5b68f344a636a63e1b3a8a882bedc7` |
| test | 72 | 360 | `f75dae25cad37c472bd34dc3df8366efb392343994f7059dd4134b6ba44d6a9d` |

Corpus source SHA256: `8c1793759067b775cf49e07e8f3107af0f0782b3c13b6e49cb7634addd988067`.
Split-manifest SHA256: `e8247ce3b8d17ae3afbeadcfca9dcdc1a460dc4ff7945bca3a69b9d669775e14`.
Decision-question source SHA256: `d4bd68e029bc282806f83afddba5ddf242eca127dd21e5e43f74d6d969fbf16a`.

The five non-generative categorical decisions are intent (14 families), more-speech, risk
(safe/reversible/consequential), command-vs-dictation and ambiguity. The utterances cover
incremental prefixes, negation/quotation hard negatives, self-correction, compound commands,
app ambiguity, partial words, repetition, hesitation, near-homophones, article/casing/punctuation
noise, text/file/macro commands and unknown requests. Labels and synthetic provenance are explicit.
URLs, titles, queries and app mentions occur as input context; the model never learns to emit
those values, plans, filenames or shell commands.

Train-only casing/punctuation/filler variants remain within their original family. Calibration
and test are separately authored explicit adversarial cases, not generated training-template
variants. Case-folded exact utterance and family overlap are rejected. Two training families
were excluded for overlap with existing Laya evaluation fixtures. Existing held-out fixtures
were not trained on. Hashes are checked before training/evaluation.

**Review boundary:** assistant-authored and manually assistant-reviewed, with no personal user
information. Independent human review is pending. Family labels and exact-overlap checks cannot
prove complete semantic independence; shared operator/intent vocabulary remains. This is a
small engineering pilot, not population-level safety evidence. Forty calibration utterances
cannot statistically establish 95–99% precision with the chosen two-sided Wilson lower bound,
even with zero errors. The test set has ten more-speech-positive examples.

[Corpus](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/corpus.tsv), [split manifest](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/split-manifest.json),
[reproduction instructions](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/README.md).

## 4. Same-held-out public checkpoint bake-off

| Candidate | Intent | Risk | More accuracy | More precision | More recall | Command/dictation | Ambiguity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| English 421M · MPS FP32 | 45.83% | 41.67% | 75.00% | 21.43% | 30.00% | 76.39% | 55.56% |
| Multilingual 322M · MPS FP32 | 51.39% | 52.78% | 77.78% | 31.25% | 50.00% | 45.83% | 56.94% |
| Typed decisions 421M · MPS FP32 | 44.44% | 40.28% | 86.11% | 50.00% | 10.00% | 62.50% | 76.39% |
| Actual deterministic engine | 30.56% | 48.61% | 94.44% | 75.00% | 90.00% | 37.50% | 72.22% |
| English · ONNX CPU FP32 | 45.83% | 41.67% | 75.00% | 21.43% | 30.00% | 76.39% | 55.56% |
| English · ONNX CPU INT8 (rejected) | 47.22% | 43.06% | 76.39% | 23.08% | 30.00% | 73.61% | 55.56% |
| Multilingual · MPS FP16 | 51.39% | 52.78% | 77.78% | 31.25% | 50.00% | 45.83% | 56.94% |
| LocalFlow-Laya-v1 · MPS FP32 | 58.33% | 63.89% | 86.11% | — | 0.00% | 83.33% | 75.00% |
| LocalFlow-Laya-v1 · MPS FP16 | 58.33% | 63.89% | 86.11% | — | 0.00% | 83.33% | 75.00% |

All columns above use the identical frozen **72 utterances**. Scalar positive temperatures
preserve argmax labels. `—` denotes undefined precision because no positives were predicted.
Every candidate's [raw logits and detailed metrics](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results) is retained.

The deterministic row runs the actual Swift `DeterministicDecisionEngine`, with a fixed synthetic
application catalog and isolated settings. Only focus/quit label names are mapped to equivalent
new vocabulary. Its existing narrower taxonomy was not patched to improve text/file/workflow
scores; whole-utterance adversarial/compound semantics are also different from successful typed
per-segment execution. This row measures classifier coverage under that boundary, not a claim
that 69.44% of supported native commands execute incorrectly. Unknown requests remain unresolved.
Deterministic confidence is parser evidence, not calibrated probability.

The historical production English benchmark (different 45 held-out examples and three questions)
reported 60% intent, 44.44% risk and 86.67% more-speech accuracy. Those numbers are not mixed with
this new dataset or used to claim a regression/improvement on identical inputs.

## 5. Selective accuracy, coverage and calibration

### Fixed intent confidence threshold 0.5

| Candidate | Accepted / 72 | Coverage | Selective accuracy | Wilson 95% lower bound |
| --- | --- | --- | --- | --- |
| English 421M · MPS FP32 | 45 | 62.50% | 55.56% | 41.18% |
| Multilingual 322M · MPS FP32 | 42 | 58.33% | 59.52% | 44.49% |
| Typed decisions 421M · MPS FP32 | 52 | 72.22% | 55.77% | 42.34% |
| LocalFlow-Laya-v1 · MPS FP32 | 59 | 81.94% | 66.10% | 53.37% |
| Deterministic parser evidence | 64 | 88.89% | 31.25% | 21.23% |

### Fixed intent confidence threshold 0.75

| Candidate | Accepted / 72 | Coverage | Selective accuracy | Wilson 95% lower bound |
| --- | --- | --- | --- | --- |
| English 421M · MPS FP32 | 18 | 25.00% | 83.33% | 60.78% |
| Multilingual 322M · MPS FP32 | 24 | 33.33% | 66.67% | 46.71% |
| Typed decisions 421M · MPS FP32 | 19 | 26.39% | 57.89% | 36.28% |
| LocalFlow-Laya-v1 · MPS FP32 | 51 | 70.83% | 68.63% | 54.97% |
| Deterministic parser evidence | 64 | 88.89% | 31.25% | 21.23% |

### Fixed intent confidence threshold 0.9

| Candidate | Accepted / 72 | Coverage | Selective accuracy | Wilson 95% lower bound |
| --- | --- | --- | --- | --- |
| English 421M · MPS FP32 | 6 | 8.33% | 100.00% | 60.97% |
| Multilingual 322M · MPS FP32 | 11 | 15.28% | 72.73% | 43.44% |
| Typed decisions 421M · MPS FP32 | 2 | 2.78% | 100.00% | 34.24% |
| LocalFlow-Laya-v1 · MPS FP32 | 1 | 1.39% | 100.00% | 20.65% |
| Deterministic parser evidence | 64 | 88.89% | 31.25% | 21.23% |

### Fixed intent confidence threshold 0.95

| Candidate | Accepted / 72 | Coverage | Selective accuracy | Wilson 95% lower bound |
| --- | --- | --- | --- | --- |
| English 421M · MPS FP32 | 4 | 5.56% | 100.00% | 51.01% |
| Multilingual 322M · MPS FP32 | 4 | 5.56% | 50.00% | 15.00% |
| Typed decisions 421M · MPS FP32 | 0 | 0.00% | — | — |
| LocalFlow-Laya-v1 · MPS FP32 | 0 | 0.00% | — | — |
| Deterministic parser evidence | 59 | 81.94% | 28.81% | 18.84% |

### Fixed intent confidence threshold 0.97

| Candidate | Accepted / 72 | Coverage | Selective accuracy | Wilson 95% lower bound |
| --- | --- | --- | --- | --- |
| English 421M · MPS FP32 | 3 | 4.17% | 100.00% | 43.85% |
| Multilingual 322M · MPS FP32 | 3 | 4.17% | 33.33% | 6.15% |
| Typed decisions 421M · MPS FP32 | 0 | 0.00% | — | — |
| LocalFlow-Laya-v1 · MPS FP32 | 0 | 0.00% | — | — |
| Deterministic parser evidence | 59 | 81.94% | 28.81% | 18.84% |

### Fixed intent confidence threshold 0.99

| Candidate | Accepted / 72 | Coverage | Selective accuracy | Wilson 95% lower bound |
| --- | --- | --- | --- | --- |
| English 421M · MPS FP32 | 3 | 4.17% | 100.00% | 43.85% |
| Multilingual 322M · MPS FP32 | 1 | 1.39% | 100.00% | 20.65% |
| Typed decisions 421M · MPS FP32 | 0 | 0.00% | — | — |
| LocalFlow-Laya-v1 · MPS FP32 | 0 | 0.00% | — | — |
| Deterministic parser evidence | 59 | 81.94% | 28.81% | 18.84% |

Fixed thresholds are reported as diagnostics, not selected after observing the test set.
For requested precision targets, the next table selects an empirical gate on calibration only
(minimum five accepted), then measures its held-out outcome. No held-out threshold refit occurs.

| Candidate | Target calibration precision | Chosen threshold | Held-out coverage | Held-out precision | Statistically supported gate coverage |
| --- | --- | --- | --- | --- | --- |
| English 421M · MPS FP32 | 95.00% | — | 0.00% | — | 0.00% |
| English 421M · MPS FP32 | 97.00% | — | 0.00% | — | 0.00% |
| English 421M · MPS FP32 | 99.00% | — | 0.00% | — | 0.00% |
| Multilingual 322M · MPS FP32 | 95.00% | 0.765828 | 33.33% | 66.67% | 0.00% |
| Multilingual 322M · MPS FP32 | 97.00% | 0.765828 | 33.33% | 66.67% | 0.00% |
| Multilingual 322M · MPS FP32 | 99.00% | 0.765828 | 33.33% | 66.67% | 0.00% |
| Typed decisions 421M · MPS FP32 | 95.00% | — | 0.00% | — | 0.00% |
| Typed decisions 421M · MPS FP32 | 97.00% | — | 0.00% | — | 0.00% |
| Typed decisions 421M · MPS FP32 | 99.00% | — | 0.00% | — | 0.00% |
| LocalFlow-Laya-v1 · MPS FP32 | 95.00% | 0.886647 | 15.28% | 81.82% | 0.00% |
| LocalFlow-Laya-v1 · MPS FP32 | 97.00% | 0.886647 | 15.28% | 81.82% | 0.00% |
| LocalFlow-Laya-v1 · MPS FP32 | 99.00% | 0.886647 | 15.28% | 81.82% | 0.00% |

**No statistically supported 95%, 97% or 99% intent gate exists for any candidate in this
calibration pilot; supported coverage is zero, and precision is undefined at zero coverage.**
The v1 empirical gate accepts 8/40 calibration examples, all correct, but its Wilson lower
bound is only 67.56%. On held-out it accepts 11/72 (15.28% coverage), with 9/11 correct
(81.82% precision; lower bound 52.30%). The multilingual empirical gate also fails transfer:
24/72 accepted, only 66.67% precision. These are not 95–99% precision successes.

| Candidate | Intent temperature | Intent raw ECE10 | Intent calibrated ECE10 | Risk calibrated ECE10 | More calibrated ECE10 |
| --- | --- | --- | --- | --- | --- |
| English 421M · MPS FP32 | 1.9055 | 0.3561 | 0.1557 | 0.1695 | 0.0472 |
| Multilingual 322M · MPS FP32 | 1.7378 | 0.2704 | 0.1567 | 0.0672 | 0.0999 |
| Typed decisions 421M · MPS FP32 | 0.6506 | 0.0797 | 0.1751 | 0.1045 | 0.0340 |
| English · ONNX CPU FP32 | 1.9055 | 0.3561 | 0.1557 | 0.1695 | 0.0472 |
| English · ONNX CPU INT8 (rejected) | 1.6853 | 0.3333 | 0.1709 | 0.0991 | 0.0556 |
| Multilingual · MPS FP16 | 1.7378 | 0.2808 | 0.1569 | 0.0672 | 0.0999 |
| LocalFlow-Laya-v1 · MPS FP32 | 5.4117 | 0.3608 | 0.2002 | 0.1082 | 0.0105 |
| LocalFlow-Laya-v1 · MPS FP16 | 5.4117 | 0.3613 | 0.1809 | 0.0999 | 0.0105 |

Calibration fits NLL on the separate 40-example split, using a deterministic log-temperature
search bounded to 0.1–10. Saved reports also include NLL/Brier, raw/calibrated metrics and per-head
threshold tables. Typed-decision calibration worsened held-out intent ECE, demonstrating why
calibration-set improvement alone is insufficient. v1 more-speech ECE is small despite **zero
recall**: it predicts no more-speech positives. Aggregate calibration quality does not prove a
usable stopping/waiting detector. More and ambiguity temperatures reach the upper bound.

| v1 head | Calibration-only temperature | Held-out raw ECE10 | Held-out calibrated ECE10 |
| --- | --- | --- | --- |
| intent | 5.411695 | 0.360831 | 0.200173 |
| risk | 8.709636 | 0.338552 | 0.108166 |
| more_speech | 10.000000 | 0.138889 | 0.010524 |
| command | 8.066157 | 0.166646 | 0.081384 |
| ambiguous | 10.000000 | 0.250000 | 0.100462 |

| Risk classifier | Predicted safe/reversible / 72 | Actually non-consequential precision | Wilson 95% lower bound |
| --- | --- | --- | --- |
| English 421M · MPS FP32 | 40 | 85.00% | 70.93% |
| Multilingual 322M · MPS FP32 | 69 | 78.26% | 67.18% |
| Typed decisions 421M · MPS FP32 | 65 | 81.54% | 70.45% |
| LocalFlow-Laya-v1 · MPS FP32 | 54 | 88.89% | 77.81% |
| Deterministic risk classifier | 70 | 80.00% | 69.18% |

This is classifier-only eligibility (predicted safe/reversible), not actual native auto-execution.
Native tool risk, finality, exact matching and confirmation remain authoritative. No model
achieves statistically supported 99% precision here; no risk gate is enabled.

## 6. LocalFlow-Laya-v1: real training status

**Full configured local MPS training completed**, not merely a smoke job or unrun script.
Base: multilingual 321,908,998-parameter model at revision
`e4e9ddf21a7b1903b7acffd8814ad4307bf63a67`.
Full encoder + decision head, FP32 training, random seed `421322`, micro-batch 1,
32-example accumulated windows, 2 epochs, **74 optimizer updates / 2,340 micro-steps**.
Elapsed: **805.712 seconds (13.43 minutes)**. Peak process RSS:
**2.544 GiB**.

Loss: official RLCD four noisy logit projections plus one-hot cross entropy; noise sigma
0.4→0.1; spherical weight 0.75 and ranked weight 1.0. AdamW encoder LR 2.5e-5 / head LR 1e-4,
weight decay 0.01, cosine decay to 1e-6, gradient norm clipping 1, encoder/head checkpointing.
The model remains non-generative and saves compatible Laya weights/config/tokenizer.
Temperature calibration is separate; inherited option-count calibration was removed.

Retained full weight checkpoint: [model.safetensors](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/localflow-laya-v1/model.safetensors).
SHA256: `66e223580811be6485bf64362320e0f0ecbed05ee6762c0e50089a160c244dac`.
[Training config](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/training-config.json),
[per-update metrics](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/training-metrics.jsonl),
[status](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/training-status.json),
[calibration](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/calibration.json).

A real preliminary 3-update, 6-micro-step full-gradient smoke job completed in 16.50 seconds.
Its weights hash/config/metrics remain recorded; its superseded binary was removed after disk
exhaustion to retain the full trained checkpoint. An initial full job was aborted after finding
an accumulation-window bug: epoch-tail averaging/reset crossed boundaries. Its partial metrics
and config are retained as **aborted**, never called successful. Corrected partial windows are
averaged by their actual size and reset each epoch; a regression covers this. The subsequent
74-update job above completed.

Exact executed training source SHA256: `21b1de70ea04bb600dba146b28c29bb2b7cbff12f6c1ffaaae0e0716b4b91c2b`.
Exact executed metrics source SHA256: `a60b5a9e53f2266a99dd5bd75a97a8bc0ee0190374de7a47fd2807eaf059f883`.
Their immutable source copies match those hashes. Current pipeline additionally fixes Linux
RSS unit reporting for future GPU jobs; this changes measurement units, not training arithmetic.
Source/context/dataset/question/base hashes and dependency versions are retained. Seeded MPS
training is not guaranteed bitwise identical across devices or framework releases.

[CUDA entry point](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/run_gpu.sh) and pinned requirements provide a runnable full GPU
job without uploads, publication or automatic installation. Shell syntax, dataset/calibration
checks and the equivalent full local training path were verified. **No CUDA/free-cloud GPU job
was executed; hardware compatibility, quota and cloud execution remain unverified.**

The trained model improves broad pilot intent/risk accuracy but still overfits and fails waiting,
selective precision, risk precision and latency. It is an experimental checkpoint, not an app
asset or approved production replacement.

## 7. Actual inference alternatives, parity, memory and disk

| Candidate | Cold load ms | First inference ms | Warm p50 ms | Warm p95 ms | Peak RSS GiB | Disk MiB |
| --- | --- | --- | --- | --- | --- | --- |
| English 421M · MPS FP32 | 5802.54 | 3882.37 | 1035.81 | 1266.89 | 1.740 | 806.99 |
| Multilingual 322M · MPS FP32 | 5094.09 | 2439.29 | 444.17 | 562.88 | 1.888 | 646.79 |
| Typed decisions 421M · MPS FP32 | 3906.48 | 1573.81 | 1576.70 | 1874.73 | 1.858 | 807.00 |
| English · ONNX CPU FP32 | 3711.52 | 2812.51 | 2448.06 | 4136.19 | 2.271 | 1610.70 |
| English · ONNX CPU INT8 (rejected) | 1100.03 | 1329.07 | 1381.11 | 1614.85 | 2.299 | 570.93 |
| Multilingual · MPS FP16 | 5129.10 | 3032.46 | 396.24 | 483.91 | 2.540 | 646.79 |
| LocalFlow-Laya-v1 · MPS FP32 | 3056.84 | 1370.08 | 376.90 | 415.64 | 2.541 | 646.79 |
| LocalFlow-Laya-v1 · MPS FP16 | 2976.78 | 385.33 | 343.33 | 388.72 | 2.528 | 646.79 |
| Deterministic Swift | Unmeasured | 5.83 | 0.135 | 7.508 | Unmeasured | 0 |
| ONNX CoreML EP | FAILED | — | — | — | — | — |
| Direct Core ML | FAILED | — | — | — | — | — |

Neural candidates batch five categorical questions per utterance, resident across 112 utterances;
first inference is excluded from 111 warm samples. MPS timings synchronize execution. PyTorch
RSS includes runtime/import/load allocations; it is a high-water mark, not an app-only delta.
ONNX provider profiling proves CPU execution for CPU results. Some public runs overlapped builds;
these are indicative, uncontrolled-machine comparisons. v1 FP32/FP16 runs followed completed
training without another model job, but are still not rigorous repeated thermal/power studies.

ONNX disk means graph + external weights; PyTorch disk means checkpoint directory, including
tokenizer/config/provenance. FP16 inference casts resident weights; it does not halve already
FP16 checkpoint files. These measures do not include model caches or all speech assets.
The historical native three-question English CPU path was 824.21/1047.90 ms and peak resident
1.605 GiB on a different dataset/runtime scope; the new five-question totals are not a directly
matched speedup comparison. The retained production helper already stays resident over IPC;
clear commands now avoid its latency altogether. No reload-per-utterance path was added.

| Candidate | MPS allocated GiB | MPS driver GiB |
| --- | --- | --- |
| English 421M · MPS FP32 | 1.573 | 2.023 |
| Multilingual 322M · MPS FP32 | 1.207 | 2.279 |
| Multilingual · MPS FP16 | 0.601 | 1.020 |
| LocalFlow-Laya-v1 · MPS FP32 | 1.207 | 2.279 |
| LocalFlow-Laya-v1 · MPS FP16 | 0.601 | 1.020 |

MPS figures overlap process/unified memory accounting. Do not sum RSS and GPU figures as
independent physical memory. The Mac has an Apple M4, 10 CPU cores and 16 GiB RAM. Full trained
checkpoint directory is 678,212,710 bytes; weights are 643,835,524 bytes. Disk exhaustion occurred
during experiments; only task-created superseded experiment binaries were removed. Previous
production/research assets and unrelated working-tree changes were preserved.

| Conversion / precision comparison | Decisions | Answer agreement | Changed answers | Max absolute logit drift | Mean drift |
| --- | --- | --- | --- | --- | --- |
| English MPS FP32 vs existing ONNX FP32 | 560 | 100.00% | 0 | 0.000384 | 0.000009 |
| Multilingual MPS FP32 vs FP16 | 560 | 100.00% | 0 | 0.102638 | 0.003299 |
| v1 MPS FP32 vs FP16 | 560 | 100.00% | 0 | 0.330028 | 0.007835 |
| English ONNX FP32 vs INT8 | 560 | 86.61% | 75 | 7.724942 | 0.365688 |

All parity comparisons use 560 calibration/test decisions on varied utterances. Zero argmax
differences in this pilot does not certify unseen-input parity; recalibrated metrics are also
reported per candidate. FP16 MPS reduces measured latency/memory but still misses targets and
is not installed into production.

Per-tensor dynamic INT8 MatMul/Gemm conversion succeeded only after retaining ONNX hardlink
protection with separate clones and regenerating stale intermediate shape annotations. No
operator/weight/source contract was changed as an accuracy shortcut. It changed **75/560
answers (13.39%)**, including **11 demotions relative to FP32 consequential predictions**, so it was rejected despite
smaller disk size and faster CPU timing. The 11 count is relative to the reference model, not
eleven proven consequential gold examples; the parity record separately counts gold-consequential
changes (three consequential-gold demotions, all held-out). [INT8 hashes and disagreements](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/int8-parity.json).

ONNX Runtime CoreML EP was attempted twice (normal and disabled graph rewrites): partition
initialization failed, `axis 2 is not in valid range [-2,1]`. No CPU fallback was relabeled as
Core ML. Direct coremltools 9.0 conversion was attempted three times: unsupported `new_ones`,
then mixed integer/boolean `bitwise_and`, including a boolean-attention wrapper. Torch 2.14.1
is newer than the converter's tested range. No accepted Core ML package or numerical result
exists. The future success branch now times reloading a saved Core ML artifact, rather than
mislabeling PyTorch source-load time. That branch remains unexecuted.

The smaller 322M base was actually evaluated/trained on MPS; a separate 322M ONNX/CoreML/INT8
matrix was not completed. Failures/resource limits are retained explicitly, not filled with
estimated benchmarks. [Conversion status](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/conversion-status.json).

## 8. Native source changes and concurrency/safety review

Clear known commands now follow deterministic parsing directly. Optional Laya evaluates only
ambiguous/confirmation-requiring cases; low-confidence/disabled gates abstain and native
confirmation remains in force. Unknown/incomplete speech creates no invented action or plan.
Ordinary dictation avoids a model decision for every final utterance. Slot extraction remains
source-aligned and deterministic, including when semantic evidence disagrees.

Decision source is explicit: deterministic, Laya, or fallback after model failure/generation
change. State sent to the existing helper remains only relevant utterance/finality/language,
without history, app catalogs, unrelated operational memory or conversational context.

The Debug guided pane retains bounded, opt-in, transient evidence: streaming/final transcript,
parsed segment, exact arguments, decision source/confidence, actual receipt output, verification
and timing. Defaults disable trace collection; close/disable clears evidence. No persistent
conversation memory or payload logging was added.

Concrete ownership/focus safeguards added and tested/source-reviewed:

- Real confirmation preview uses the existing executor's single-use grant and consumes it
  without sending the native lock effect. A stale preview cancels only its own matching grant,
  so it cannot revoke a newer native confirmation.
- Preview preparation has generation guards; closing/disabling cancels its owned task and
  prevents late state publication. Beginning capture cancels stale preview ownership.
- Guided recording freezes its selected step across awaits. Step changes cannot redirect a
  pending start into a different test.
- Appending is gated on the verified test-note receipt; the captured note ID must match. A
  changed selection cancels the append rather than writing into another note.
- Notes focus is restored for recording, Finish and confirmation clicked from Settings.
  The existing non-key island behavior is preserved; real OS focus verification remains pending.
- Action records retain real receipt output rather than treating acceptance as application
  completion. Unsupported earlier clauses still block later dependent actions.

Existing revision guards, cancellation drain-before-reuse, weak callback captures, single-flight
helper inference, model unload/reload ownership and bounded trace storage were checked against
source and exercised by existing/new tests. This is not an Instruments retain-cycle proof or an
exhaustive OS race proof. Live cancellation/focus/model lifecycle under microphone use remains
unverified. No broader architectural rewrite was made.

## 9. Actual Debug live-test results and mocked/real boundaries

An **intermediate** unsigned Xcode Debug executable was launched from the exact build path and
its Settings sidebar showed Agent / Mac Control. Selecting the pane failed in computer-control
infrastructure: `Sky Computer Use native pipe closed before response`. The corresponding
SkyComputerUseService crash was `EXC_BREAKPOINT / SIGTRAP`, with `Array.remove(at:)` in its stack.
The LocalFlow process remained running; this is not evidence of a LocalFlow crash.

Resetting the UI-control session and requesting the then-current Debug bundle still failed
with the same closed pipe. The later legacy capture payload fix was rebuilt after that retry;
the service remains unavailable. **Final exact-build launch is UNVERIFIED**.
No permission changes or real test Notes/Reminders were completed in this iteration.
No native acceptance is counted as verified application completion.

| Step | Live requirement | Actual status |
| --- | --- | --- |
| 1 | microphone permission | UNVERIFIED |
| 2 | Accessibility permission | UNVERIFIED |
| 3 | Automation permission | UNVERIFIED |
| 4 | live streaming transcript | UNVERIFIED |
| 5 | Open Notes | UNVERIFIED |
| 6 | create exact-title note | UNVERIFIED |
| 7 | append exact sentence | UNVERIFIED |
| 8 | open preferred browser | UNVERIFIED |
| 9 | search exact query | UNVERIFIED |
| 10 | open exact URL | UNVERIFIED |
| 11 | create exact reminder | UNVERIFIED |
| 12 | open Photo Booth | UNVERIFIED |
| 13 | multi-command speech | UNVERIFIED |
| 14 | mid-sentence correction | UNVERIFIED |
| 15 | cancel in-flight action | UNVERIFIED |
| 16 | consequential confirmation without effect | UNVERIFIED |

For every unrun step, transcript/slots/source/confidence/tool/arguments/receipt/timings are
null in [live-results.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/live-results.json); they are not borrowed from mock results.
The implemented pane can expose those fields when the real workflow is run. Exact note/body,
URL and reminder gold is explicit, not obtained by parsing the same text under test.

[Guided developer-only workflow](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/GUIDED_VALIDATION.md) covers permission evidence,
exact actions, correction, cancellation and consequential confirmation without effects.
Photo Booth step only launches the app; no photo/video capture is performed.

| Evidence | Actually real | Mocked or missing boundary |
| --- | --- | --- |
| Native Laya opt-in suite | Verified native helper, real ONNX weights, inference, temporary model install/remove/reinstall | OS actions in voice-agent integration mocked; production install unchanged |
| ASR fixture suite | Real streaming/batch model inference on paced PCM; actual transcripts and parser arguments | Synthetic system TTS, no microphone; all native effects mocked |
| Decoder reset | Same real resident streaming adapter used twice; live partials before input close | Fixture audio; no native actions |
| Deterministic corpus export | Actual Swift engine and parser | Fixed synthetic app catalog/settings, no OS tools |
| Confirmation tests | Actual executor single-use challenge/ownership machinery | Native system mock; Debug preview deliberately sends no effect |
| Debug app | Intermediate executable launch/sidebar observed | Final launch and all microphone/native action steps unverified |

A mocked tool returning `.verified` proves the test boundary only; it does not verify Notes,
Safari, Reminders, camera state, page load or a real microphone session.

## 10. Tests, builds and checks actually executed

Final source checks were run consecutively, with no intervening Swift source changes:

```sh
swift test --package-path LocalFlow
swift test --package-path LocalFlow
swift test --package-path LocalFlow
xcodebuild -project LocalFlow/LocalFlow.xcodeproj -scheme LocalFlow   -configuration Debug CODE_SIGNING_ALLOWED=NO build
git diff --check
```

Each final Swift run: **231 tests, 7 skipped, 0 failures** (224 actually passed).
The unsigned Xcode Debug build: **BUILD SUCCEEDED**. `git diff --check`: clean.
No test weakening or comparator normalization was used to obtain these results.

| Run / log | Observed result |
| --- | --- |
| [localflow-existing-calibration-final.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-existing-calibration-final.log) | 5 Python tests; OK |
| [localflow-existing-calibration-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-existing-calibration-tests.log) | 5 Python tests; OK |
| [localflow-reality-asr-after.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-asr-after.log) | Executed 1 test, with 0 failures (0 unexpected) in 28.031 (28.033) seconds |
| [localflow-reality-asr-before.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-asr-before.log) | Executed 1 test, with 0 failures (0 unexpected) in 71.984 (71.986) seconds |
| [localflow-reality-asr-final.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-asr-final.log) | Executed 1 test, with 0 failures (0 unexpected) in 417.566 (417.569) seconds |
| [localflow-reality-baseline-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-baseline-tests.log) | Executed 222 tests, with 6 tests skipped and 0 failures (0 unexpected) in 9.519 (9.546) seconds |
| [localflow-reality-decoder-reset.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-decoder-reset.log) | Executed 1 test, with 0 failures (0 unexpected) in 13.735 (13.736) seconds |
| [localflow-reality-deterministic-repeat.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-deterministic-repeat.log) | Executed 1 test, with 0 failures (0 unexpected) in 0.101 (0.104) seconds |
| [localflow-reality-deterministic.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-deterministic.log) | Executed 1 test, with 0 failures (0 unexpected) in 0.291 (0.298) seconds |
| [localflow-reality-fastpath-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-fastpath-tests.log) | Executed 45 tests, with 0 failures (0 unexpected) in 0.324 (0.332) seconds |
| [localflow-reality-final-build.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-final-build.log) | BUILD SUCCEEDED |
| [localflow-reality-final-tests-1.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-final-tests-1.log) | Executed 231 tests, with 7 tests skipped and 0 failures (0 unexpected) in 10.871 (10.931) seconds |
| [localflow-reality-final-tests-2.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-final-tests-2.log) | Executed 231 tests, with 7 tests skipped and 0 failures (0 unexpected) in 10.856 (10.915) seconds |
| [localflow-reality-final-tests-3.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-final-tests-3.log) | Executed 231 tests, with 7 tests skipped and 0 failures (0 unexpected) in 13.100 (13.170) seconds |
| [localflow-reality-final-v2-build.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-final-v2-build.log) | BUILD SUCCEEDED |
| [localflow-reality-final-v2-tests-1.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-final-v2-tests-1.log) | Executed 231 tests, with 7 tests skipped and 0 failures (0 unexpected) in 9.352 (9.378) seconds |
| [localflow-reality-final-v2-tests-2.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-final-v2-tests-2.log) | Executed 231 tests, with 7 tests skipped and 0 failures (0 unexpected) in 8.303 (8.329) seconds |
| [localflow-reality-final-v2-tests-3.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-final-v2-tests-3.log) | Executed 231 tests, with 7 tests skipped and 0 failures (0 unexpected) in 8.880 (8.905) seconds |
| [localflow-reality-guided-build.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-guided-build.log) | BUILD SUCCEEDED |
| [localflow-reality-guided-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-guided-tests.log) | Executed 52 tests, with 0 failures (0 unexpected) in 0.347 (0.371) seconds |
| [localflow-reality-ownership-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-ownership-tests.log) | Executed 53 tests, with 0 failures (0 unexpected) in 0.300 (0.317) seconds |
| [localflow-reality-payload-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-payload-tests.log) | Executed 45 tests, with 0 failures (0 unexpected) in 0.285 (0.290) seconds |
| [localflow-reality-python-final.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-python-final.log) | 7 Python tests; OK |
| [localflow-reality-python-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-python-tests.log) | 7 Python tests; OK |
| [localflow-reality-quality-gate.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-quality-gate.log) | Quality gate: expected FAIL (exit 1) |
| [localflow-reality-real-laya-repeat.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-real-laya-repeat.log) | Executed 15 tests, with 0 failures (0 unexpected) in 34.593 (34.597) seconds |
| [localflow-reality-real-laya-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-real-laya-tests.log) | Executed 15 tests, with 0 failures (0 unexpected) in 33.946 (33.952) seconds |
| [localflow-reality-receipt-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-receipt-tests.log) | Executed 55 tests, with 0 failures (0 unexpected) in 0.327 (0.346) seconds |
| [localflow-reality-routing-build.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-routing-build.log) | BUILD SUCCEEDED |
| [localflow-reality-routing-full-tests.log](/Users/anuragtummapudi/Localflow-project/LocalFlow/.build/reality-gate/logs/localflow-reality-routing-full-tests.log) | Executed 227 tests, with 7 tests skipped and 0 failures (0 unexpected) in 8.536 (8.562) seconds |

The seven standard-suite skips are explicit opt-in requirements, not hidden failures:

- `LayaRuntimeTests.testRealLayaFeedsIncrementalAgentWithCalibratedAbstention`
- `LayaRuntimeTests.testRealModelInstallRemoveAndReinstallWhenExplicitPackageIsProvided`
- `LayaRuntimeTests.testRealNativeInferenceWhenExplicitTestPackageIsProvided`
- `LayaRuntimeTests.testRealPackageCannotEnableAGateWithoutHeldOutEvidence`
- `ParakeetStreamingIntegrationTests.testDailyBenchmarkWithRealStreamingAudioAndMockNativeTools`
- `ParakeetStreamingIntegrationTests.testRealIncrementalInferenceAndDecoderReset`
- `RealityCorpusTests.testFrozenCorpusAgainstActualDeterministicEngineWhenRequested`

All were executed separately using available test-owned assets. The native Laya suite ran
twice: 15 tests each, zero skips/failures. Real ASR fixture runner ran before/early-after/final,
with five exact payload mismatches each. Real decoder reset test ran two inferences through
the same cached adapter. Actual deterministic corpus export ran twice; it measures outputs,
not a hidden assertion that accuracy is sufficient. New pipeline tests (7) and existing
calibration tests (5) passed repeatedly. GPU shell syntax and Python compile checks passed.

Intermediate focused suites and Debug builds are in the log inventory. Compilation/type errors
during implementation were corrected before the final checks. FluidAudio's unhandled
`benchmark.md` resource warning and absent AppIntents extraction warning remain non-fatal.
The final real-ASR ANE compiler warning is separately disclosed above.

The measured quality checker deliberately returns **exit 1 / FAIL**, with seven failed targets:
exact ASR slots, supported intent precision/coverage, more-speech precision, risk precision,
preferred p50, preferred p95, and complete real microphone/native sequence. The fastest trained
FP16 candidate and final ASR result feed this check. It is not presented as a passing benchmark.

[Test log hashes/inventory](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/test-runs.json),
[quality-gate result](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/quality-gate.json),
[source/dependency boundary checks](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/verification-record.json).
Raw logs remain local under `.build/reality-gate/logs/` rather than becoming release artifacts.

## 11. Remaining failures and engineering recommendation

**NOT READY FOR SYSTEM-2 PLANNER.**

1. Five exact ASR payload mismatches remain; four are visible during streaming and the remaining
   query capitalization error appears in batch refinement. They cannot safely be guessed away.
2. The LocalFlow-Laya-v1 pilot reaches only 58.33% broad held-out intent accuracy. Its empirical
   selective gate fails held-out precision, and no statistically supported high-precision gate exists.
3. More-speech recall is zero; 86.11% aggregate accuracy is dominated by negatives and is insufficient.
4. Risk classifier precision is below 99%; native confirmation/risk remain necessary and unchanged.
5. Best measured five-question warm latency is 343.33/388.72 ms, above preferred 200/300 ms targets.
6. CoreML EP and direct conversion fail on this export/toolchain. INT8 answer/risk drift is unacceptable.
7. Full MPS training ran, but independent human corpus review and larger calibration evidence are pending;
   CUDA execution was not run. Held-out data is now an evaluation record and must remain held out.
8. The final app's real microphone → exact action → native readback sequence is unverified because
   UI infrastructure failed. Cancellation/focus/permission behavior cannot be certified by mocks.
9. Real ASR final startup incurred lengthy compilation and an ANE compiler warning. Its fallback/compute
   placement and repeat cold startup behavior were not proven for daily-use launch.

Keep deterministic known commands on the fast path. Keep Laya optional for ambiguity with
production semantic gates disabled, until a fresh independent validation set supports quality,
safety and live completion. Do not promote the trained checkpoint merely because training completed.

## 12. Local working tree and exact file inventory

At task start: 22 tracked modifications and
58 untracked files already represented previous iterations.
Current: 23 tracked modifications and 128
untracked files. HEAD and branch are unchanged; index is empty. The Git diff against HEAD therefore
includes prior work as well as this iteration. No unrelated file was discarded.

FluidAudio remains `0.15.5`, checkout revision `19600a485baa4998812e4654b70d2bab8f2c9949`, clean.
All three dependency lockfiles and Xcode project file match task-start hashes. Original benchmark
comparator, native parser, model question/stability assets and version-evolution report are unchanged.
A final source audit corrected the legacy capture vocabulary boundary; the final-v2 three test
logs and build supersede the earlier three final logs for the application source. ASR fixture
results exercise unchanged library/Voice Agent paths, not that legacy App-only capture branch.

The following paths changed **during this iteration**, determined by task-start vs current hashes.
Paths are relative to the repository above; `Evaluation/RealityGate/changed-files.json` contains before/after hashes.
New model/cache/log binaries are deliberately outside Git under `.build/`, separately linked above.
The inventory JSON excludes its own hash to avoid a self-reference.

| Iteration delta | Path |
| --- | --- |
| modified | [App/DictationCoordinator.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/App/DictationCoordinator.swift) |
| modified | [App/SettingsRootView.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/App/SettingsRootView.swift) |
| modified | [Shared/VocabularyStore.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Shared/VocabularyStore.swift) |
| modified | [Core/ModelManager/DecisionModelManager.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Core/ModelManager/DecisionModelManager.swift) |
| modified | [DECISIONS.md](/Users/anuragtummapudi/Localflow-project/LocalFlow/DECISIONS.md) |
| added | [Evaluation/RealityGate/GUIDED_VALIDATION.md](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/GUIDED_VALIDATION.md) |
| added | [Evaluation/RealityGate/README.md](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/README.md) |
| added | [Evaluation/RealityGate/RESEARCH.md](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/RESEARCH.md) |
| added | [Evaluation/RealityGate/asr-after.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/asr-after.json) |
| added | [Evaluation/RealityGate/asr-before.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/asr-before.json) |
| added | [Evaluation/RealityGate/asr-final.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/asr-final.json) |
| added | [Evaluation/RealityGate/asr-summary.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/asr-summary.json) |
| added | [Evaluation/RealityGate/audio-qc.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/audio-qc.json) |
| added | [Evaluation/RealityGate/build_corpus.py](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/build_corpus.py) |
| added | [Evaluation/RealityGate/calibration.jsonl](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/calibration.jsonl) |
| added | [Evaluation/RealityGate/check_quality.py](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/check_quality.py) |
| added | [Evaluation/RealityGate/conversion-status.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/conversion-status.json) |
| added | [Evaluation/RealityGate/corpus.tsv](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/corpus.tsv) |
| added | [Evaluation/RealityGate/decisions.py](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/decisions.py) |
| added | [Evaluation/RealityGate/deterministic-predictions.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/deterministic-predictions.json) |
| added | [Evaluation/RealityGate/deterministic-report.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/deterministic-report.json) |
| added | [Evaluation/RealityGate/fetch_checkpoints.py](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/fetch_checkpoints.py) |
| added | [Evaluation/RealityGate/fp16-parity.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/fp16-parity.json) |
| added | [Evaluation/RealityGate/inference_candidates.py](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/inference_candidates.py) |
| added | [Evaluation/RealityGate/int8-parity.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/int8-parity.json) |
| added | [Evaluation/RealityGate/live-results.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/live-results.json) |
| added | [Evaluation/RealityGate/metrics.py](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/metrics.py) |
| added | [Evaluation/RealityGate/model_pipeline.py](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/model_pipeline.py) |
| added | [Evaluation/RealityGate/onnx-parity.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/onnx-parity.json) |
| added | [Evaluation/RealityGate/payload-failures.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/payload-failures.json) |
| added | [Evaluation/RealityGate/payload-final.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/payload-final.json) |
| added | [Evaluation/RealityGate/public-provenance.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/public-provenance.json) |
| added | [Evaluation/RealityGate/quality-gate.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/quality-gate.json) |
| added | [Evaluation/RealityGate/requirements-training.txt](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/requirements-training.txt) |
| added | [Evaluation/RealityGate/results/english-mps-fp32/predictions.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/english-mps-fp32/predictions.json) |
| added | [Evaluation/RealityGate/results/english-mps-fp32/report.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/english-mps-fp32/report.json) |
| added | [Evaluation/RealityGate/results/english-onnx-cpu/predictions.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/english-onnx-cpu/predictions.json) |
| added | [Evaluation/RealityGate/results/english-onnx-cpu/report.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/english-onnx-cpu/report.json) |
| added | [Evaluation/RealityGate/results/english-onnx-int8/predictions.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/english-onnx-int8/predictions.json) |
| added | [Evaluation/RealityGate/results/english-onnx-int8/report.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/english-onnx-int8/report.json) |
| added | [Evaluation/RealityGate/results/localflow-laya-v1-mps-fp16/predictions.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/localflow-laya-v1-mps-fp16/predictions.json) |
| added | [Evaluation/RealityGate/results/localflow-laya-v1-mps-fp16/report.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/localflow-laya-v1-mps-fp16/report.json) |
| added | [Evaluation/RealityGate/results/localflow-laya-v1-mps-fp32/predictions.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/localflow-laya-v1-mps-fp32/predictions.json) |
| added | [Evaluation/RealityGate/results/localflow-laya-v1-mps-fp32/report.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/localflow-laya-v1-mps-fp32/report.json) |
| added | [Evaluation/RealityGate/results/multilingual-assets.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/multilingual-assets.json) |
| added | [Evaluation/RealityGate/results/multilingual-mps-fp16/predictions.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/multilingual-mps-fp16/predictions.json) |
| added | [Evaluation/RealityGate/results/multilingual-mps-fp16/report.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/multilingual-mps-fp16/report.json) |
| added | [Evaluation/RealityGate/results/multilingual-mps-fp32/predictions.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/multilingual-mps-fp32/predictions.json) |
| added | [Evaluation/RealityGate/results/multilingual-mps-fp32/report.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/multilingual-mps-fp32/report.json) |
| added | [Evaluation/RealityGate/results/typed-assets.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/typed-assets.json) |
| added | [Evaluation/RealityGate/results/typed-mps-fp32/predictions.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/typed-mps-fp32/predictions.json) |
| added | [Evaluation/RealityGate/results/typed-mps-fp32/report.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/results/typed-mps-fp32/report.json) |
| added | [Evaluation/RealityGate/run_gpu.sh](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/run_gpu.sh) |
| added | [Evaluation/RealityGate/split-manifest.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/split-manifest.json) |
| added | [Evaluation/RealityGate/test-runs.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/test-runs.json) |
| added | [Evaluation/RealityGate/test.jsonl](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/test.jsonl) |
| added | [Evaluation/RealityGate/test_pipeline.py](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/test_pipeline.py) |
| added | [Evaluation/RealityGate/train.jsonl](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/train.jsonl) |
| added | [Evaluation/RealityGate/trained-fp16-parity.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/trained-fp16-parity.json) |
| added | [Evaluation/RealityGate/training/aborted-first-training-config.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/aborted-first-training-config.json) |
| added | [Evaluation/RealityGate/training/aborted-first-training-metrics.jsonl](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/aborted-first-training-metrics.jsonl) |
| added | [Evaluation/RealityGate/training/calibration.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/calibration.json) |
| added | [Evaluation/RealityGate/training/executed-metrics-source.py](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/executed-metrics-source.py) |
| added | [Evaluation/RealityGate/training/executed-training-source.py](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/executed-training-source.py) |
| added | [Evaluation/RealityGate/training/smoke-training-config.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/smoke-training-config.json) |
| added | [Evaluation/RealityGate/training/smoke-training-metrics.jsonl](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/smoke-training-metrics.jsonl) |
| added | [Evaluation/RealityGate/training/smoke-training-status.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/smoke-training-status.json) |
| added | [Evaluation/RealityGate/training/training-config.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/training-config.json) |
| added | [Evaluation/RealityGate/training/training-metrics.jsonl](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/training-metrics.jsonl) |
| added | [Evaluation/RealityGate/training/training-status.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/training/training-status.json) |
| added | [Evaluation/RealityGate/verification-record.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/verification-record.json) |
| modified | [Features/CommandMode/IncrementalSpeech.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Features/CommandMode/IncrementalSpeech.swift) |
| modified | [Features/CommandMode/NativeTools.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Features/CommandMode/NativeTools.swift) |
| modified | [Features/CommandMode/VoiceAgentCoordinator.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Features/CommandMode/VoiceAgentCoordinator.swift) |
| added | [REALITY_GATE_REPORT.md](/Users/anuragtummapudi/Localflow-project/LocalFlow/REALITY_GATE_REPORT.md) |
| modified | [Tests/FeaturesTests/NativeToolTests.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Tests/FeaturesTests/NativeToolTests.swift) |
| added | [Tests/FeaturesTests/PayloadRealityTests.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Tests/FeaturesTests/PayloadRealityTests.swift) |
| added | [Tests/FeaturesTests/RealityCorpusTests.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Tests/FeaturesTests/RealityCorpusTests.swift) |
| modified | [Tests/FeaturesTests/VoiceAgentTests.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Tests/FeaturesTests/VoiceAgentTests.swift) |
| modified | [Tests/SharedTests/LayaRuntimeTests.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Tests/SharedTests/LayaRuntimeTests.swift) |
| modified | [Tests/SharedTests/ParakeetStreamingIntegrationTests.swift](/Users/anuragtummapudi/Localflow-project/LocalFlow/Tests/SharedTests/ParakeetStreamingIntegrationTests.swift) |
| modified | [VOICE_AGENT.md](/Users/anuragtummapudi/Localflow-project/LocalFlow/VOICE_AGENT.md) |
| added | [Evaluation/RealityGate/changed-files.json](/Users/anuragtummapudi/Localflow-project/LocalFlow/Evaluation/RealityGate/changed-files.json) |

### Entire current Git working-tree inventory (including previous iterations)

```text
 M .gitignore
 M App/AppServices.swift
 M App/CommandConfirmationView.swift
 M App/DictationCoordinator.swift
 M App/Info.plist
 M App/LocalFlow.entitlements
 M App/MenuBarController.swift
 M App/OverlayWindowController.swift
 M App/SettingsRootView.swift
 M App/SettingsViewModel.swift
 M App/WaveformOverlayView.swift
 M Core/AudioCapture/AudioCaptureSession.swift
 M Core/HotkeyManager/HotkeyManager.swift
 M Core/ModelManager/ModelManager.swift
 M Engines/TranscriptionRouter.swift
 M Features/CommandMode/CommandMode.swift
 M Features/CommandMode/SpotifyPlaybackController.swift
 M Package.swift
 M Shared/VocabularyStore.swift
 M Tests/FeaturesTests/FeaturesTests.swift
 M Tests/FeaturesTests/SmartFormattingTests.swift
 M Tests/FeaturesTests/SpeechCleanupTests.swift
 M Tests/SharedTests/SharedTests.swift
?? AGENTS.md
?? BASELINE.md
?? Core/ModelManager/DecisionModelManager.swift
?? Core/ModelManager/Resources/DecisionPreparation/Laya/evaluate.py
?? Core/ModelManager/Resources/DecisionPreparation/Laya/utterances.json
?? Core/ModelManager/Resources/DecisionPreparation/LayaHelper/Package.resolved
?? Core/ModelManager/Resources/DecisionPreparation/LayaHelper/Package.swift
?? Core/ModelManager/Resources/DecisionPreparation/LayaHelper/Sources/LayaHelper/LocalLaya.swift
?? Core/ModelManager/Resources/DecisionPreparation/laya-questions.json
?? Core/ModelManager/Resources/DecisionPreparation/prepare-laya.py
?? Core/ModelManager/Resources/DecisionPreparation/prepare-laya.sh
?? DECISIONS.md
?? Engines/ParakeetEngine/ParakeetStreamingEngine.swift
?? Engines/StreamingSTTEngine.swift
?? Engines/StreamingTranscriptionRouter.swift
?? Evaluation/Agent/VALIDATION.md
?? Evaluation/Agent/refined-results.json
?? Evaluation/Agent/scripted-results.json
?? Evaluation/Agent/streaming-results.json
?? Evaluation/Agent/summary.json
?? Evaluation/Laya/evaluate.py
?? Evaluation/Laya/test_calibration.py
?? Evaluation/Laya/validated-baseline.json
?? Evaluation/RealityGate/GUIDED_VALIDATION.md
?? Evaluation/RealityGate/README.md
?? Evaluation/RealityGate/RESEARCH.md
?? Evaluation/RealityGate/asr-after.json
?? Evaluation/RealityGate/asr-before.json
?? Evaluation/RealityGate/asr-final.json
?? Evaluation/RealityGate/asr-summary.json
?? Evaluation/RealityGate/audio-qc.json
?? Evaluation/RealityGate/build_corpus.py
?? Evaluation/RealityGate/calibration.jsonl
?? Evaluation/RealityGate/changed-files.json
?? Evaluation/RealityGate/check_quality.py
?? Evaluation/RealityGate/conversion-status.json
?? Evaluation/RealityGate/corpus.tsv
?? Evaluation/RealityGate/decisions.py
?? Evaluation/RealityGate/deterministic-predictions.json
?? Evaluation/RealityGate/deterministic-report.json
?? Evaluation/RealityGate/fetch_checkpoints.py
?? Evaluation/RealityGate/fp16-parity.json
?? Evaluation/RealityGate/inference_candidates.py
?? Evaluation/RealityGate/int8-parity.json
?? Evaluation/RealityGate/live-results.json
?? Evaluation/RealityGate/metrics.py
?? Evaluation/RealityGate/model_pipeline.py
?? Evaluation/RealityGate/onnx-parity.json
?? Evaluation/RealityGate/payload-failures.json
?? Evaluation/RealityGate/payload-final.json
?? Evaluation/RealityGate/public-provenance.json
?? Evaluation/RealityGate/quality-gate.json
?? Evaluation/RealityGate/requirements-training.txt
?? Evaluation/RealityGate/results/english-mps-fp32/predictions.json
?? Evaluation/RealityGate/results/english-mps-fp32/report.json
?? Evaluation/RealityGate/results/english-onnx-cpu/predictions.json
?? Evaluation/RealityGate/results/english-onnx-cpu/report.json
?? Evaluation/RealityGate/results/english-onnx-int8/predictions.json
?? Evaluation/RealityGate/results/english-onnx-int8/report.json
?? Evaluation/RealityGate/results/localflow-laya-v1-mps-fp16/predictions.json
?? Evaluation/RealityGate/results/localflow-laya-v1-mps-fp16/report.json
?? Evaluation/RealityGate/results/localflow-laya-v1-mps-fp32/predictions.json
?? Evaluation/RealityGate/results/localflow-laya-v1-mps-fp32/report.json
?? Evaluation/RealityGate/results/multilingual-assets.json
?? Evaluation/RealityGate/results/multilingual-mps-fp16/predictions.json
?? Evaluation/RealityGate/results/multilingual-mps-fp16/report.json
?? Evaluation/RealityGate/results/multilingual-mps-fp32/predictions.json
?? Evaluation/RealityGate/results/multilingual-mps-fp32/report.json
?? Evaluation/RealityGate/results/typed-assets.json
?? Evaluation/RealityGate/results/typed-mps-fp32/predictions.json
?? Evaluation/RealityGate/results/typed-mps-fp32/report.json
?? Evaluation/RealityGate/run_gpu.sh
?? Evaluation/RealityGate/split-manifest.json
?? Evaluation/RealityGate/test-runs.json
?? Evaluation/RealityGate/test.jsonl
?? Evaluation/RealityGate/test_pipeline.py
?? Evaluation/RealityGate/train.jsonl
?? Evaluation/RealityGate/trained-fp16-parity.json
?? Evaluation/RealityGate/training/aborted-first-training-config.json
?? Evaluation/RealityGate/training/aborted-first-training-metrics.jsonl
?? Evaluation/RealityGate/training/calibration.json
?? Evaluation/RealityGate/training/executed-metrics-source.py
?? Evaluation/RealityGate/training/executed-training-source.py
?? Evaluation/RealityGate/training/smoke-training-config.json
?? Evaluation/RealityGate/training/smoke-training-metrics.jsonl
?? Evaluation/RealityGate/training/smoke-training-status.json
?? Evaluation/RealityGate/training/training-config.json
?? Evaluation/RealityGate/training/training-metrics.jsonl
?? Evaluation/RealityGate/training/training-status.json
?? Evaluation/RealityGate/verification-record.json
?? Features/CommandMode/AgentBenchmark.swift
?? Features/CommandMode/DecisionEngine.swift
?? Features/CommandMode/IncrementalSpeech.swift
?? Features/CommandMode/LayaDecisionEngine.swift
?? Features/CommandMode/MacNativeToolSystem.swift
?? Features/CommandMode/NativeCommandParser.swift
?? Features/CommandMode/NativeTools.swift
?? Features/CommandMode/NativeUndoGuards.swift
?? Features/CommandMode/Resources/laya-questions.json
?? Features/CommandMode/Resources/voice-agent-stability.json
?? Features/CommandMode/SpotifyTransportPolicy.swift
?? Features/CommandMode/VoiceAgentCoordinator.swift
?? NATIVE_TOOLS.md
?? OPERATIONAL_MEMORY.md
?? OVERLAY.md
?? REALITY_GATE_REPORT.md
?? Runtime/README.md
?? STREAMING.md
?? Scripts/prepare-laya.sh
?? Shared/AgentMemoryStore.swift
?? Shared/OverlayState.swift
?? Shared/StreamingSpeech.swift
?? Tests/FeaturesTests/AgentOperationalTests.swift
?? Tests/FeaturesTests/DecisionEngineTests.swift
?? Tests/FeaturesTests/LocalSettingsTestCase.swift
?? Tests/FeaturesTests/NativeToolTests.swift
?? Tests/FeaturesTests/PayloadRealityTests.swift
?? Tests/FeaturesTests/RealityCorpusTests.swift
?? Tests/FeaturesTests/VoiceAgentTests.swift
?? Tests/SharedTests/AgentMemoryTests.swift
?? Tests/SharedTests/BatchOwnershipTests.swift
?? Tests/SharedTests/CascadingSTTEngineTests.swift
?? Tests/SharedTests/LayaRuntimeTests.swift
?? Tests/SharedTests/OverlayStateTests.swift
?? Tests/SharedTests/ParakeetStreamingIntegrationTests.swift
?? Tests/SharedTests/StreamingTranscriptionTests.swift
?? VERSION_EVOLUTION_SUMMARY.md
?? VOICE_AGENT.md
```

### Tracked diff against unchanged HEAD (prior work included)

```text
 .gitignore                                         |   4 +
 App/AppServices.swift                              |  10 +-
 App/CommandConfirmationView.swift                  |   1 +
 App/DictationCoordinator.swift                     | 502 +++++++++++++++++--
 App/Info.plist                                     |   4 +-
 App/LocalFlow.entitlements                         |   2 +
 App/MenuBarController.swift                        |  85 +++-
 App/OverlayWindowController.swift                  | 320 ++++++------
 App/SettingsRootView.swift                         | 432 +++++++++++++++++
 App/SettingsViewModel.swift                        |   8 +-
 App/WaveformOverlayView.swift                      | 536 +++++++--------------
 Core/AudioCapture/AudioCaptureSession.swift        |  86 +++-
 Core/HotkeyManager/HotkeyManager.swift             |  14 +
 Core/ModelManager/ModelManager.swift               |  59 +++
 Engines/TranscriptionRouter.swift                  |  22 +-
 Features/CommandMode/CommandMode.swift             | 209 +++++---
 .../CommandMode/SpotifyPlaybackController.swift    |   9 +-
 Package.swift                                      |   6 +-
 Shared/VocabularyStore.swift                       |   5 +-
 Tests/FeaturesTests/FeaturesTests.swift            |   4 +-
 Tests/FeaturesTests/SmartFormattingTests.swift     |  16 +-
 Tests/FeaturesTests/SpeechCleanupTests.swift       |   5 +-
 Tests/SharedTests/SharedTests.swift                |  80 +--
 23 files changed, 1738 insertions(+), 681 deletions(-)
```
