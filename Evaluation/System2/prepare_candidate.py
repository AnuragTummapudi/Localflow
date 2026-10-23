"""Explicit developer setup: one immutable checkpoint, TLS curl, hash-checked staging."""
import json,pathlib,subprocess,hashlib
root=pathlib.Path(__file__).resolve().parents[2]
meta=json.loads((root/'Evaluation/System2/quantized.json').read_text())
target=root/'.build/system2/candidate';target.mkdir(parents=True,exist_ok=True)
files=[]
for f in meta['siblings']:
    name=f['rfilename']
    if name not in ['config.json','model.safetensors','model.safetensors.index.json','tokenizer.json','tokenizer_config.json','vocab.json','chat_template.jinja']:continue
    p=target/name
    if not p.exists():
        print('Download',name,flush=True)
        subprocess.run(['curl','--fail','--location','--continue-at','-','--retry','5','--retry-all-errors','--silent','--show-error','https://huggingface.co/'+meta['id']+'/resolve/'+meta['sha']+'/'+name,'-o',str(p)+'.partial'],check=True)
        pathlib.Path(str(p)+'.partial').rename(p)
    h=hashlib.sha256()
    with p.open('rb') as s:
        for b in iter(lambda:s.read(1024*1024),b''):h.update(b)
    digest=h.hexdigest()
    expected=f.get('lfs',{}).get('sha256')
    if expected and digest!=expected:raise ValueError('Upstream SHA256 mismatch: '+name)
    if p.stat().st_size!=f['size']:raise ValueError('Size mismatch: '+name)
    files.append({'name':name,'sha256':digest,'bytes':p.stat().st_size})
manifest={'version':1,'upstream':'Qwen/Qwen3.5-4B','upstreamRevision':json.loads((root/'Evaluation/System2/upstream.json').read_text())['sha'],'repository':meta['id'],'revision':meta['sha'],'files':files}
(root/'Core/ModelManager/Resources/PlannerRuntime/model-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
(root/'Evaluation/System2/model-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
print('VERIFIED',sum(f['bytes'] for f in files),flush=True)
