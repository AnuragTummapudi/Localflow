"""One resident child, same registry-generated prompts, modes; numeric evidence and calls only."""
import argparse,subprocess,json,pathlib,time,select,statistics,signal,os
p=argparse.ArgumentParser();p.add_argument('--runtime',choices=['native','python'],required=True);p.add_argument('--samples',type=int,default=5);p.add_argument('--smoke',action='store_true');p.add_argument('--first-only',action='store_true');a=p.parse_args()
root=pathlib.Path(__file__).resolve().parents[2];model=root/'.build/system2/candidate'
cmd=[str(root/'.build/system2/swift/release/localflow-qwen'),str(model)] if a.runtime=='native' else [str(root/'.build/system2/python/bin/python'),str(root/'Evaluation/System2/python_helper.py'),str(model)]
env={'PATH':'/usr/bin:/bin','HF_HUB_OFFLINE':'1','TRANSFORMERS_OFFLINE':'1','HOME':str(pathlib.Path.home())}
child=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(root/('Evaluation/System2/'+a.runtime+'-stderr.log'),'w'),text=True,env=env,start_new_session=True)
def receive(timeout=150):
    if not select.select([child.stdout],[],[],timeout)[0]:raise TimeoutError('Resident child deadline')
    line=child.stdout.readline()
    if not line:raise RuntimeError('Resident helper exited '+str(child.poll()))
    return json.loads(line)
label=a.runtime+('-first' if a.first_only else '')+('-smoke' if a.smoke else '')
output=root/('Evaluation/System2/'+label+'-latency.json');rows=[]
try:
    load=receive();print('LOAD',json.dumps(load),flush=True)
    if not load.get('ready'):raise RuntimeError('Not ready')
    cases=json.loads((root/'Evaluation/System2/benchmark-requests.json').read_text())
    for thinking in [False,True]:
        for case in cases[:1] if a.smoke else cases:
            for sample in range(1 if a.smoke else a.samples+1):
                wire=dict(case['wire'],thinking=thinking,firstOnly=a.first_only)
                start=time.perf_counter();child.stdin.write(json.dumps(wire)+'\n');child.stdin.flush();reply=receive()
                if 'error' in reply or not all(k in reply for k in ['ttftMS','firstToolCallMS','planMS','tokensPerSecond']):raise RuntimeError('Runtime failed: '+str(reply.get('error','missing metrics')))
                # output is already stripped of reasoning by both children; no raw stream is saved.
                result={'case':case['id'],'thinking':thinking,'sample':sample,'warmup':sample==0,'wallMS':(time.perf_counter()-start)*1000,'reply':reply}
                rows.append(result)
                output.write_text(json.dumps({'runtime':a.runtime,'command':cmd,'load':load,'samplesPerModeCase':a.samples,'firstOnly':a.first_only,'rssSemantics':'current RSS' if a.runtime=='native' else 'high-water RSS','rows':rows},indent=2)+'\n')
                print(label,case['id'],'thinking='+str(thinking),'sample='+str(sample),'ms='+str(round(result['wallMS'])),'error='+str(reply.get('error','')),flush=True)
finally:
    child.stdin.close()
    try:child.wait(timeout=5)
    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
