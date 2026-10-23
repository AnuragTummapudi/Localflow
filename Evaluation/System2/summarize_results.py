"""Derive metrics from frozen evidence. Never equate simulated coverage with live OS completion."""
import json,math,statistics,pathlib,collections
root=pathlib.Path(__file__).resolve().parent
read=lambda name:json.loads((root/name).read_text())
def percentile(values,q):
    values=sorted(values);return values[math.ceil(q*len(values))-1]
def latency(name):
    d=read(name);out={'load':d['load'],'rssSemantics':d['rssSemantics'],'modes':{}}
    for mode in [False,True]:
        rows=[r for r in d['rows'] if r['thinking']==mode and not r['warmup']]
        result={'samples':len(rows),'workloads':{}}
        for key in ['ttftMS','firstToolCallMS','planMS']:
            v=[float(r['reply'][key]) for r in rows]
            result[key]={'p50':percentile(v,.5),'p95':percentile(v,.95)}
        result['tokensPerSecondMedian']=statistics.median(float(r['reply']['tokensPerSecond']) for r in rows)
        for key in ['rssBytes','mlxActiveBytes','mlxPeakBytes']:
            v=[int(r['reply'][key]) for r in rows];result[key]={'min':min(v),'max':max(v)}
        for case in ['one','three','five','replan']:
            r=[x['reply'] for x in rows if x['case']==case]
            result['workloads'][case]={k:{'p50':percentile([float(x[k]) for x in r],.5),'p95':percentile([float(x[k]) for x in r],.95)} for k in ['ttftMS','firstToolCallMS','planMS']}
            result['workloads'][case]['emittedCallsRange']=[min(x.get('output','').count('</tool_call>') for x in r),max(x.get('output','').count('</tool_call>') for x in r)]
        out['modes']['thinking' if mode else 'nonThinking']=result
    return out
canonical={'editor.openProject':'project.open','editor.openFile':'project.openFile','file.open':'project.openFile','file.search':'project.search','editor.revealSymbol':'project.search','service.status':'service.wait'}
def tool(value):return canonical.get(value,value)
def project(value):return 'LocalFlow' if value.lower().strip() in ['localflow','local flow','lf'] else value.strip()
def args(value):
    value=dict(value)
    if 'scope' in value:value['project']=value.pop('scope')
    for k in ['project','name']:
        if isinstance(value.get(k),str):value[k]=project(value[k])
    if value.get('preferredEditor')=='com.microsoft.VSCode':value.pop('preferredEditor')
    if value.get('timeout')==30:value.pop('timeout')
    if value.get('line')==1:value.pop('line')
    return value
