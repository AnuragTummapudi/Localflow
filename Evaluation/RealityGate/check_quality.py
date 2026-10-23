"""Fail visibly when measured reality targets are not met. Never repairs metrics."""
import argparse
import json
from pathlib import Path

def check(model, asr, live):
    gates=[]
    def add(name,passed,evidence): gates.append({"name":name,"passed":bool(passed),"evidence":evidence})
    add("exact ASR slots",asr["incorrectInvocations"]==0,asr)
    intent=model["questions"]["intent"]["selectiveCoverage"]["0.95"]["testAtSupportedGate"]
    add("statistically supported high-precision intent coverage",intent["accepted"]>0 and (intent["accuracy95LowerBound"] or 0)>=.95,intent)
    more=model["questions"]["more_speech"]["testCalibrated"]
    add("more-speech precision >=95%",(more.get("precision") or 0)>=.95,{k:more.get(k) for k in ["precision","recall","predictedPositiveCount","positiveCount"]})
    risk=model["questions"]["autoExecutableRisk"]
    add("statistically supported auto-executable risk precision >=99%",(risk.get("precision95LowerBound") or 0)>=.99,risk)
    performance=model["performance"]
    add("preferred warm p50 <200 ms",performance["warmP50Milliseconds"]<200,performance["warmP50Milliseconds"])
    add("preferred warm p95 <300 ms",performance["warmP95Milliseconds"]<300,performance["warmP95Milliseconds"])
    add("complete real microphone/native sequence",all(s["status"]=="VERIFIED" for s in live["steps"]),live["steps"])
    return {"recommendation":"READY FOR SYSTEM-2 PLANNER" if all(g["passed"] for g in gates) else "NOT READY FOR SYSTEM-2 PLANNER",
        "gates":gates,"note":"Latency values are preferred engineering targets. Statistical gates cannot be enabled by a small perfect sample. Native request acceptance is not verification."}

if __name__=="__main__":
    parser=argparse.ArgumentParser()
    for name in ["model-report","asr-summary","live-results","output"]:parser.add_argument("--"+name,type=Path,required=True)
    args=parser.parse_args()
    result=check(json.loads(args.model_report.read_text()),json.loads(args.asr_summary.read_text())["after"],json.loads(args.live_results.read_text()))
    args.output.write_text(json.dumps(result,indent=2)+"\n")
    print(result["recommendation"])
    for gate in result["gates"]: print(("PASS " if gate["passed"] else "FAIL ")+gate["name"])
    raise SystemExit(0 if all(g["passed"] for g in result["gates"]) else 1)
