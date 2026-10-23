#!/bin/zsh
# Explicit local developer setup. No model download or enablement; app Download owns model installation.
set -eu
cd "${0:A:h:h}"
swift build --package-path Core/ModelManager/Resources/PlannerRuntime/QwenHelper --scratch-path .build/system2/swift -c release
python3 Evaluation/System2/prepare_native_metal.py
python3 Evaluation/System2/install_runtime.py
