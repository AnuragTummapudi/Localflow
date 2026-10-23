"""Keep exact failures visible. Secondary lexical equivalence is diagnostic only.
No normalizer here is used by execution or STT, and URL paths are case-sensitive.
"""
import json, re, statistics, sys, urllib.parse
from collections import defaultdict
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def content(value,key):
 if key=='url':
  u=urllib.parse.urlsplit(value)
  return urllib.parse.urlunsplit((u.scheme.lower(),u.netloc.lower(),u.path,u.query,u.fragment))
 value=' '.join(value.casefold().split()).rstrip('.!?')
 # Benchmark contains this explicitly named compound proper noun. Diagnose its
 # split/join orthography separately; this mapping never enters production.
 return re.sub(r'\blocal flow\b','localflow',value)

def percentile(xs,p):
 xs=sorted(xs);i=(len(xs)-1)*p;lo=int(i);return xs[lo]+(xs[min(lo+1,len(xs)-1)]-xs[lo])*(i-lo)

def summarize(path):
 data=json.loads(path.read_text());rows=data['rows'];checks=[];category=defaultdict(list)
 for row in rows:
  expected=row['expected'];actual=row['actual']
  for i,gold in enumerate(expected):
   observed=actual[i] if i<len(actual) else {}
   exact=gold==observed
   lexical=gold.keys()==observed.keys() and all(content(v,k)==content(observed[k],k) for k,v in gold.items())
   kind='exact' if exact else 'orthographic_difference' if lexical else 'content_error'
   fields={k:{'expected':v,'actual':observed.get(k),'exact':v==observed.get(k),
     'contentCorrect':k in observed and content(v,k)==content(observed[k],k)} for k,v in gold.items() if k!='tool' and v}
   for k,v in fields.items():category[k].append(v)
   names=[n for n in ('LocalFlow','Ada Lovelace','Swift') if any(n in value for value in gold.values())]
   for name in names:
    vals=' '.join(v for k,v in observed.items() if k!='tool')
    category['properName'].append({'exact':name in vals,'contentCorrect':content(name,'properName') in content(vals,'properName')})
   checks.append({'scenario':row['scenario'],'repeat':row['repeat'],'action':i,'exact':exact,'contentEquivalent':lexical,'diagnosis':kind,'fields':fields})
 def rate(values):return {'count':len(values),'exactCorrect':sum(v['exact'] for v in values),'exactRate':sum(v['exact'] for v in values)/len(values),
 'contentCorrect':sum(v['contentCorrect'] for v in values),'contentRate':sum(v['contentCorrect'] for v in values)/len(values)}
 n=len(checks);warm=[r['finalInferenceMilliseconds'] for r in rows[1:]]
 return {'engine':data['engine'],'expectedPayloads':n,'exactCorrect':sum(c['exact'] for c in checks),'exactRate':sum(c['exact'] for c in checks)/n,
 'exactFailureRate':sum(not c['exact'] for c in checks)/n,'contentCorruptions':sum(not c['contentEquivalent'] for c in checks),
 'contentCorruptionRate':sum(not c['contentEquivalent'] for c in checks)/n,'orthographicDifferences':sum(c['diagnosis']=='orthographic_difference' for c in checks),
 'semanticPayloadCorrectnessProxy':sum(c['contentEquivalent'] for c in checks)/n,
 'semanticMetricLimit':'Conservative lexical equivalence proxy, not independent human semantic judgments. Only case, whitespace, terminal punctuation, and named LocalFlow split/join; URLs preserve path/query case. Exact failures always retained.',
 'categories':{k:rate(v) for k,v in category.items()},
 'performance':{'coldPreparationMilliseconds':data['coldPreparationMilliseconds'],'firstInferenceMilliseconds':rows[0]['finalInferenceMilliseconds'],
 'warmP50Milliseconds':percentile(warm,.5),'warmP95Milliseconds':percentile(warm,.95),'peakRSSBytes':data['peakRSSBytes'],
 'perScenarioWarmMilliseconds':{str(i):[r['finalInferenceMilliseconds'] for r in rows if r['scenario']==i and r['repeat']>0] for i in range(1,11)}},
 'repeatAgreement':all(rows[i]['transcript']==rows[i+10]['transcript']==rows[i+20]['transcript'] for i in range(10)),
 'checks':checks,'unexpectedExtraActions':sum(max(0,len(r['actual'])-len(r['expected'])) for r in rows)}
if __name__=='__main__':
 results=[summarize(p) for p in sorted(ROOT.glob('*.json')) if p.stem in ('apple','parakeet','whisper-base','whisper-turbo')]
 hashes=[{r['scenario']:r['audioSHA256'] for r in json.loads((ROOT/(x['engine']+'.json')).read_text())['rows']} for x in results]
 assert all(x==hashes[0] for x in hashes),'Frozen audio differs across engines'
 (ROOT/'summary.json').write_text(json.dumps({'engines':results,'sameAudioHashes':hashes[0],'nativeEffects':'none'},indent=2)+'\n')
 for x in results:print(x['engine'],x['exactCorrect'],x['expectedPayloads'],x['contentCorruptions'],x['performance'])
