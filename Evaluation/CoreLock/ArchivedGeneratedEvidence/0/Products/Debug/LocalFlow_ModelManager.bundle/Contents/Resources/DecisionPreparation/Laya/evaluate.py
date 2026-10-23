#!/usr/bin/env python3
"""Offline native evaluation. Python is a development tool, never the app runtime."""
import argparse
import hashlib
import json
import math
import os
import pathlib
import select
import statistics
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
QUESTIONS = pathlib.Path(os.environ.get('LAYA_QUESTIONS', pathlib.Path(__file__).resolve().parents[1] / 'laya-questions.json'))
FIXTURES = pathlib.Path(os.environ.get('LAYA_FIXTURES', pathlib.Path(__file__).with_name('utterances.json')))


def probabilities(logits, temperature):
    if not logits or not all(math.isfinite(x) for x in logits) or not math.isfinite(temperature) or temperature <= 0:
        raise ValueError('Invalid logits or calibration')
    high = max(logits)
    values = [math.exp((x-high)/temperature) for x in logits]
    total = sum(values)
    return [x/total for x in values]


def calibrate(samples):
    """Fit NLL temperature, then maximal coverage with >=95% empirical precision.

    At least eight calibration examples must pass. A bucket with no reliable
    operating point abstains entirely; never manufacture a default threshold.
    """
    if not samples:
        return dict(temperature=1.0, threshold=None, enabled=False)
    grid = [math.exp(math.log(.2)+i*(math.log(8)-math.log(.2))/120) for i in range(121)]
    def loss(temp):
        return sum(-math.log(max(probabilities(row['logits'],temp)[row['target']],1e-12)) for row in samples)/len(samples)
    temperature = min(grid,key=loss)
    predictions = []
    for row in samples:
        ps = probabilities(row['logits'],temperature)
        best = max(range(len(ps)),key=ps.__getitem__)
        predictions.append((ps[best],best==row['target']))
    valid = []
    for threshold in sorted(set(p[0] for p in predictions)):
        accepted = [correct for confidence,correct in predictions if confidence>=threshold]
        if len(accepted)>=8 and sum(accepted)/len(accepted)>=.95:
            valid.append((len(accepted),threshold))
    threshold = max(valid)[1] if valid else None
    return dict(temperature=temperature,threshold=threshold,enabled=threshold is not None,
                calibrationNLL=loss(temperature),calibrationCount=len(samples))


def score(samples,policy):
    correct=accepted=accepted_correct=0
    for row in samples:
        ps=probabilities(row['logits'],policy['temperature'])
        best=max(range(len(ps)),key=ps.__getitem__)
        good=best==row['target'];correct+=good
        if policy['threshold'] is not None and ps[best]>=policy['threshold']:
            accepted+=1;accepted_correct+=good
    return dict(count=len(samples),accuracy=correct/len(samples) if samples else None,
                accepted=accepted,coverage=accepted/len(samples) if samples else 0,
                selectiveAccuracy=accepted_correct/accepted if accepted else None)


def receive(process,timeout=30):
    if not select.select([process.stdout],[],[],timeout)[0]:
        process.kill();raise TimeoutError('Native helper exceeded evaluation deadline')
    line=process.stdout.readline()
    if not line:raise RuntimeError('Native helper exited without a response')
    return json.loads(line)


