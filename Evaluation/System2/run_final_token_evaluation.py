"""Final token-boundary runtime: sequential, quiet benchmark and opt-in integration."""
import pathlib,subprocess,os,json,time
root=pathlib.Path(__file__).resolve().parents[2];results=[]
commands=[
 ('native-final',['python3','Evaluation/System2/benchmark_runtime.py','--runtime','native','--first-only','--samples','5'],{}),
 ('python-final',['python3','Evaluation/System2/benchmark_runtime.py','--runtime','python','--first-only','--samples','5'],{}),
 ('model-108-final',['swift','test','--skip-build','--filter','PlannerBenchmarkTests.testModelBacked108FirstPlansAndSafetyOptIn'],{'LOCALFLOW_PLANNER_MODEL':str(root/'.build/system2/candidate'),'LOCALFLOW_PLANNER_EXECUTABLE':str(root/'.build/system2/swift/release/localflow-qwen'),'LOCALFLOW_PLANNER_BENCHMARK_OUTPUT':str(root/'Evaluation/System2/model-108-final.json')}),
 ('installed-live-final',['swift','test','--skip-build','--filter','PlannerBenchmarkTests.testRealReadOnlyIterativePlansAndRuntimeCancellationOptIn'],{'LOCALFLOW_PLANNER_MODEL':str(pathlib.Path.home()/'Library/Application Support/LocalFlow/Models/qwen3.5-4b-4bit'),'LOCALFLOW_PLANNER_EXECUTABLE':str(pathlib.Path.home()/'Library/Application Support/LocalFlow/Models/qwen-runtime/localflow-qwen'),'LOCALFLOW_PLANNER_LIVE_OUTPUT':str(root/'Evaluation/System2/installed-real-read-only-final.json')})]
for name,cmd,extra in commands:
 print('START',name,flush=True);start=time.monotonic()
 with (root/('Evaluation/System2/'+name+'.log')).open('w') as f:r=subprocess.run(cmd,cwd=root,env=dict(os.environ,**extra),stdout=f,stderr=subprocess.STDOUT)
 results.append({'name':name,'exit':r.returncode,'seconds':time.monotonic()-start})
 (root/'Evaluation/System2/final-token-evaluation-runs.json').write_text(json.dumps(results,indent=2)+'\n');print('END',name,r.returncode,flush=True)
 if r.returncode:raise SystemExit(r.returncode)
