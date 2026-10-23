#!/bin/bash
# Explicit build/install preparation only. Normal LocalFlow inference never runs this script.
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"
if [[ -d "$script_dir/../Runtime/LayaHelper" ]]; then
    resource_root="$(cd "$script_dir/.." && pwd)"
else
    resource_root="$script_dir"
fi
python_bin="${LOCALFLOW_PREPARATION_PYTHON:-}"
if [[ -z "$python_bin" ]]; then
    for candidate in /opt/homebrew/bin/python3.11 /usr/local/bin/python3.11 /usr/bin/python3; do
        if [[ -x "$candidate" ]]; then python_bin="$candidate"; break; fi
    done
fi
if [[ -z "$python_bin" ]]; then echo 'Python 3.11+ is required only for explicit model export/preparation.' >&2; exit 1; fi
exec "$python_bin" "$script_dir/prepare-laya.py" --resources "$resource_root" "$@"
