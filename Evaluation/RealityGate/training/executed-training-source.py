"""Pinned Laya evaluation and official RLCD + CE specialization recipe.

Training primitive attribution: NandhaKishorM/laya (Apache-2.0), revision
2e4d9c87e8b1621deb344eac7de5c7258f32f849,
notebooks/laya_finetune_typed_decisions_mps.py. No upstream publishing cells.
Splits here are immutable and separate; test data never enters training/calibration.
"""
import argparse
import hashlib
import json
import math
import os
import random
import resource
import time
from pathlib import Path

import numpy as np
import torch
from safetensors.torch import load_file, save_file
from transformers import AutoTokenizer
from laya.common import QTYPES, build_model, build_sequence, proper_reward, render_options
from decisions import QUESTIONS, options
from metrics import accumulation_window, fit_temperature, summarize, target_coverage

ROOT = Path(__file__).resolve().parent
SEED = 421322

def sha(path):
    h = hashlib.sha256()
    with open(path,"rb") as f:
        for part in iter(lambda:f.read(1024*1024), b""): h.update(part)
    return h.hexdigest()

def read_split(name):
    manifest = json.loads((ROOT / "split-manifest.json").read_text())
    path = ROOT / f"{name}.jsonl"
    assert sha(path) == manifest["splits"][name]["sha256"], "Frozen dataset hash changed"
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    assert all(row["split"] == name for row in rows)
    return rows

def tokenize(tokenizer, cfg, rows):
    items = []
    for row in rows:
        for name, question in QUESTIONS.items():
            seq, markers = build_sequence(tokenizer,row["state"],
                {"t":question["type"],"ins":question["instructions"],"crit":question["criteria"]},
                cfg["max_len"],cfg["head_max_len"])
            choices = options(question)
            assert len(markers) == len(choices), f"Truncated decision options: {row['id']}/{name}"
            gold = choices.index(row["labels"][name])
            items.append({"ids":seq,"markers":markers,"qtype":QTYPES[question["type"]],
                "target":[float(i==gold) for i in range(len(choices))],"goldIndex":gold,
                "id":row["id"],"question":name,"split":row["split"]})
    return items

def collate(items, pad):
    length, k = max(len(i["ids"]) for i in items), max(len(i["markers"]) for i in items)
    ids = torch.full((len(items),length),pad,dtype=torch.long)
    attention = torch.zeros_like(ids)
    positions = torch.zeros((len(items),k),dtype=torch.long)
    mask = torch.zeros_like(positions,dtype=torch.bool)
    target = torch.zeros_like(positions,dtype=torch.float32)
    for row,item in enumerate(items):
        n,m = len(item["ids"]),len(item["markers"])
        ids[row,:n] = torch.tensor(item["ids"]); attention[row,:n] = 1
        positions[row,:m] = torch.tensor(item["markers"]); mask[row,:m] = True
        target[row,:m] = torch.tensor(item["target"])
    return ids,attention,positions,mask,torch.tensor([i["qtype"] for i in items]),target

def synchronize(device):
    if device == "mps": torch.mps.synchronize()
    elif device == "cuda": torch.cuda.synchronize()

def load(path,device,dtype):
    start = time.perf_counter()
    cfg = json.loads((path/"rl_agent_config.json").read_text())
    # max_len stays at the public checkpoint's configured value. Never truncate options.
    tokenizer = AutoTokenizer.from_pretrained(path/"tokenizer",local_files_only=True)
    model = build_model(cfg,encoder_dir=path/"encoder")
    model.load_state_dict(load_file(str(path/"model.safetensors")),strict=True)
    model = model.to(device=device,dtype=getattr(torch,dtype)).eval()
    synchronize(device)
    return model,tokenizer,cfg,(time.perf_counter()-start)*1000

def predict(model, items, tokenizer, device):
    inputs = [x.to(device) for x in collate(items,tokenizer.pad_token_id)[:5]]
    synchronize(device); start = time.perf_counter()
    with torch.inference_mode(): logits,_ = model(*inputs)
    synchronize(device); elapsed = (time.perf_counter()-start)*1000
    values = logits.float().cpu().tolist()
    return [{k:item[k] for k in ("id","question","split","goldIndex")} |
            {"logits":values[index][:len(item["markers"])]} for index,item in enumerate(items)], elapsed

