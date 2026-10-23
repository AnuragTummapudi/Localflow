"""Test-owned v2 ONNX export and native/PyTorch parity, without installation.

Uses the already downloaded official exporter and existing pinned environment.
No model downloads, runtime Python, quantization or production asset changes.
Policies remain disabled until human review and qualification have occurred.
"""
import argparse, json, os, random, select, shutil, subprocess, time
from pathlib import Path
import numpy as np
import torch
import model_pipeline as pipeline
from decisions import QUESTIONS, options

ROOT=Path(__file__).resolve().parent

def receive(process, timeout=60):
 if not select.select([process.stdout],[],[],timeout)[0]:
  raise TimeoutError('Native parity response deadline exceeded')
 line=process.stdout.readline()
 if not line:raise RuntimeError('Native helper exited')
 return json.loads(line)

def export(a):
 if a.output.exists():raise ValueError('Select a new test-owned output directory')
 config=json.loads((a.model/'training-config.json').read_text())
 status=json.loads((a.model/'training-status.json').read_text())
 assert status['checkpointSHA256']==pipeline.base.sha(a.model/'model.safetensors')
 a.output.mkdir(parents=True)
 provenance={'trainingConfig':config,'trainingStatus':status,
  'evaluationManifestSHA256':pipeline.base.sha(ROOT/'split-manifest.json'),
  'evaluationSplitHashes':{s:pipeline.base.sha(ROOT/f'{s}.jsonl') for s in ('calibration','test')},
  'exporterSHA256':pipeline.base.sha(a.exporter),'preparationSourceSHA256':pipeline.base.sha(Path(__file__)),
  'exportPrecision':'official full-precision CPU export; no quantization','humanReviewed':False}
 (a.output/'training-provenance.json').write_text(json.dumps(provenance,indent=2)+'\n')
 env=dict(os.environ,HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1')
 subprocess.run([os.sys.executable,str(a.exporter),'--model',str(a.model),'--output',str(a.output/'laya.onnx')],env=env,check=True)
 import onnx
 graph=onnx.load(a.output/'laya.onnx',load_external_data=False)
 # Native ORT bindings use Int64 masks. The sole graph adaptation is a bool cast.
 for node in graph.graph.node:
  for i,name in enumerate(node.input):
   if name=='marker_mask':node.input[i]='marker_mask_bool'
 for value in graph.graph.input:
  if value.name=='marker_mask':value.type.tensor_type.elem_type=onnx.TensorProto.INT64
 graph.graph.node.insert(0,onnx.helper.make_node('Cast',['marker_mask'],['marker_mask_bool'],to=onnx.TensorProto.BOOL,name='LocalFlowBoolAdapter'))
 onnx.save(graph,a.output/'laya.onnx')
 # Original tokenizer bytes, whose unchanged behavior is tested in parity.
 shutil.copytree(a.base/'tokenizer',a.output/'tokenizer')
 shutil.copy2(a.helper,a.output/'localflow-laya')
 shutil.copy2(ROOT.parents[1]/'Features/CommandMode/Resources/laya-v2-questions.json',a.output/'questions.json')
 cfg=json.loads((a.model/'rl_agent_config.json').read_text())
 tok=json.loads((a.base/'tokenizer/tokenizer_config.json').read_text())
 spec={'protocolVersion':2,'maxLength':cfg['max_len'],'headMaxLength':cfg['head_max_len'],
  'clsToken':tok['bos_token'],'sepToken':tok['eos_token'],'maskToken':tok['mask_token'],'padToken':tok['pad_token']}
 (a.output/'runtime-spec.json').write_text(json.dumps(spec,indent=2)+'\n')
 order={n:[str(x).lower() if isinstance(x,bool) else x for x in options(q)] for n,q in QUESTIONS.items()}
 (a.output/'option-order.json').write_text(json.dumps(order,indent=2)+'\n')
 temperatures=json.loads((a.evaluation/'calibration.json').read_text())
 policies={n:{'temperature':temperatures[n],'threshold':None,'enabled':False} for n in QUESTIONS}
 (a.output/'calibration.json').write_text(json.dumps(policies,indent=2)+'\n')

def parity(a):
 torch.set_num_threads(4)
 model,tok,cfg,cold=pipeline.base.load(a.model,'cpu','float32')
 rows=pipeline.read_split('test');random.Random(pipeline.SEED+3).shuffle(rows)
 # 32 distinct states, 128 decisions. All heads, variable lengths, final flags,
 # punctuation, correction/ASR slices. Family parity is valid even without gold.
 rows=rows[:32]
 process=subprocess.Popen([str(a.output/'localflow-laya'),str(a.output)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
  stderr=subprocess.PIPE,text=True,bufsize=1,env={'PATH':'/usr/bin:/bin','HF_HUB_OFFLINE':'1'})
 maximum=0.;count=0;agreements=0;records=[];times=[];wall=time.perf_counter()
 try:
  ready=receive(process)
  assert ready.get('ready') and ready['protocolVersion']==2
  ready['wallColdLoadMilliseconds']=(time.perf_counter()-wall)*1000
  for row in rows:
   request={'id':row['id'],'state':{'text':row['state']['utterance'],'isFinal':row['state']['is_final'],'languageCode':'en'},'questions':list(QUESTIONS)}
   start=time.perf_counter();process.stdin.write(json.dumps(request,ensure_ascii=False)+'\n');process.stdin.flush();reply=receive(process)
   times.append((time.perf_counter()-start)*1000);assert reply['id']==row['id']
   # Reuse the exact pinned SDK token construction, not a local approximation.
   valid=dict(row);valid['labels']=dict(row['labels']);valid['labels']['coarse_family']=valid['labels']['coarse_family'] or 'other'
   items=pipeline.tokenize(tok,cfg,[valid]);references,_=pipeline.base.predict(model,items,tok,'cpu')
   for ref in references:
    native=np.asarray(reply['logits'][ref['question']]);expected=np.asarray(ref['logits'])
    difference=float(np.max(np.abs(native-expected)));maximum=max(maximum,difference);count+=1
    agreement=int(native.argmax())==int(expected.argmax());agreements+=agreement
    records.append({'id':row['id'],'question':ref['question'],'native':native.tolist(),'reference':expected.tolist(),'maxDifference':difference,'argmaxAgreement':agreement})
   print('native parity',count,'maximum',maximum,flush=True)
 finally:
  process.stdin.close()
  try:process.wait(timeout=5)
  except subprocess.TimeoutExpired:process.kill();process.wait()
 parity_={'passed':maximum<=.003 and agreements==count,'decisions':count,'maxAbsoluteLogitDifference':maximum,'argmaxAgreements':agreements,
  'reference':'official laya 0.3.26 token construction and full-precision PyTorch CPU','firstIPCInferenceMilliseconds':times[0],
  'warmIPC_p50Milliseconds':float(np.percentile(times[1:],50)),'warmIPC_p95Milliseconds':float(np.percentile(times[1:],95)),
  'nativeReady':ready,'referenceColdLoadMilliseconds':cold}
 (a.output/'parity-details.json').write_text(json.dumps({'summary':parity_,'decisions':records},indent=2)+'\n')
 if not parity_['passed']:raise ValueError('Native v2 parity failed; no validated manifest emitted')
 config=json.loads((a.model/'training-config.json').read_text());policies=json.loads((a.output/'calibration.json').read_text())
 evidence={'checkpointSHA256':pipeline.base.sha(a.model/'model.safetensors'),'questionsSHA256':pipeline.base.sha(a.output/'questions.json'),
  'baseRevision':config['baseProvenance']['revision'],'baseSHA256':config['baseSHA256'],
  'trainingCount':len(pipeline.read_split('train')),'calibrationCount':len(pipeline.read_split('calibration')),'heldoutCount':len(pipeline.read_split('test')),
  'humanReviewed':False,'parity':parity_,'policies':policies,'quality':{}}
 (a.output/'validation.json').write_text(json.dumps(evidence,indent=2)+'\n')
 files=['localflow-laya','laya.onnx','laya.onnx.data','tokenizer/tokenizer.json','tokenizer/tokenizer_config.json','questions.json','option-order.json',
  'calibration.json','validation.json','runtime-spec.json','training-provenance.json']
 manifest={'checkpoint':'LocalFlow-Laya-v2','revision':config['baseProvenance']['revision'],'protocolVersion':2,'validated':True,
  'checkpointSHA256':evidence['checkpointSHA256'],'files':{n:pipeline.base.sha(a.output/n) for n in files}}
 (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print(json.dumps(parity_,indent=2),flush=True)

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('operation',choices=['export','parity']);p.add_argument('--model',type=Path,required=True)
 p.add_argument('--output',type=Path,required=True);p.add_argument('--base',type=Path,required=True);p.add_argument('--evaluation',type=Path,required=True)
 p.add_argument('--exporter',type=Path);p.add_argument('--helper',type=Path);a=p.parse_args()
 globals()[a.operation](a)
