"""Compare MPS FP32/FP16 arithmetic on identical rounded checkpoint weights."""
import argparse,json,random
from pathlib import Path
import numpy as np
import torch
from model_pipeline import base,read_split,tokenize,SEED

def run(a):
 torch.set_num_threads(4);rows=read_split('test');random.Random(SEED+7).shuffle(rows);rows=rows[:64]
 m32,tok,cfg,cold32=base.load(a.model,'mps','float32')
 m16,_,_,cold16=base.load(a.model,'mps','float16')
 maxLogit=0.;maxProb=0.;agree=0;count=0;records=[]
 for row in rows:
  valid=dict(row);valid['labels']=dict(row['labels']);valid['labels']['coarse_family']=valid['labels']['coarse_family'] or 'other'
  items=tokenize(tok,cfg,[valid]);r32,_=base.predict(m32,items,tok,'mps');r16,_=base.predict(m16,items,tok,'mps')
  for x,y in zip(r32,r16):
   l32=np.asarray(x['logits']);l16=np.asarray(y['logits'])
   def probs(v):v=v-v.max();v=np.exp(v);return v/v.sum()
   dl=float(np.max(np.abs(l32-l16)));dp=float(np.max(np.abs(probs(l32)-probs(l16))))
   same=int(l32.argmax())==int(l16.argmax());agree+=same;count+=1;maxLogit=max(maxLogit,dl);maxProb=max(maxProb,dp)
   records.append({'id':row['id'],'question':x['question'],'argmaxAgreement':same,'maxLogitDelta':dl,'maxProbabilityDelta':dp})
 report={'states':64,'decisions':count,'argmaxAgreements':agree,'agreementRate':agree/count,'maxAbsoluteLogitDifference':maxLogit,
  'maxAbsoluteUncalibratedProbabilityDifference':maxProb,'acceptableForMeasuredFP16Experiment':agree/count>=.99 and maxProb<=.02,
  'checkpointSHA256':base.sha(a.model/'model.safetensors'),'criterion':'At least 99% argmax agreement and at most .02 uncalibrated probability difference; independent of calibration threshold selection. Does not enable production policies.',
  'reference':'MPS FP32 and MPS FP16, same saved FP16 weights; arithmetic parity, not restoration of pre-rounding trained FP32 weights. Native CPU parity is separate.',
  'decisionsDetail':records}
 a.output.write_text(json.dumps(report,indent=2)+'\n');print({k:v for k,v in report.items() if k!='decisionsDetail'})
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--output',type=Path,required=True);run(p.parse_args())
