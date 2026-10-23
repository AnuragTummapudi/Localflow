"""End-to-end, variable-input MPS benchmark; only requested questions tokenized/run."""
import argparse,json,random,resource,time
from pathlib import Path
import numpy as np
import torch
from model_pipeline import base,ROOT,read_split,QUESTIONS,options

def prepare(tok,cfg,row,heads):
 items=[]
 for name in heads:
  q=QUESTIONS[name];seq,markers,stats=base.build_sequence(tok,row['state'],{'t':q['type'],'ins':q['instructions'],'crit':q['criteria']},cfg['max_len'],cfg['head_max_len'],return_truncation_stats=True)
  assert not stats['truncated'];gold=options(q).index(row['labels'][name])
  items.append({'ids':seq,'markers':markers,'qtype':base.QTYPES[q['type']],'target':[float(i==gold) for i in range(len(markers))],
   'goldIndex':gold,'id':row['id'],'question':name,'split':row['split']})
 return items

def run(a):
 assert torch.backends.mps.is_available();torch.set_num_threads(4)
 model,tok,cfg,cold=base.load(a.model,'mps','float16');rows=read_split('test')
 workloads={'A_actionable':['actionable_command'],'B_actionable_more':['actionable_command','needs_more_speech'],
  'C_three_questions':['actionable_command','needs_more_speech','correction_or_replacement'],'D_coarse_family_after_required':['coarse_family'],
  'E_all_required':['actionable_command','needs_more_speech','correction_or_replacement','coarse_family']}
 results={}
 for wi,(name,heads) in enumerate(workloads.items()):
  candidates=[r for r in rows if all(r['labels'][h] is not None for h in heads)]
  samples=random.Random(722041+wi).sample(candidates,101);times=[];serialTimes=[];allocated=[];lengths=[]
  for row in samples:
   base.synchronize('mps');start=time.perf_counter();items=prepare(tok,cfg,row,heads)
   _,ms=base.predict(model,items,tok,'mps');base.synchronize('mps');times.append((time.perf_counter()-start)*1000)
   base.synchronize('mps');serialStart=time.perf_counter();serialItems=prepare(tok,cfg,row,heads)
   for item in serialItems:base.predict(model,[item],tok,'mps')
   base.synchronize('mps');serialTimes.append((time.perf_counter()-serialStart)*1000)
   allocated.append(torch.mps.current_allocated_memory());lengths.append(max(len(x['ids']) for x in items))
  results[name]={'heads':heads,'sampleIDs':[r['id'] for r in samples],'samples':len(times),'firstWorkloadInferenceMilliseconds':times[0],
   'warmP50Milliseconds':float(np.percentile(times[1:],50)),'warmP95Milliseconds':float(np.percentile(times[1:],95)),
   'meanSequenceTokens':sum(lengths)/len(lengths),'maxSampledMPSAllocatedBytes':max(allocated),'timesMilliseconds':times,'sequentialQuestionTimesMilliseconds':serialTimes,
   'sequentialWarmP50Milliseconds':float(np.percentile(serialTimes[1:],50)),'sequentialWarmP95Milliseconds':float(np.percentile(serialTimes[1:],95))}
  print(name,results[name]['warmP50Milliseconds'],results[name]['warmP95Milliseconds'],flush=True)
 report={'coldLoadMilliseconds':cold,'firstInferenceMilliseconds':results['A_actionable']['firstWorkloadInferenceMilliseconds'],
 'workloads':results,'device':'mps','dtype':'float16','threads':4,'seed':722041,
 'measurement':'One resident model. Includes requested-head text tokenization, tensor preparation/transfers, synchronized forward pass and logit readback. Each workload measures batched heads and separate sequential forwards on the same state. Workloads sequential; no concurrent training/inference job permitted by runner. First workload samples after A are not fresh process/model cold starts.',
 'peakRSSBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'mpsAllocatedBytes':torch.mps.current_allocated_memory(),
 'mpsDriverAllocatedBytes':torch.mps.driver_allocated_memory(),'mpsPeakLimitation':'Allocated memory sampled after each forward, not transient intra-forward peak.',
 'checkpointDiskBytes':(a.model/'model.safetensors').stat().st_size,'modelDirectoryBytes':sum(p.stat().st_size for p in a.model.rglob('*') if p.is_file()),
 'checkpointSHA256':base.sha(a.model/'model.safetensors')}
 a.output.parent.mkdir(parents=True,exist_ok=True);a.output.write_text(json.dumps(report,indent=2)+'\n')
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--output',type=Path,required=True);run(p.parse_args())
