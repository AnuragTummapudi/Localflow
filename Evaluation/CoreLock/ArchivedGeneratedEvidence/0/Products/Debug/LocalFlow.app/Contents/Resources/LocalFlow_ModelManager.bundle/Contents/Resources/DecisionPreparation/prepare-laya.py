#!/usr/bin/env python3
"""Explicit preparation: download -> SHA verify -> official export -> parity -> calibrate.

The installed helper is native Swift + ONNX; Python is used only during this step.
All source, runtime, checkpoint and build-tool versions are pinned.
"""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time
import urllib.request

REVISION='55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851'
EXPORT_SHA256='3dc6eac8971358ad5531c7124f2e631ddd4da6890a8df8a6237051e56b4594e2'
EXPORT_REVISION='fa9a2a7070b1789912a49ae24603bbfb1a78b001'
SOURCE_HASHES={
 'encoder/config.json':'bf3ab80598fdccf414855a2ce80f22859e4492d06ca8a62ddd1cfb63972f8979',
 'rl_agent_config.json':'ae287b56bbcf5f8c4f4541ae9dfd00c914c4c48b940b8398c3058af37ba92bbd',
 'tokenizer/tokenizer.json':'6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30',
 'tokenizer/tokenizer_config.json':'50044de60daaa73df97d262e15a40d4faf0160e7d742df64b377877a1320dd12',
 'model.safetensors':'891102d372688fc2a094dac56a384bc537b87c63f21f9f3dac0be2b7cbc8d86c'}


def progress(stage,completed=0,total=None):
    print(json.dumps(dict(stage=stage,completedBytes=completed,totalBytes=total)),flush=True)


def digest(path):
    value=hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda:source.read(1024*1024),b''):value.update(block)
    return value.hexdigest()


def download(url,destination,expected=None):
    destination.parent.mkdir(parents=True,exist_ok=True)
    if destination.exists() and expected and digest(destination)==expected:return
    for attempt in range(6):
        offset=destination.stat().st_size if destination.exists() else 0
        headers={'Range':f'bytes={offset}-'} if offset else {}
        try:
            with urllib.request.urlopen(urllib.request.Request(url,headers=headers),timeout=60) as response:
                append=offset>0 and response.status==206
                if not append:offset=0
                total=int(response.headers.get('Content-Length','0'))+offset or None
                with destination.open('ab' if append else 'wb') as output:
                    previous=0
                    while True:
                        block=response.read(1024*1024)
                        if not block:break
                        output.write(block);offset+=len(block)
                        if time.monotonic()-previous>.25:
                            progress('Downloading '+destination.name,offset,total);previous=time.monotonic()
                if total and offset!=total:raise IOError('Incomplete artifact')
            if expected and digest(destination)!=expected:
                destination.unlink();raise ValueError('Artifact checksum mismatch')
            return
        except Exception:
            if attempt==5:raise
            time.sleep(min(attempt+1,5))


ACTIVE_CHILD=None

def stop_preparation(signum,frame):
    if ACTIVE_CHILD is not None:
        try:os.killpg(ACTIVE_CHILD.pid,signal.SIGTERM)
        except ProcessLookupError:pass
    raise SystemExit(128+signum)

signal.signal(signal.SIGTERM,stop_preparation)
signal.signal(signal.SIGINT,stop_preparation)

