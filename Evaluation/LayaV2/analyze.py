"""Evaluation only: all thresholds fit calibration, never held-out data."""
import json, math, random, sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT.parent/'RealityGate'))
from metrics import probabilities, wilson_lower

def interval(correct,n):return [wilson_lower(correct,n),1-wilson_lower(n-correct,n)] if n else [None,None]
def joint_routing(predictions,temperatures):
 groups={}
 for row in predictions:groups.setdefault((row['split'],row['id']),{})[row['question']]=row
 sets={}
 for split in ('calibration','test'):
  rows=[]
  for (s,id),g in groups.items():
   if s!=split:continue
   heads=('actionable_command','needs_more_speech','correction_or_replacement')
   p={h:probabilities(g[h]['logits'],temperatures[h]) for h in heads}
   # Routing may only accept direct, complete, non-correction speech.
   desired={'actionable_command':1,'needs_more_speech':0,'correction_or_replacement':0}
   candidate=all(p[h][desired[h]]>=.5 for h in heads)
   score=min(p[h][desired[h]] for h in heads)
   gold=all(g[h]['goldIndex']==desired[h] for h in heads)
   rows.append({'id':id,'candidate':candidate,'score':score,'gold':gold})
  sets[split]=rows
 results=[]
 for target in (.9,.95,.97,.99):
  candidates=[]
  for t in sorted(set(r['score'] for r in sets['calibration'] if r['candidate'])):
   chosen=[r for r in sets['calibration'] if r['candidate'] and r['score']>=t]
   if len(chosen)>=20 and sum(r['gold'] for r in chosen)/len(chosen)>=target:candidates.append((len(chosen),t,chosen))
  best=max(candidates,key=lambda x:x[0]) if candidates else None
  th=best[1] if best else None
  held=[r for r in sets['test'] if r['candidate'] and th is not None and r['score']>=th]
  cal=best[2] if best else []
  correct=sum(r['gold'] for r in held);calcorrect=sum(r['gold'] for r in cal)
  results.append({'target':target,'threshold':th,'thresholdChosenFrom':'calibration only','minimumCalibrationAccepted':20,
   'calibrationAccepted':len(cal),'calibrationPrecision':calcorrect/len(cal) if cal else None,'calibrationWilson95':interval(calcorrect,len(cal)),
   'heldoutAccepted':len(held),'heldoutPrecision':correct/len(held) if held else None,'heldoutCoverage':len(held)/len(sets['test']),
   'heldoutWilson95':interval(correct,len(held)),'heldoutFalseAccepts':[r['id'] for r in held if not r['gold']]})
 return {'definition':'Joint actionable=yes, more=no, correction=no. Score is minimum calibrated probability of those labels. Measures decision eligibility, never executable slots or actual tool completion. Deterministic bypass population is not filtered from this synthetic corpus.',
 'targets':results}

def family_metrics(predictions):
 names=['application','web','productivity','system','text_file','media','other']
 rows=[r for r in predictions if r['split']=='test' and r['question']=='coarse_family'];matrix=[[0]*7 for _ in range(7)]
 for r in rows:matrix[r['goldIndex']][max(range(7),key=lambda i:r['logits'][i])]+=1
 classes={}
 for i,n in enumerate(names):
  tp=matrix[i][i];gold=sum(matrix[i]);pred=sum(row[i] for row in matrix)
  p=tp/pred if pred else None;r=tp/gold if gold else None
  classes[n]={'count':gold,'precision':p,'recall':r,'f1':2*tp/(gold+pred) if gold+pred else None}
 return {'order':names,'confusionMatrixGoldRows':matrix,'perClass':classes,'macroF1':sum(x['f1'] or 0 for x in classes.values())/7}

def attach(path):
 report=json.loads((path/'report.json').read_text());p=json.loads((path/'predictions.json').read_text());temps={n:v['temperature'] for n,v in report['questions'].items()}
 report['jointRouting']=joint_routing(p,temps);report['coarseFamilyDetails']=family_metrics(p)
 report['moreSpeechFailures']={'falseComplete':[r['id'] for r in p if r['question']=='needs_more_speech' and r['split']=='test' and r['goldIndex']==1 and r['logits'][0]>r['logits'][1]],
  'falseIncomplete':[r['id'] for r in p if r['question']=='needs_more_speech' and r['split']=='test' and r['goldIndex']==0 and r['logits'][1]>r['logits'][0]]}
 (path/'report.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report['jointRouting'],indent=2))
if __name__=='__main__':attach(Path(sys.argv[1]))