def report_predictions(predictions):
    report = {}
    for name in QUESTIONS:
        cal = [r for r in predictions if r["split"] == "calibration" and r["question"] == name]
        test = [r for r in predictions if r["split"] == "test" and r["question"] == name]
        temperature = fit_temperature(cal)
        report[name] = {"temperature":temperature,"calibration":summarize(cal,temperature),
            "testRaw":summarize(test),"testCalibrated":summarize(test,temperature),
            "selectiveCoverage":target_coverage(cal,test,temperature)}
    risk = [r for r in predictions if r["split"] == "test" and r["question"] == "risk"]
    accepted = [r for r in risk if int(np.argmax(r["logits"])) != 2]
    from metrics import wilson_lower
    correct = sum(r["goldIndex"] != 2 for r in accepted)
    report["autoExecutableRisk"] = {"accepted":len(accepted), "precision":correct/len(accepted) if accepted else None,
        "precision95LowerBound":wilson_lower(correct,len(accepted)),"productionGateEnabled":False}
    return report

def evaluate(args):
    torch.set_num_threads(args.threads)
    model,tokenizer,cfg,cold = load(args.model,args.device,args.dtype)
    items = tokenize(tokenizer,cfg,read_split("calibration")+read_split("test"))
    predictions,timings = [],[]
    for start in range(0,len(items),len(QUESTIONS)):
        result, elapsed = predict(model,items[start:start+len(QUESTIONS)],tokenizer,args.device)
        predictions += result; timings.append(elapsed)
        if len(timings)%20 == 0: print(f"Evaluated {len(timings)} utterances",flush=True)
    args.output.mkdir(parents=True,exist_ok=True)
    (args.output/"predictions.json").write_text(json.dumps(predictions)+"\n")
    report = {"model":str(args.model),"device":args.device,"dtype":args.dtype,"threads":args.threads,
        "checkpointSHA256":sha(args.model/"model.safetensors"),
        "questionsSHA256":sha(ROOT/"decisions.py"), "datasetManifestSHA256":sha(ROOT/"split-manifest.json"),
        "performance":{"coldLoadMilliseconds":cold,"firstInferenceMilliseconds":timings[0],
            "warmP50Milliseconds":float(np.percentile(timings[1:],50)),
            "warmP95Milliseconds":float(np.percentile(timings[1:],95)),
            "decisionQuestionsPerUtterance":len(QUESTIONS),"utterances":len(timings),
            "peakRSSBytes":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * (1 if os.uname().sysname=="Darwin" else 1024),
            "mpsAllocatedBytes":torch.mps.current_allocated_memory() if args.device=="mps" else None,
            "mpsDriverBytes":torch.mps.driver_allocated_memory() if args.device=="mps" else None,
            "modelDiskBytes":sum(p.stat().st_size for p in args.model.rglob("*") if p.is_file())},
        "questions":report_predictions(predictions)}
    (args.output/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report["performance"],indent=2),flush=True)

