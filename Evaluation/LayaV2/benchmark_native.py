"""Actual resident native IPC, 1/2/3 questions and family. No Python inference."""
import argparse,json,random,resource,subprocess,time
from pathlib import Path
import numpy as np
from prepare_native import receive
from model_pipeline import read_split,SEED

def run(a):
 rows=read_split('test');workloads={'one':['actionable_command'],'two':['actionable_command','needs_more_speech'],
  'three':['actionable_command','needs_more_speech','correction_or_replacement'],'family':['coarse_family']}
 start=time.perf_counter()
 proc=subprocess.Popen([str(a.package/'localflow-laya'),str(a.package)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
 ready=receive(proc);wallCold=(time.perf_counter()-start)*1000;results={}
 try:
  for wi,(name,heads) in enumerate(workloads.items()):
   samples=random.Random(SEED+wi).sample(rows,51);batch=[];serial=[]
   for i,row in enumerate(samples):
    def ask(questions):
     req={'id':row['id'],'state':{'text':row['state']['utterance'],'isFinal':row['state']['is_final'],'languageCode':'en'},'questions':questions}
     proc.stdin.write(json.dumps(req,ensure_ascii=False)+'\n');proc.stdin.flush();reply=receive(proc);assert reply['id']==row['id']
    start=time.perf_counter();ask(heads);batch.append((time.perf_counter()-start)*1000)
    start=time.perf_counter()
    for head in heads:ask([head])
    serial.append((time.perf_counter()-start)*1000)
   results[name]={'heads':heads,'samples':51,'sampleIDs':[r['id'] for r in samples],'batchedMilliseconds':batch,
    'sequentialMilliseconds':serial,'batchedWarmP50Milliseconds':float(np.percentile(batch[1:],50)),
    'batchedWarmP95Milliseconds':float(np.percentile(batch[1:],95)),
    'sequentialWarmP50Milliseconds':float(np.percentile(serial[1:],50)),
    'sequentialWarmP95Milliseconds':float(np.percentile(serial[1:],95))}
   print(name,results[name]['sequentialWarmP50Milliseconds'],results[name]['sequentialWarmP95Milliseconds'],flush=True)
  a.output.write_text(json.dumps({'ready':ready,'wallColdLoadMilliseconds':wallCold,'firstIPCInferenceMilliseconds':results['one']['batchedMilliseconds'][0],
   'workloads':results,'packageDiskBytes':sum(p.stat().st_size for p in a.package.rglob('*') if p.is_file()),
   'runtime':'Native Swift ONNX Runtime CPU; tokenizer, IPC, forward and readback included. Resident helper. Sequential forwards match hierarchical manager calls; no concurrent training/benchmark. Seed 722041. RSS in ready is load footprint, not inference peak.'},indent=2)+'\n')
 finally:
  proc.stdin.close()
  try:proc.wait(timeout=5)
  except subprocess.TimeoutExpired:proc.kill();proc.wait()
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--package',type=Path,required=True);p.add_argument('--output',type=Path,required=True);run(p.parse_args())
