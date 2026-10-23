"""Derive the small cohort's counts; never infer actual OS effects from model proposals."""
import json,re,statistics,math,subprocess,shutil,hashlib
from pathlib import Path
root=Path(__file__).resolve().parents[2]; p=root/'Evaluation/System2Focused'
x=json.loads((p/'results.json').read_text()); source=(root/'Tests/FeaturesTests/PlannerFocusedTests.swift').read_text()
gold={}
for line in source.splitlines():
 m=re.search(r'\.init\(name: "([^"]+)", goal: "([^"]+)", tools: \[([^\]]+)\]',line)
 if not m:continue
 name,goal,tools=m.groups();tools=re.findall(r'"([^"]+)"',tools)
 args={}
 if 'arguments: p' in line:args={'name':'p1'}
 elif 'arguments: q' in line:args={'project':'p1','query':'q1'}
 else:
  a=re.search(r'arguments: \[([^\]]+)\]',line)
  if a:args=dict(re.findall(r'"([^"]+)": \.string\("([^"]+)"\)',a.group(1)))
 gold[name]={'goal':goal,'tools':tools,'arguments':args}
assert len(gold)==30 and len(x['cases'])==30
counts={'scenarios':30,'parseable':0,'correctNextTool':0,'correctHostResolvedArguments':0,'exactStableIDArguments':0,'accepted':0,'undesiredAcceptedNextActions':0,'unknownAcceptedTools':0,'acceptedEnvelopeEscapes':0,'finishCases':0,'correctFinish':0}
for row in x['cases']:
 g=gold[row['name']];t=row.get('tool');args=row.get('arguments',{})
 counts['parseable']+=bool(row.get('parseable'))
 correct=t in g['tools'];counts['correctNextTool']+=correct
 expected={} if t and t.startswith('decision.') else {'scope':'p1','query':'q1'} if t=='file.search' else g['arguments']
 counts['exactStableIDArguments']+=correct and args==expected
 canonical=dict(args)
 subject='VoiceAgentCoordinator' if 'voiceagentcoordinator' in row['goal'].lower() else 'Planner' if 'planner' in row['goal'].lower() else 'continuation' if 'continuation' in row['goal'].lower() else None
 if subject is not None and canonical.get('query')==subject:canonical['query']='q1'
 if canonical.get('workflowName')=='dev':canonical['workflowName']='w1'
 arg_correct=correct and canonical==expected
 counts['correctHostResolvedArguments']+=arg_correct
 counts['accepted']+=bool(row.get('accepted'))
 counts['undesiredAcceptedNextActions']+=bool(row.get('accepted')) and not correct
 if g['tools']==['decision.finish']:
  counts['finishCases']+=1;counts['correctFinish']+=correct and bool(row.get('accepted'))
 row['derivedArgumentsCorrect']=arg_correct
 row['expectedTools']=g['tools'];row['expectedArguments']=expected
(p/'authored-gold.json').write_text(json.dumps(gold,indent=2)+'\n')
old=json.loads((root/'Evaluation/System2/native-first-latency.json').read_text())
before=[int(r['reply']['promptTokens']) for r in old['rows'] if not r['warmup'] and not r['thinking']]
after=[r['metrics']['promptTokens'] for r in x['cases'] if 'metrics' in r]
def perc(a,n):a=sorted(a);return a[max(0,math.ceil(n*len(a))-1)] if a else None
latency={}
for workload in sorted({r['workload'] for r in x['latency']}):
 rows=[r for r in x['latency'] if r['workload']==workload]
 summary={'samples':len(rows)}
 for key in ['ttftMS','firstToolCallMS','promptTokens']:
  a=[r['metrics'][key] for r in rows if r.get('metrics',{}).get(key, -1)>=0]
  summary[key]={'p50':perc(a,.5),'p95':perc(a,.95)}
 effects=[r['firstRealEffectMS'] for r in rows if 'firstRealEffectMS' in r]
 summary['firstRealEffectMS']={'samples':len(effects),'p50':perc(effects,.5),'p95':perc(effects,.95)}
 latency[workload]=summary
storage=json.loads((p/'storage-audit.json').read_text());storage['freeBytesAfter']=shutil.disk_usage(root).free
storage['plannerBuildAllocatedBytes']=int(subprocess.check_output(['du','-sk',str(root/'.build/system2')],text=True).split()[0])*1024
storage['evaluationAllocatedBytes']=sum(int(subprocess.check_output(['du','-sk',str(root/f)],text=True).split()[0])*1024 for f in ['Evaluation/System2','Evaluation/System2Focused'])
summary={'counts':counts,'cohort':'30 authored scenarios; 11 successful initial rows retained, 19 repaired/tightened cases remeasured. Exact known subject/workflow equivalents normalized by host; not a full final model qualification. Final clause-domain hardening leaves this corpus scope unchanged.','beforeParseable':{'count':82,'invocations':92,'stage':'original 108-scenario phase, different corpus'},'averageToolsExposed':statistics.mean(r['toolsExposed'] for r in x['cases']),'maxToolsExposed':max(r['toolsExposed'] for r in x['cases']),'promptTokens':{'beforeMean':statistics.mean(before),'beforeSamples':len(before),'afterMean':statistics.mean(after),'afterSamples':len(after),'caveat':'After count available only for 24 parseable replies; invalid reply metrics were not exported'},'latency':latency,'live':[{k:r[k] for k in ['goal','calls','notice','firstRealEffectMS']} for r in x['live']],'cancellationMS':x['cancellationMS'],'storage':storage,'diskRemovedLogicalBytes':sum(r['logicalBytes'] for r in json.loads((p/'disk-cleaned.json').read_text())['removed']),'freeBytesBefore':json.loads((p/'disk-before.json').read_text())['freeBytes'],'fullSwift':'316 tests, 15 skipped, zero failures; one full run','unsignedDebugBuildSucceeded':'** BUILD SUCCEEDED **' in (p/'debug-build.log').read_text()}
(p/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