def train(args):
    random.seed(SEED); np.random.seed(SEED); torch.manual_seed(SEED)
    torch.set_num_threads(args.threads)
    model,tokenizer,cfg,cold = load(args.model,args.device,"float32")
    items = tokenize(tokenizer,cfg,read_split("train"))
    if args.head_only:
        for parameter in model.encoder.parameters(): parameter.requires_grad_(False)
    else:
        model.encoder.gradient_checkpointing_enable(gradient_checkpointing_kwargs={"use_reentrant":False})
    model.head_checkpointing = True; model.train()
    groups = [{"params":[p for n,p in model.named_parameters() if p.requires_grad and n.startswith("encoder.")],"lr":2.5e-5},
              {"params":[p for n,p in model.named_parameters() if p.requires_grad and not n.startswith("encoder.")],"lr":1e-4}]
    optimizer = torch.optim.AdamW(groups,weight_decay=.01)
    total = args.max_updates or math.ceil(len(items)/args.grad_accum)*args.epochs
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(optimizer,T_max=total,eta_min=1e-6)
    args.output.mkdir(parents=True,exist_ok=True)
    config = {"experiment":"localflow-laya-v1","baseModel":str(args.model),"baseSHA256":sha(args.model/"model.safetensors"),
        "baseProvenance":json.loads((args.model/"provenance.json").read_text()) if (args.model/"provenance.json").exists() else None,
        "seed":SEED,"datasetManifestSHA256":sha(ROOT/"split-manifest.json"),"questionsSHA256":sha(ROOT/"decisions.py"),
        "pipelineSHA256":sha(ROOT/"model_pipeline.py"),"metricsSHA256":sha(ROOT/"metrics.py"),
        "recipeRevision":"2e4d9c87e8b1621deb344eac7de5c7258f32f849","device":args.device,
        "headOnly":args.head_only,"maxUpdates":args.max_updates,"epochs":args.epochs,"gradAccum":args.grad_accum,
        "torch":torch.__version__,"microBatch":1,"loss":"official RLCD four noisy projections + one-hot CE",
        "optimizer":{"name":"AdamW","encoderLearningRate":2.5e-5,"headLearningRate":1e-4,"weightDecay":.01},
        "scheduler":{"name":"CosineAnnealingLR","updates":total,"minimumLearningRate":1e-6},
        "gradientNormClip":1.,"sigmaStart":.4,"sigmaEnd":.1,"projections":4,"sphericalWeight":.75,"rankedWeight":1.,
        "numericBoundary":"Seeded MPS run; bitwise repeatability across GPU/software versions is not guaranteed.",
        "limitation":"One-hot assistant-reviewed labels, not independent teacher soft distributions."}
    (args.output/"training-config.json").write_text(json.dumps(config,indent=2)+"\n")
    optimizer.zero_grad(set_to_none=True); updates=0; micro=0; losses=[]; began=time.perf_counter()
    with open(args.output/"training-metrics.jsonl","w",buffering=1) as log:
        for epoch in range(args.epochs):
            random.Random(SEED+epoch).shuffle(items)
            sigma = .4 + (.1-.4)*epoch/max(1,args.epochs-1)
            for index,item in enumerate(items):
                ids,attention,positions,mask,qtype,target = [x.to(args.device) for x in collate([item],tokenizer.pad_token_id)]
                logits,activation = model(ids,attention,positions,mask,qtype)
                k = mask.sum(-1,keepdim=True).float()
                eps = torch.randn((4,)+logits.shape,device=args.device)*sigma*mask
                eps = (eps-eps.sum(-1,keepdim=True)/k)*mask
                noisy = logits.detach().unsqueeze(0)+eps
                with torch.no_grad():
                    reward = proper_reward(torch.softmax(noisy.masked_fill(~mask,-1e4),-1),target.unsqueeze(0),qtype,mask,w_sph=.75,w_rps=1.)
                    advantage = reward-reward.mean(0,keepdim=True)
                    advantage = advantage/(advantage.std()+1e-6)
                logp = -(((noisy-logits.unsqueeze(0))**2)*mask).sum(-1)/(2*sigma**2)
                rl = -(advantage*logp).mean()
                ce = -(target*torch.log_softmax(logits.masked_fill(~mask,-1e4),-1)).sum(-1).mean()
                window_size, flush = accumulation_window(index,len(items),args.grad_accum)
                loss = (rl+ce+0*activation.sum())/window_size
                if not torch.isfinite(loss): raise RuntimeError("Non-finite training loss")
                loss.backward(); losses.append(float(loss.detach().cpu())*window_size); micro+=1
                if flush:
                    torch.nn.utils.clip_grad_norm_(model.parameters(),1.)
                    optimizer.step();scheduler.step();optimizer.zero_grad(set_to_none=True);updates+=1
                    record = {"update":updates,"microSteps":micro,"epoch":epoch,"meanLoss":sum(losses)/len(losses),
                        "elapsedSeconds":time.perf_counter()-began}
                    log.write(json.dumps(record)+"\n");print(record,flush=True);losses=[]
                    if args.max_updates and updates>=args.max_updates: break
            if args.max_updates and updates>=args.max_updates: break
    # One final checkpoint, no repeated copies. Compatibility matches official SDK.
    weights = {name:value.detach().half().cpu().contiguous() for name,value in model.state_dict().items()}
    save_file(weights,str(args.output/"model.safetensors"))
    model.encoder.config.save_pretrained(args.output/"encoder");tokenizer.save_pretrained(args.output/"tokenizer")
    cfg.pop("temperature_by_options",None);cfg["temperature"]=[1.,1.,1.]
    (args.output/"rl_agent_config.json").write_text(json.dumps(cfg,indent=2)+"\n")
    metadata = {"updatesCompleted":updates,"microSteps":micro,"elapsedSeconds":time.perf_counter()-began,
        "status":"smoke-trained; not production qualified" if args.max_updates else "full configured training completed; not production qualified",
        "checkpointSHA256":sha(args.output/"model.safetensors"),"calibration":"Not embedded. Evaluate fits per-decision calibration on separate calibration split.",
        "testUsedInTraining":False,"peakRSSBytes":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss}
    (args.output/"training-status.json").write_text(json.dumps(metadata,indent=2)+"\n")
    print(metadata,flush=True)

if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("operation",choices=["evaluate","train"])
    parser.add_argument("--model",type=Path,required=True);parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--device",choices=["cpu","mps","cuda"],default="cpu")
    parser.add_argument("--dtype",choices=["float32","float16"],default="float32")
    parser.add_argument("--threads",type=int,default=4);parser.add_argument("--epochs",type=int,default=2)
    parser.add_argument("--grad-accum",type=int,default=32);parser.add_argument("--max-updates",type=int,default=0)
    parser.add_argument("--head-only",action="store_true");args=parser.parse_args()
    if args.device=="mps" and not torch.backends.mps.is_available(): raise RuntimeError("MPS unavailable; no silent CPU substitution")
    (evaluate if args.operation=="evaluate" else train)(args)
