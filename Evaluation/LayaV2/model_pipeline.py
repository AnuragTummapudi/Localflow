"""Reuse the pinned official model, token construction, RLCD and CE pipeline.
One-hot supervised labels; no fabricated teacher probability distribution.
Heads are conditional. Calibration is separate. Held-out never affects fitting.
"""
import argparse, hashlib, importlib.util, json, math, os, random, resource, sys, time
from pathlib import Path
import numpy as np
import torch
from safetensors.torch import save_file
from decisions import QUESTIONS, options
ROOT=Path(__file__).resolve().parent
OLD=ROOT.parent/'RealityGate'
spec=importlib.util.spec_from_file_location('proven_pipeline',OLD/'model_pipeline.py')
# The reused source imports decisions; this process has deliberately loaded v2's schema.
sys.path.append(str(OLD))
base=importlib.util.module_from_spec(spec);spec.loader.exec_module(base)
from metrics import probabilities, fit_temperature, wilson_lower, accumulation_window
SEED=722041

def read_split(name):
 manifest=json.loads((ROOT/'split-manifest.json').read_text());p=ROOT/f'{name}.jsonl'
 assert base.sha(p)==manifest['splits'][name]['sha256']
 rows=[json.loads(line) for line in p.read_text().splitlines()]
 assert all(r['split']==name for r in rows)
 return rows

def tokenize(tokenizer,cfg,rows):
 items=[]
 for row in rows:
  # The same JSON state contract is used in training and runtime evaluation.
  for name,q in QUESTIONS.items():
   if row['labels'][name] is None:continue
   seq,markers,stats=base.build_sequence(tokenizer,row['state'],{'t':q['type'],'ins':q['instructions'],'crit':q['criteria']},cfg['max_len'],cfg['head_max_len'],return_truncation_stats=True)
   assert not stats['truncated'] and len(markers)==len(options(q)),(row['id'],name)
   gold=options(q).index(row['labels'][name])
   items.append({'ids':seq,'markers':markers,'qtype':base.QTYPES[q['type']], 'target':[float(i==gold) for i in range(len(markers))],
    'goldIndex':gold,'id':row['id'],'question':name,'split':row['split'],'diagnostic':row['diagnostic']})
 return items