def run_native(package,fixtures):
    process=subprocess.Popen([str(package/'localflow-laya'),str(package)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL,text=True,bufsize=1,env={'PATH':'/usr/bin:/bin','HF_HUB_OFFLINE':'1'})
    wall=time.perf_counter()
    try:
        ready=receive(process)
        if ready.get('protocolVersion')!=1 or not ready.get('ready'):raise RuntimeError('Invalid helper readiness')
        ready['wallColdLoadMilliseconds']=(time.perf_counter()-wall)*1000
        outputs=[];timings=[]
        for i,row in enumerate(fixtures):
            request=dict(id=row['id'],state=dict(text=row['text'],isFinal=True,languageCode='en'),questions=['intent','risk','requires_more_speech'])
            start=time.perf_counter();process.stdin.write(json.dumps(request)+'\n');process.stdin.flush()
            reply=receive(process,10)
            if reply['id']!=row['id']:raise RuntimeError('Mismatched response')
            timings.append((time.perf_counter()-start)*1000);outputs.append(reply)
            if i%20==0:print(f'Native inference {i+1}/{len(fixtures)}',flush=True)
        return ready,outputs,timings
    finally:
        process.stdin.close()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()


def verify_reference(checkpoint,fixtures,outputs,questions):
    """Compare native/tokenizer/ONNX against official full-precision PyTorch.

    All three questions and varying utterance lengths. This
    catches slot ordering, tokenization, padding and BOOL adapter errors.
    """
    import numpy as np
    import torch
    from laya.agent import Agent
    from laya.common import build_sequence,collate_items
    torch.set_num_threads(4)
    agent=Agent(str(checkpoint),compile=False,device='cpu')
    agent.model.eval()
    maximum=0;compared=0
    indices=[0,2,10,12,24,36,48,60,72,84,96,108,120,135]
    with torch.inference_mode():
        for index in indices:
            row=fixtures[index];items=[]
            for question in questions:
                q=dict(t='choice',ins=question['instructions'],crit=question['options'])
                ids,markers=build_sequence(agent.tok,row['text'],q)
                items.append(dict(ids=ids,markers=markers,qtype=0))
            batch=collate_items([items],agent.tok.pad_token_id)
            logits,_=agent.model(batch['input_ids'],batch['attention_mask'],batch['marker_pos'],batch['marker_mask'],batch['qtype'])
            for qi,question in enumerate(questions):
                native=np.asarray(outputs[index]['logits'][question['id']])
                reference=logits[qi,:len(native)].numpy()
                diff=float(np.max(np.abs(native-reference)))
                maximum=max(maximum,diff)
                if not np.allclose(native,reference,atol=.003,rtol=.001):
                    raise ValueError(f'Native/reference parity failed for {row["id"]}/{question["id"]}: {diff}')
                if int(native.argmax())!=int(reference.argmax()):raise ValueError('Native/reference decision mismatch')
                compared+=1
    return dict(backend='official laya 0.3.24 PyTorch CPU',comparedQuestions=compared,maxAbsoluteLogitDifference=maximum,passed=True)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--package',type=pathlib.Path,required=True)
    parser.add_argument('--checkpoint',type=pathlib.Path,help='Build-time official parity validation')
    parser.add_argument('--calibrate',action='store_true')
    parser.add_argument('--reuse-native',action='store_true',help='Reuse a matching test-owned native result cache after a parity harness repair')
    parser.add_argument('--report',type=pathlib.Path,required=True)
    args=parser.parse_args();package=args.package.resolve()
    fixtures=json.loads(FIXTURES.read_text());questions=json.loads(QUESTIONS.read_text())
    assert len(fixtures)>=100 and len(set(row['id'] for row in fixtures))==len(fixtures)
    cache=args.report.with_suffix('.native.json')
    signature={str(path):hashlib.sha256(path.read_bytes()).hexdigest() for path in [FIXTURES,QUESTIONS,package/'localflow-laya',package/'laya.onnx',package/'tokenizer/tokenizer.json']}
    if args.reuse_native and cache.exists():
        saved=json.loads(cache.read_text())
        if saved['signature']!=signature:raise ValueError('Stale native result cache')
        ready,outputs,timings=saved['ready'],saved['outputs'],saved['timings']
    else:
        ready,outputs,timings=run_native(package,fixtures)
        args.report.parent.mkdir(parents=True,exist_ok=True)
        cache.write_text(json.dumps(dict(signature=signature,ready=ready,outputs=outputs,timings=timings)))
    policies={};summary={}
    for question in questions:
        name=question['id'];labels=list(question['options']);samples=[]
        for row,reply in zip(fixtures,outputs):
            value=('B' if row['requiresMoreSpeech'] else 'A') if name=='requires_more_speech' else row[name]
            samples.append(dict(logits=reply['logits'][name],target=labels.index(value),split=row['split']))
        training=[s for s in samples if s['split']=='calibration'];heldout=[s for s in samples if s['split']=='evaluation']
        policy=calibrate(training)
        heldout_score=score(heldout,policy)
        # Fixed release quality gate. The threshold is fitted ONLY on calibration.
        policy['enabled']=bool(policy['enabled'] and heldout_score['accepted']>=4 and heldout_score['selectiveAccuracy']>=.95)
        policies[name]=policy
        summary[name]=dict(calibration=score(training,policy),evaluation=heldout_score,policy=policy)
    report=dict(checkpoint='convaiinnovations/laya',revision='55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851',
                fixtureSHA256=hashlib.sha256(FIXTURES.read_bytes()).hexdigest(),fixtureCount=len(fixtures),
                questionsSHA256=hashlib.sha256(QUESTIONS.read_bytes()).hexdigest(),
                metrics=dict(**ready,warmP50Milliseconds=statistics.median(timings[1:]),
                             warmP95Milliseconds=sorted(timings[1:])[math.ceil(.95*len(timings[1:]))-1],
                             firstInferenceMilliseconds=timings[0],peakResidentBytes=max(o['residentBytes'] for o in outputs)),
                questions=summary)
    if args.checkpoint:report['parity']=verify_reference(args.checkpoint.resolve(),fixtures,outputs,questions)
    if args.calibrate:
        if not report.get('parity',{}).get('passed'):raise ValueError('Calibration install requires official parity validation')
        (package/'calibration.json').write_text(json.dumps(policies,indent=2)+'\n')
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))

if __name__=='__main__':main()
