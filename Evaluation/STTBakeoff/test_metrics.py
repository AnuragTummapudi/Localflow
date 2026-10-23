import importlib.util, unittest
from pathlib import Path
spec=importlib.util.spec_from_file_location('sttmetrics',Path(__file__).with_name('metrics.py'));m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class MetricsTests(unittest.TestCase):
 def testContentErrorAndOrthographicDifferenceStayDistinct(self):
  self.assertNotEqual(m.content('https://example.com','url'),m.content('https://examblow.com','url'))
  self.assertEqual(m.content('Swift actors','searchQuery'),m.content('Swift Actors','searchQuery'))
  self.assertNotEqual('Swift actors','Swift Actors')
 def testURLPathAndDifferentProperNamesAreNotNormalizedAway(self):
  self.assertNotEqual(m.content('https://example.com/Actors','url'),m.content('https://example.com/actors','url'))
  self.assertNotEqual(m.content('Ada Lovelace','properName'),m.content('Ada Loveplace','properName'))
  self.assertNotEqual(m.content('therapist','text'),m.content('the rapist','text'))
if __name__=='__main__':unittest.main()
