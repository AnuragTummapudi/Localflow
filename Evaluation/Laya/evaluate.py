#!/usr/bin/env python3
"""Repository entry point for the same evaluator bundled with explicit model preparation."""
from pathlib import Path
import runpy
_implementation = Path(__file__).resolve().parents[2] / 'Core/ModelManager/Resources/DecisionPreparation/Laya/evaluate.py'
globals().update({key: value for key, value in runpy.run_path(str(_implementation)).items() if not key.startswith('__')})
if __name__ == '__main__': main()