def train(a):
 random.seed(SEED);np.random.seed(SEED);torch.manual_seed(SEED);torch.set_num_threads(4)
 model,tok,cfg,cold=base.load(a.model,'mps','float32');items=tokenize(tok,cfg,read_split('train'))
 model.encoder.gradient_checkpointing_enable(gradient_checkpointing_kwargs={'use_reentrant':False})
 model.head_checkpointing=True;model.train()
 optimizer=torch.optim.AdamW([{'params':[p for n,p in model.named_parameters() if n.startswith('encoder.')],'lr':2.5e-5},
 {'params':[p for n,p in model.named_parameters() if not n.startswith('encoder.')],'lr':1e-4}],weight_decay=.01)
 updates=math.ceil(len(items)/a.grad_accum)*a.epochs
 scheduler=torch.optim.lr_scheduler.CosineAnnealingLR(optimizer,T_max=updates,eta_min=1e-6)
 a.output.mkdir(parents=True,exist_ok=False)
 import shutil
 shutil.copy2(Path(__file__),a.output/'executed-training-source.py')
 shutil.copy2(OLD/'model_pipeline.py',a.output/'reused-training-source.py')
 import importlib.metadata as md
 config={'experiment':'LocalFlow-Laya-v2','baseProvenance':json.loads((a.model/'provenance.json').read_text()),
 'baseSHA256':base.sha(a.model/'model.safetensors'),'dependencies':{n:md.version(n) for n in ('torch','transformers','numpy','safetensors','laya')},
 'seed':SEED,'epochs':a.epochs,'gradAccum':a.grad_accum,'microBatch':1,'device':'mps','trainingDtype':'float32',
 'loss':a.loss,'labelTargets':'one-hot supervised; independent soft teacher targets unavailable',
 'optimizer':{'name':'AdamW','encoderLR':2.5e-5,'headLR':1e-4,'weightDecay':.01},'scheduler':{'name':'cosine','updates':updates,'minLR':1e-6},
 'clipNorm':1.,'projections':4 if a.loss=='rlcd-ce' else 0,'sigma':[.4,.1],'properRewardWeights':[.75,1.],
 'recipeRevision':'2e4d9c87e8b1621deb344eac7de5c7258f32f849','datasetManifestSHA256':base.sha(ROOT/'split-manifest.json'),
 'splitHashes':{s:base.sha(ROOT/f'{s}.jsonl') for s in ('train','calibration','test')},
 'pipelineSHA256':base.sha(Path(__file__)),'reusedPipelineSHA256':base.sha(OLD/'model_pipeline.py'),'questionSHA256':base.sha(ROOT/'decisions.py')}
 (a.output/'training-config.json').write_text(json.dumps(config,indent=2)+'\n')
 began=time.perf_counter();step=0;micro=0;losses=[];optimizer.zero_grad(set_to_none=True)
 with (a.output/'training-metrics.jsonl').open('w',buffering=1) as log:
  for epoch in range(a.epochs):
   random.Random(SEED+epoch).shuffle(items);sigma=.4-.3*epoch/max(1,a.epochs-1)
   for index,item in enumerate(items):
    ids,attention,pos,mask,qtype,target=[x.to('mps') for x in base.collate([item],tok.pad_token_id)]
    logits,activation=model(ids,attention,pos,mask,qtype)
    ce=-(target*torch.log_softmax(logits.masked_fill(~mask,-1e4),-1)).sum(-1).mean()
    rl=0*ce
    if a.loss=='rlcd-ce':
     k=mask.sum(-1,keepdim=True).float();eps=torch.randn((4,)+logits.shape,device='mps')*sigma*mask
     eps=(eps-eps.sum(-1,keepdim=True)/k)*mask;noisy=logits.detach().unsqueeze(0)+eps
     with torch.no_grad():
      reward=base.proper_reward(torch.softmax(noisy.masked_fill(~mask,-1e4),-1),target.unsqueeze(0),qtype,mask,w_sph=.75,w_rps=1.)
      advantage=reward-reward.mean(0,keepdim=True);advantage=advantage/(advantage.std()+1e-6)
     logp=-(((noisy-logits.unsqueeze(0))**2)*mask).sum(-1)/(2*sigma**2);rl=-(advantage*logp).mean()
    window,flush=accumulation_window(index,len(items),a.grad_accum);loss=(ce+rl+0*activation.sum())/window
    if not torch.isfinite(loss):raise RuntimeError('Non-finite loss')
    loss.backward();micro+=1;losses.append((float(ce.detach().cpu()),float(rl.detach().cpu())))
    if flush:
     grad=float(torch.nn.utils.clip_grad_norm_(model.parameters(),1.).detach().cpu())
     optimizer.step();scheduler.step();optimizer.zero_grad(set_to_none=True);step+=1
     record={'update':step,'microSteps':micro,'epoch':epoch,'ce':sum(x for x,y in losses)/len(losses),'rl':sum(y for x,y in losses)/len(losses),
      'gradientNormBeforeClip':grad,'learningRates':scheduler.get_last_lr(),'elapsedSeconds':time.perf_counter()-began}
     log.write(json.dumps(record)+'\n');print(record,flush=True);losses=[]
 (a.output/'encoder').mkdir(exist_ok=True);model.encoder.config.save_pretrained(a.output/'encoder');tok.save_pretrained(a.output/'tokenizer')
 save_file({n:p.detach().half().cpu().contiguous() for n,p in model.state_dict().items()},str(a.output/'model.safetensors'))
 cfg.pop('temperature_by_options',None);cfg['temperature']=[1.,1.,1.]
 (a.output/'rl_agent_config.json').write_text(json.dumps(cfg,indent=2)+'\n')
 status={'status':'configured training complete; not production qualified','updates':step,'microSteps':micro,'elapsedSeconds':time.perf_counter()-began,
 'checkpointSHA256':base.sha(a.output/'model.safetensors'),'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'testUsedInTraining':False}
 (a.output/'training-status.json').write_text(json.dumps(status,indent=2)+'\n');print(status,flush=True)

def wilson(correct,n):
 low=wilson_lower(correct,n)
 return [low,1-wilson_lower(n-correct,n)] if n else [None,None]

def binary(rows,t,threshold=.5):
 pp=[(probabilities(r['logits'],t)[1],r['goldIndex']) for r in rows]
 tp=sum(p>=threshold and g==1 for p,g in pp);fp=sum(p>=threshold and g==0 for p,g in pp)
 fn=sum(p<threshold and g==1 for p,g in pp);tn=len(pp)-tp-fp-fn
 precision=tp/(tp+fp) if tp+fp else None;recall=tp/(tp+fn) if tp+fn else None
 return {'count':len(rows),'tp':tp,'fp':fp,'fn':fn,'tn':tn,'precision':precision,'recall':recall,
 'f1':2*tp/(2*tp+fp+fn) if 2*tp+fp+fn else None,'positivePredictionCoverage':(tp+fp)/len(pp),
 'accuracy':(tp+tn)/len(pp),'precisionWilson95':wilson(tp,tp+fp),'threshold':threshold}

def select(cal,held,t,target,positive_only=False):
 def pairs(rows):
  result=[]
  for r in rows:
   p=probabilities(r['logits'],t);winner=int(np.argmax(p))
   if positive_only and winner!=1:continue
   result.append((p[winner],winner==r['goldIndex']))
  return result
 c=pairs(cal);h=pairs(held)
 candidates=[]
 for threshold in sorted(set(p for p,g in c)):
  accepted=[g for p,g in c if p>=threshold]
  if len(accepted)>=20 and sum(accepted)/len(accepted)>=target:candidates.append((len(accepted),threshold,sum(accepted)))
 best=max(candidates) if candidates else None;th=best[1] if best else None
 values=[g for p,g in h if th is not None and p>=th]
 return {'target':target,'threshold':th,'selectionSplit':'calibration','calibrationAccepted':best[0] if best else 0,
 'calibrationPrecision':best[2]/best[0] if best else None,'heldoutAccepted':len(values),'heldoutCoverage':len(values)/len(held),
 'heldoutPrecision':sum(values)/len(values) if values else None,'heldoutWilson95':wilson(sum(values),len(values))}

def report(predictions):
 result={}
 for name in QUESTIONS:
  cal=[r for r in predictions if r['split']=='calibration' and r['question']==name]
  held=[r for r in predictions if r['split']=='test' and r['question']==name];t=fit_temperature(cal)
  from metrics import summarize
  item={'temperature':t,'calibration':summarize(cal,t),'heldout':summarize(held,t),
   'selectiveCorrectDecision':[select(cal,held,t,target) for target in (.9,.95,.97,.99)]}
  if name!='coarse_family':
   item['binary']=binary(held,t)
   item['positiveRouting']=[select(cal,held,t,target,True) for target in (.9,.95,.97,.99)]
   # PR curve is a diagnostic sweep, never a held-out-fitted deployment threshold.
   item['prCurve']=[binary(held,t,x/100) for x in range(101)]
   item['slices']={s:binary([r for r in held if r['diagnostic']==s],t) for s in sorted(set(r['diagnostic'] for r in held))}
   item['errors']=[{'id':r['id'],'diagnostic':r['diagnostic'],'gold':bool(r['goldIndex']),'prediction':bool(np.argmax(r['logits']))} for r in held if int(np.argmax(r['logits']))!=r['goldIndex']]
  result[name]=item
 return result

def evaluate(a):
 torch.set_num_threads(4);model,tok,cfg,cold=base.load(a.model,'mps','float16')
 items=tokenize(tok,cfg,read_split('calibration')+read_split('test'));byid={}
 for item in items:byid.setdefault(item['id'],[]).append(item)
 predictions=[];timings=[]
 for index,group in enumerate(byid.values()):
  result,ms=base.predict(model,group,tok,'mps')
  for row,source in zip(result,group):row['diagnostic']=source['diagnostic']
  predictions+=result;timings.append(ms)
  if index%100==0:print('evaluated',index,flush=True)
 a.output.mkdir(parents=True,exist_ok=True)
 (a.output/'predictions.json').write_text(json.dumps(predictions)+'\n')
 outcome={'checkpointSHA256':base.sha(a.model/'model.safetensors'),'evaluationDtype':'float16','evaluationDevice':'mps',
 'evaluationManifestSHA256':base.sha(ROOT/'split-manifest.json'),'evaluationSourceSHA256':base.sha(Path(__file__)),
 'evaluatedSplitHashes':{s:base.sha(ROOT/f'{s}.jsonl') for s in ('calibration','test')},
 'coldLoadMilliseconds':cold,'firstInferenceMilliseconds':timings[0],
 'performance':{'warmP50Milliseconds':float(np.percentile(timings[1:],50)),'warmP95Milliseconds':float(np.percentile(timings[1:],95)),
 'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'mpsAllocatedBytes':torch.mps.current_allocated_memory(),
 'mpsDriverBytes':torch.mps.driver_allocated_memory(),'diskBytes':sum(p.stat().st_size for p in a.model.rglob('*') if p.is_file())},'questions':report(predictions)}
 (a.output/'report.json').write_text(json.dumps(outcome,indent=2)+'\n')
 (a.output/'calibration.json').write_text(json.dumps({n:v['temperature'] for n,v in outcome['questions'].items()},indent=2)+'\n')
 print(json.dumps({n:v.get('binary',v['heldout']) for n,v in outcome['questions'].items()},indent=2),flush=True)

def latency(a):
 torch.set_num_threads(4);model,tok,cfg,cold=base.load(a.model,'mps','float16')
 rows=read_split('test');items=tokenize(tok,cfg,rows);byid={}
 for item in items:byid.setdefault(item['id'],{})[item['question']]=item
 workloads={'A_actionable':['actionable_command'],'B_actionable_more':['actionable_command','needs_more_speech'],
 'C_actionable_correction':['actionable_command','correction_or_replacement'],'D_family_after_required':['coarse_family'],
 'E_all_required':list(QUESTIONS)}
 result={}
 # Rotate representative variable-length states, one resident model; no logits cache.
 for name,heads in workloads.items():
  elapsed=[];lengths=[];mps=[]
  for group in list(byid.values()):
   if not all(h in group for h in heads):continue
   batch=[group[h] for h in heads];start=time.perf_counter()
   base.predict(model,batch,tok,'mps');base.synchronize('mps');elapsed.append((time.perf_counter()-start)*1000)
   lengths.append(max(len(i['ids']) for i in batch));mps.append(torch.mps.current_allocated_memory())
   if len(elapsed)>=101:break
  result[name]={'heads':heads,'samples':len(elapsed),'firstInferenceMilliseconds':elapsed[0],
   'warmP50Milliseconds':float(np.percentile(elapsed[1:],50)),'warmP95Milliseconds':float(np.percentile(elapsed[1:],95)),
   'meanSequenceTokens':sum(lengths)/len(lengths),'maxMPSAllocatedBytes':max(mps)}
 report_={'coldLoadMilliseconds':cold,'workloads':result,'measurement':'FP16 MPS; pretokenized inputs, collate/transfers/forward/logit readback included; excludes text tokenization. Sequential workload order and thermal drift possible.',
 'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'mpsAllocatedBytes':torch.mps.current_allocated_memory(),'mpsDriverBytes':torch.mps.driver_allocated_memory(),
 'checkpointSHA256':base.sha(a.model/'model.safetensors'),'modelDiskBytes':sum(p.stat().st_size for p in a.model.rglob('*') if p.is_file())}
 a.output.mkdir(parents=True,exist_ok=True);(a.output/'latency.json').write_text(json.dumps(report_,indent=2)+'\n');print(json.dumps(report_,indent=2),flush=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('operation',choices=['train','evaluate','latency']);p.add_argument('--model',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
 p.add_argument('--epochs',type=int,default=2);p.add_argument('--grad-accum',type=int,default=32);p.add_argument('--loss',choices=['ce','rlcd-ce'],default='ce');a=p.parse_args()
 assert torch.backends.mps.is_available(),'MPS unavailable; no silent CPU fallback'
 globals()[a.operation](a)
