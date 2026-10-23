import hashlib
import json
import unittest
from pathlib import Path
from decisions import QUESTIONS, options
from metrics import accumulation_window, probabilities, fit_temperature, summarize, target_coverage, wilson_lower

ROOT = Path(__file__).resolve().parent

class PipelineTests(unittest.TestCase):
    def test_partial_accumulation_window_is_averaged_and_resets_each_epoch(self):
        for _ in range(2):
            windows=[accumulation_window(i,10,4) for i in range(10)]
            self.assertEqual([i for i,(_,flush) in enumerate(windows) if flush],[3,7,9])
            self.assertEqual([n for n,_ in windows],[4]*8+[2]*2)
            self.assertAlmostEqual(sum(1/n for n,_ in windows[-2:]),1.)
    def test_frozen_splits_have_no_shared_family_or_utterance(self):
        manifest = json.loads((ROOT/"split-manifest.json").read_text())
        families, texts = {}, {}
        for split in ("train","calibration","test"):
            path=ROOT/f"{split}.jsonl"
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),manifest["splits"][split]["sha256"])
            for line in path.read_text().splitlines():
                row=json.loads(line)
                self.assertEqual(families.setdefault(row["family"],split),split)
                self.assertEqual(texts.setdefault(row["state"]["utterance"].casefold(),split),split)
                self.assertEqual(set(row["labels"]),set(QUESTIONS))
                for question,label in row["labels"].items(): self.assertIn(label,options(QUESTIONS[question]))

    def test_calibration_rejects_held_out_input(self):
        with self.assertRaises(ValueError): fit_temperature([{"split":"test","logits":[1.,0.],"goldIndex":0}])

    def test_temperature_scaling_does_not_change_answers(self):
        for temperature in (.1,1.,10.):
            p=probabilities([4.,2.,-2.],temperature)
            self.assertAlmostEqual(sum(p),1.);self.assertEqual(p.index(max(p)),0)

    def test_small_perfect_sample_cannot_prove_safety_precision(self):
        self.assertLess(wilson_lower(40,40),.95)
        self.assertLess(wilson_lower(72,72),.99)

    def test_empirical_selection_does_not_silently_become_supported_gate(self):
        cal=[{"split":"calibration","logits":[10.,0.],"goldIndex":0} for _ in range(40)]
        test=[{"split":"test","logits":[10.,0.],"goldIndex":1} for _ in range(72)]
        result=target_coverage(cal,test,1.)["0.95"]
        self.assertEqual(result["testAtCalibrationEmpiricalGate"]["selectiveAccuracy"],0.)
        self.assertIsNone(result["calibrationStatisticallySupported"])

    def test_precision_recall_and_ece_count_incorrect_confident_answers(self):
        report=summarize([{"logits":[0.,10.],"goldIndex":0},{"logits":[10.,0.],"goldIndex":1}])
        self.assertEqual(report["accuracy"],0.);self.assertEqual(report["precision"],0.)
        self.assertEqual(report["recall"],0.);self.assertGreater(report["ece10"],.99)

if __name__=="__main__": unittest.main()
