"""Sequential evaluation: only one Qwen process/model resident at a time."""
import pathlib,subprocess,os,json,time
root=pathlib.Path(__file__).resolve().parents[2];results=[]
commands=[
 ('native-optimized',['python3','Evaluation/System2/benchmark_runtime.py','--runtime','native','--samples','5'],{}),
 ('python-optimized',['python3','Evaluation/System2/benchmark_runtime.py','--runtime','python','--samples','5'],{}),
 ('model-108',['swift','test','--skip-build','--filter','PlannerBenchmarkTests.testModelBacked108FirstPlansAndSafetyOptIn'],{'LOCALFLOW_PLANNER_MODEL':str(root/'.build/system2/candidate'),'LOCALFLOW_PLANNER_EXECUTABLE':str(root/'.build/system2/swift/release/localflow-qwen'),'LOCALFLOW_PLANNER_BENCHMARK_OUTPUT':str(root/'Evaluation/System2/model-108.json')}),
 ('missions-24',['swift','test','--skip-build','--filter','PlannerBenchmarkTests.testModelBackedIterativeMissionsOptIn'],{'LOCALFLOW_PLANNER_MODEL':str(root/'.build/system2/candidate'),'LOCALFLOW_PLANNER_EXECUTABLE':str(root/'.build/system2/swift/release/localflow-qwen'),'LOCALFLOW_PLANNER_MISSIONS_OUTPUT':str(root/'Evaluation/System2/missions-24.json')}),
 ('thinking-24',['swift','test','--skip-build','--filter','PlannerBenchmarkTests.testModelBacked108FirstPlansAndSafetyOptIn'],{'LOCALFLOW_PLANNER_MODEL':str(root/'.build/system2/candidate'),'LOCALFLOW_PLANNER_EXECUTABLE':str(root/'.build/system2/swift/release/localflow-qwen'),'LOCALFLOW_PLANNER_BENCHMARK_OUTPUT':str(root/'Evaluation/System2/thinking-24.json'),'LOCALFLOW_PLANNER_THINKING':'1','LOCALFLOW_PLANNER_CASE_IDS':','.join(['complex-%02d'%i for i in range(1,8)]+['memory-%02d'%i for i in range(1,7)]+['safety-%02d'%i for i in [1,2,3,4,5,6,7,9,17]]+['failure-05','failure-13'])}),
 ('real-read-only',['swift','test','--skip-build','--filter','PlannerBenchmarkTests.testRealReadOnlyIterativePlansAndRuntimeCancellationOptIn'],{'LOCALFLOW_PLANNER_MODEL':str(root/'.build/system2/candidate'),'LOCALFLOW_PLANNER_EXECUTABLE':str(root/'.build/system2/swift/release/localflow-qwen'),'LOCALFLOW_PLANNER_LIVE_OUTPUT':str(root/'Evaluation/System2/real-read-only.json')})]
for name,cmd,extra in commands:
 print('START',name,flush=True);start=time.monotonic()
 with open(root/('Evaluation/System2/'+name+'.log'),'w') as f:
  r=subprocess.run(cmd,cwd=root,env=dict(os.environ,**extra),stdout=f,stderr=subprocess.STDOUT)
 results.append({'name':name,'exit':r.returncode,'seconds':time.monotonic()-start})
 (root/'Evaluation/System2/evaluation-runs.json').write_text(json.dumps(results,indent=2)+'\n')
 print('END',name,r.returncode,flush=True)
 if r.returncode:raise SystemExit(r.returncode)
