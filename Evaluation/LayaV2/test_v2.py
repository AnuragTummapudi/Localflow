import json, math, sys, unittest
from pathlib import Path
from collections import defaultdict
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT));from build_corpus import norm,sha,TEMPLATES
from decisions import QUESTIONS
from build_corpus import APPS,TOPICS
class CorpusTests(unittest.TestCase):
 def setUp(self):
  self.manifest=json.loads((ROOT/'split-manifest.json').read_text())
  self.rows=[json.loads(x) for s in ('train','calibration','test') for x in (ROOT/f'{s}.jsonl').read_text().splitlines()]
 def testFrozenHashesAndMinimums(self):
  for split,minimum in [('train',2000),('calibration',300),('test',500)]:
   data=[r for r in self.rows if r['split']==split]
   self.assertGreaterEqual(len(data),minimum);self.assertEqual(sha(ROOT/f'{split}.jsonl'),self.manifest['splits'][split]['sha256'])
   self.assertEqual(sum(r['labels']['needs_more_speech'] for r in data),len(data)//2)
   for label in ('actionable_command','correction_or_replacement'):
    count=sum(r['labels'][label] for r in data);self.assertGreater(count,0);self.assertLess(count,len(data))
 def testNoDuplicateOrScenarioTemplateLeakage(self):
  self.assertEqual(len(set(r['id'] for r in self.rows)),len(self.rows))
  self.assertEqual(len(set(r['state']['utterance'] for r in self.rows)),len(self.rows))
  self.assertEqual(len(set(norm(r['state']['utterance']) for r in self.rows)),len(self.rows))
  for field in ('family','template_family'):
   ownership=defaultdict(set)
   for r in self.rows:ownership[r[field]].add(r['split'])
   self.assertTrue(all(len(v)==1 for v in ownership.values()))
  shapes=[t for modes in TEMPLATES.values() for templates in modes.values() for t in templates]
  self.assertEqual(len(set(shapes)),len(shapes))
 def testDiagnosticSlicesAndConditionalFamily(self):
  for split in ('train','calibration','test'):
   for category in ('partial_application','partial_correction','incomplete_note','incomplete_reminder','incomplete_web_query','trailing_conjunction','dictation_prefix'):
    self.assertGreaterEqual(sum(r['split']==split and r['diagnostic']==category for r in self.rows),10,(split,category))
  for row in self.rows:self.assertEqual(row['labels']['coarse_family'] is not None,row['labels']['actionable_command'])
  for row in self.rows:
   if row['mode']=='dictation' and row['diagnostic']=='repeated_partial':
    self.assertFalse(row['labels']['correction_or_replacement'])
   if row['diagnostic'] in ('initial_prefix','streaming_prefix','compound_prefix','partial_application'):
    self.assertTrue(row['labels']['needs_more_speech'])
  train=[r for r in self.rows if r['split']=='train']
  self.assertGreaterEqual(sum(r['diagnostic'] in ('streaming_prefix','compound_prefix') for r in train),300)
 def testFinalFlagCannotReplaceMoreSpeechDecision(self):
  pairs={(r['state']['is_final'],r['labels']['needs_more_speech']) for r in self.rows}
  self.assertEqual(len(pairs),4)
 def testEntityPartitionsIncludeFixedCorrectionDestinations(self):
  for values in (APPS,TOPICS):
   groups=[set(v) for v in values.values()]
   for i,left in enumerate(groups):
    for right in groups[i+1:]:self.assertFalse(left & right)
  import re
  for split,modes in TEMPLATES.items():
   other={name for key,names in APPS.items() if key!=split for name in names}
   for templates in modes.values():
    for template in templates:
     for name in other:
      self.assertIsNone(re.search(r'(?i)\b(?:open|launch|start|activate|switch to)\s+'+re.escape(name)+r'\b',template),(split,template,name))
 def testNoRiskOrPayloadOutputsAndNoHumanClaim(self):
  self.assertEqual(set(QUESTIONS),{'actionable_command','needs_more_speech','correction_or_replacement','coarse_family'})
  self.assertIn('PENDING',self.manifest['human_review'])
  import csv
  with (ROOT/'human-review.csv').open() as stream:rows=list(csv.DictReader(stream))
  self.assertGreaterEqual(len(rows),200);self.assertTrue(all(not r['reviewer'] and not r['approved'] for r in rows))
 def testSchemaCopiesMatchPythonAndEachOther(self):
  paths=[ROOT.parent.parent/'Features/CommandMode/Resources/laya-v2-questions.json',ROOT.parent.parent/'Core/ModelManager/Resources/DecisionPreparation/laya-v2-questions.json']
  self.assertEqual(paths[0].read_bytes(),paths[1].read_bytes())
  for q in json.loads(paths[0].read_text()):
   self.assertEqual(q['instructions'],QUESTIONS[q['id']]['instructions']);self.assertEqual(q['type'],QUESTIONS[q['id']]['type'])
if __name__=='__main__':unittest.main()