def run(command,env=None):
    # Child tools have their own process group so explicit cancellation stops exports/builds.
    global ACTIVE_CHILD
    ACTIVE_CHILD=subprocess.Popen([str(c) for c in command],stdout=sys.stderr,env=env,start_new_session=True)
    try:
        code=ACTIVE_CHILD.wait()
        if code:raise subprocess.CalledProcessError(code,command)
    finally:ACTIVE_CHILD=None


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--resources',type=pathlib.Path,required=True)
    parser.add_argument('--output',type=pathlib.Path,required=True)
    parser.add_argument('--work',type=pathlib.Path,help='Retain a test-owned build cache for reproducible developer preparation')
    args=parser.parse_args();base=args.resources.resolve();output=args.output.resolve()
    # Never overwrite an existing package, including the user's installed model.
    if output.exists():raise ValueError('Output already exists; select a new package directory')
    work=args.work.resolve() if args.work else output.parent/(output.name+'-preparation')
    work.mkdir(parents=True,exist_ok=True)
    if shutil.disk_usage(work).free<6*1024**3:raise ValueError('Model preparation needs at least 6 GiB of free space')
    helper=base/'Runtime/LayaHelper' if (base/'Runtime').exists() else base/'LayaHelper'
    evaluation=base/'Evaluation/Laya' if (base/'Evaluation').exists() else base/'Laya'
    questions=base/'Features/CommandMode/Resources/laya-questions.json' if (base/'Features').exists() else base/'laya-questions.json'
    python=work/'venv/bin/python'
    progress('Preparing pinned export tools')
    if not python.exists():run([sys.executable,'-m','venv',work/'venv'])
    run([python,'-m','pip','install','laya==0.3.24','torch==2.14.1','transformers==5.18.0',
         'onnx==1.23.1','onnxruntime==1.24.2','onnxscript==0.7.2','numpy==2.4.6','tokenizers==0.23.2'])
    checkpoint=work/'checkpoint'
    for name,sha in SOURCE_HASHES.items():
        download(f'https://huggingface.co/convaiinnovations/laya/resolve/{REVISION}/{name}',checkpoint/name,sha)
    progress('Building native ONNX helper')
    shutil.copytree(helper,work/'helper-source',dirs_exist_ok=True)
    run(['swift','build','--package-path',work/'helper-source','--scratch-path',work/'helper-build','-c','release','--disable-automatic-resolution'])
    # Compile locally for this Mac; ORT is statically linked, no runtime download/dylib lookup.
    exporter=work/'export_onnx.py'
    download(f'https://raw.githubusercontent.com/NandhaKishorM/laya/{EXPORT_REVISION}/scripts/export_onnx.py',exporter,EXPORT_SHA256)
    progress('Exporting full-precision official checkpoint')
    graph=work/'laya.onnx'
    run([python,exporter,'--model',checkpoint,'--output',graph])
    adapter=work/'adapt.py'
    adapter.write_text('''import onnx,sys
p=sys.argv[1]
m=onnx.load(p,load_external_data=False)
for node in m.graph.node:
 for i,name in enumerate(node.input):
  if name=='marker_mask':node.input[i]='marker_mask_bool'
for v in m.graph.input:
 if v.name=='marker_mask':v.type.tensor_type.elem_type=onnx.TensorProto.INT64
m.graph.node.insert(0,onnx.helper.make_node('Cast',['marker_mask'],['marker_mask_bool'],to=onnx.TensorProto.BOOL,name='LocalFlowBoolAdapter'))
onnx.save(m,p)
''')
    run([python,adapter,graph])
    output.mkdir(parents=True)
    try:
        for name in ['laya.onnx','laya.onnx.data']:shutil.copy2(work/name,output/name)
        shutil.copytree(checkpoint/'tokenizer',output/'tokenizer')
        shutil.copy2(work/'helper-build/release/localflow-laya',output/'localflow-laya')
        shutil.copy2(questions,output/'questions.json')
        q=json.loads(questions.read_text())
        (output/'option-order.json').write_text(json.dumps({item['id']:list(item['options']) for item in q}))
        (output/'calibration.json').write_text('{}')
        progress('Validating native inference and calibrating 136 voice fixtures')
        env=dict(os.environ,HF_HUB_OFFLINE='1',TRANSFORMERS_OFFLINE='1',LAYA_QUESTIONS=str(questions),LAYA_FIXTURES=str(evaluation/'utterances.json'))
        run([python,evaluation/'evaluate.py','--package',output,'--checkpoint',checkpoint,'--calibrate','--report',output/'validation.json'],env)
        report=json.loads((output/'validation.json').read_text())
        if not report.get('parity',{}).get('passed'):raise ValueError('Export parity did not pass')
        (output/'validation.native.json').unlink(missing_ok=True)
        files=['localflow-laya','laya.onnx','laya.onnx.data','tokenizer/tokenizer.json','tokenizer/tokenizer_config.json','questions.json','option-order.json','calibration.json','validation.json']
        manifest=dict(checkpoint='convaiinnovations/laya',revision=REVISION,protocolVersion=1,validated=True,
                      checkpointSHA256=SOURCE_HASHES['model.safetensors'],exportRevision=EXPORT_REVISION,
                      exporterSHA256=digest(exporter),files={name:digest(output/name) for name in files})
        (output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        progress('Prepared local Laya package',1,1)
    except BaseException:
        shutil.rmtree(output)
        raise

if __name__=='__main__':main()
