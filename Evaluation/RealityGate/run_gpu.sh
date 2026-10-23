#!/bin/bash
# Run from this corpus directory on an available CUDA GPU (e.g. Kaggle T4).
# No uploads, publication, automatic installation or repository changes.
set -euo pipefail
cd "$(dirname "$0")"
task_output="${LOCALFLOW_TRAINING_OUTPUT:-./gpu-experiment}"
python -m unittest discover -s . -p 'test_*.py' -v
python -c 'import torch; assert torch.cuda.is_available(), "A CUDA GPU is required"'
python fetch_checkpoints.py laya-multilingual "$task_output/base"
python model_pipeline.py train --model "$task_output/base" \
  --output "$task_output/localflow-laya-v1" --device cuda --epochs 2 --grad-accum 32
python model_pipeline.py evaluate --model "$task_output/localflow-laya-v1" \
  --output "$task_output/evaluation" --device cuda --dtype float32