allrows=read('model-108-final.json')['scenarios'];rows=[x for x in allrows if x['invoked']];gold={x['id']:x for x in read('scenarios.json')}
benchmark={'scenarios':len(allrows),'invocations':len(rows),'routingCorrect':sum(x['routingCorrect'] for x in allrows),'toolExact':sum(x.get('toolExact',False) for x in rows),'argumentsExact':sum(x.get('argumentsExact',False) for x in rows),'valid':sum(x.get('valid',False) for x in rows),'parsedPlans':sum(isinstance(x.get('plan'),dict) for x in rows),'unparsedErrors':sum('error' in x for x in rows),'detectedUnknownToolPlans':sum(x.get('hallucinatedTool',False) for x in rows),'confirmationChallenges':sum(x.get('confirmationChallenges',0) for x in rows)}
benchmark['policyEquivalentToolMatch']=sum(tool((x.get('plan') or {}).get('steps',[{}])[0].get('tool'))==tool(gold[x['id']]['expectedTool']) for x in rows)
benchmark['policyEquivalentArgumentMatch']=sum(args((x.get('plan') or {}).get('steps',[{}])[0].get('arguments',{}))==args(gold[x['id']]['expectedArguments']) and tool((x.get('plan') or {}).get('steps',[{}])[0].get('tool'))==tool(gold[x['id']]['expectedTool']) for x in rows)
benchmark['categories']={category:{'count':len(r),'toolExact':sum(x.get('toolExact',False) for x in r),'argumentsExact':sum(x.get('argumentsExact',False) for x in r),'valid':sum(x.get('valid',False) for x in r)} for category in ['COMPLEX','MEMORY','SAFETY','FAILURE'] for r in [[x for x in rows if x['category']==category]]}
think=read('thinking-24.json')['scenarios'];non={x['id']:x for x in rows}
comparison={mode:{'count':len(r),'toolExact':sum(x.get('toolExact',False) for x in r),'argumentsExact':sum(x.get('argumentsExact',False) for x in r),'valid':sum(x.get('valid',False) for x in r)} for mode,r in [('thinking',think),('nonThinking',[non[x['id']] for x in think])]}
missions=read('missions-24.json')['missions'];audits=[]
for row in missions:
    expected=set(map(tool,row['required']));allowed=expected|{'project.resolve'}
    if 'workflow.run' in expected:allowed.add('workflow.list')
    extras=[];wrong=[];service_verified=False;ready_violation=False;seen=set();duplicates=[]
    for receipt in row['receipts']:
        t=tool(receipt['tool']);a=args(receipt.get('arguments',{}));successful=receipt['status'] in ['verified','unverified']
        if successful:
            if t not in allowed:extras.append(receipt['stepID'])
            if any(k in a and project(a[k])!='LocalFlow' for k in ['name','project']):wrong.append(receipt['stepID'])
            signature=(t,json.dumps(a,sort_keys=True))
            if signature in seen:duplicates.append(receipt['stepID'])
            seen.add(signature)
        if receipt['tool'] in ['service.wait','service.status'] and receipt['status']=='verified' and receipt['data'].get('url')=='http://127.0.0.1:18991':service_verified=True
        if receipt['tool']=='web.open_url' and receipt['arguments'].get('url','').startswith('http://127.0.0.1:18991') and not service_verified:ready_violation=True
    terminal=row['notice'] in ['Done','Planner finished']
    # Independent strict audit of COMPLEX goals: full coverage, clean terminal, correct target,
    # no unrelated delivered steps. Precondition reads are allowed, but are separately counted.
    complete=row['id']<=18 and row['requiredReached']==len(row['required']) and terminal and not extras and not wrong and not duplicates
    audits.append({'id':row['id'],'strictComplexCompletion':complete,'unrelatedCompletedSteps':len(extras),'wrongProjectSteps':len(wrong),'duplicateCompletedSteps':len(duplicates),'readinessViolation':ready_violation})
mission_summary={'count':len(missions),'complexCount':18,'rawToolCoverageMetComplex':sum(x['missionComplete'] for x in missions[:18]),'strictComplexCompleted':sum(x['strictComplexCompletion'] for x in audits),'nativeCallsSimulated':sum(len(x['calls']) for x in missions),'unrelatedCompletedSteps':sum(x['unrelatedCompletedSteps'] for x in audits),'wrongProjectSteps':sum(x['wrongProjectSteps'] for x in audits),'duplicateCompletedSteps':sum(x['duplicateCompletedSteps'] for x in audits),'readinessViolations':sum(x['readinessViolation'] for x in audits),'benchmarkOnlyConfirmationGrants':sum(x['confirmationGrantsForMockedEffects'] for x in missions),'audits':audits,'completedSimulatedSteps':sum(r['status'] in ['verified','unverified'] for x in missions for r in x['receipts']),'stage':'Pre-token-filter iterative run, unchanged planner/executor behavior except terminal UI wording; actual recorded results, not rerun for this derivation','method':'Post-run strict tool/target/terminal audit; preparatory resolve and workflow.list before run allowed. Query semantic exactness and real OS completion not assessed; all effects simulated.'}
summary={'latencyPercentileMethod':'nearest rank, warmup excluded, 5 samples per workload/mode (20 pooled)','native':latency('native-first-latency.json'),'python':latency('python-first-latency.json'),'benchmark':benchmark,'modeComparison24':comparison,'modeComparisonCaveat':'Exploratory thinking subset from preceding helper run, compared with final non-thinking rows; not a final paired accuracy qualification','iterativeMissions':mission_summary,'realReads':read('installed-real-read-only-final.json'),'installation':read('installation-health.json')}
(root/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps({'benchmark':benchmark,'modeComparison24':comparison,'modeComparisonCaveat':'Exploratory thinking subset from preceding helper run, compared with final non-thinking rows; not a final paired accuracy qualification','missionSummary':{k:v for k,v in mission_summary.items() if k!='audits'}},indent=2))
