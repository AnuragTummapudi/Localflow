import unittest
import math
import json
from pathlib import Path
from evaluate import calibrate,probabilities,score,FIXTURES

class CalibrationTests(unittest.TestCase):
    def test_unreliable_bucket_fails_closed(self):
        rows=[dict(logits=[5.,0.],target=1) for _ in range(20)]
        policy=calibrate(rows)
        self.assertIsNone(policy['threshold'])
        self.assertFalse(policy['enabled'])
    def test_threshold_comes_from_fixture_confidences(self):
        rows=[dict(logits=[5.,0.],target=0) for _ in range(12)]+[dict(logits=[.1,0.],target=1) for _ in range(8)]
        policy=calibrate(rows)
        self.assertIsNotNone(policy['threshold'])
        confidences=[max(probabilities(row['logits'],policy['temperature'])) for row in rows]
        self.assertIn(policy['threshold'],confidences)
        self.assertEqual(score(rows,policy)['selectiveAccuracy'],1)
    def test_no_evidence_abstains(self):
        self.assertFalse(calibrate([])['enabled'])
        self.assertFalse(calibrate([dict(logits=[4,0],target=0)])['enabled'])
    def test_nonfinite_values_rejected(self):
        for value in [math.nan,math.inf]:
            with self.assertRaises(ValueError):probabilities([value,0],1)
            with self.assertRaises(ValueError):probabilities([1,0],value)
    def test_real_fixture_coverage_and_disjoint_splits(self):
        rows=json.loads(FIXTURES.read_text())
        self.assertGreaterEqual(len(rows),100)
        self.assertEqual(len(set(row['id'] for row in rows)),len(rows))
        self.assertEqual(len(set(row['intent'] for row in rows)),11)
        self.assertEqual(set(row['split'] for row in rows),{'calibration','evaluation'})
        self.assertTrue(any('sorry' in row['text'] for row in rows))
        self.assertTrue(any(row['requiresMoreSpeech'] for row in rows))

if __name__=='__main__':unittest.main()
