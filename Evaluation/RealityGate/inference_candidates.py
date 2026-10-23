"""Real ONNX CPU/CoreML EP/INT8 and direct Core ML experiments, never production installs."""
import argparse
import json
import os
import resource
import time
from pathlib import Path
import numpy as np
import onnxruntime as ort
from transformers import AutoTokenizer
from decisions import QUESTIONS
from model_pipeline import ROOT, collate, load, predict, read_split, report_predictions, sha, tokenize

def evaluate_onnx(args):
    cfg=json.loads((args.model/"rl_agent_config.json").read_text())
    tokenizer=AutoTokenizer.from_pretrained(args.model/"tokenizer",local_files_only=True)
    items=tokenize(tokenizer,cfg,read_split("calibration")+read_split("test"))
    args.output.mkdir(parents=True,exist_ok=True)
    settings=ort.SessionOptions();settings.intra_op_num_threads=4;settings.inter_op_num_threads=1
    settings.enable_profiling=True;settings.profile_file_prefix=str(args.output/"provider-profile")
    settings.log_severity_level=2
    providers=["CPUExecutionProvider"]
    if args.provider=="coreml":
        # The current export hits an ORT partition/shape-fusion axis failure with
        # default optimizations. Disable graph rewrites in this experiment only.
        settings.graph_optimization_level=ort.GraphOptimizationLevel.ORT_DISABLE_ALL
        if "CoreMLExecutionProvider" not in ort.get_available_providers(): raise RuntimeError("CoreML EP unavailable")
        providers=[("CoreMLExecutionProvider",{"ModelFormat":"MLProgram","MLComputeUnits":"ALL",
            "RequireStaticInputShapes":"0","EnableOnSubgraphs":"1"}),"CPUExecutionProvider"]
    start=time.perf_counter();session=ort.InferenceSession(str(args.onnx),sess_options=settings,providers=providers)
    cold=(time.perf_counter()-start)*1000
    names=[i.name for i in session.get_inputs()];types={i.name:i.type for i in session.get_inputs()}
    print({"inputs":types,"providers":session.get_providers(),"coldMilliseconds":cold},flush=True)
    predictions,timings=[],[]
    for start in range(0,len(items),len(QUESTIONS)):
        group=items[start:start+len(QUESTIONS)]
        batch=collate(group,tokenizer.pad_token_id)
        arrays=[x.numpy() for x in batch[:5]]
        canonical=dict(zip(["input_ids","attention_mask","marker_pos","marker_mask","qtype"],arrays))
        feed={name:canonical[name].astype(bool if types[name]=="tensor(bool)" else np.int64) for name in names}
        began=time.perf_counter();output=session.run(None,feed);timings.append((time.perf_counter()-began)*1000)
        logits=output[0]
        predictions += [{key:item[key] for key in ("id","question","split","goldIndex")} |
            {"logits":logits[i,:len(item["markers"])].tolist()} for i,item in enumerate(group)]
        if len(timings)%20==0: print("Evaluated",len(timings),"utterances",flush=True)
    profile=Path(session.end_profiling())
    events=json.loads(profile.read_text());placement={}
    for event in events:
        provider=event.get("args",{}).get("provider")
        if provider: placement[provider]=placement.get(provider,0)+1
    report={"modelSHA256":sha(args.onnx),"providerRequested":args.provider,"providersRegistered":session.get_providers(),
        "runtime":ort.__version__,"executedNodeEventsByProvider":placement,
        "performance":{"coldLoadMilliseconds":cold,"firstInferenceMilliseconds":timings[0],
            "warmP50Milliseconds":float(np.percentile(timings[1:],50)),"warmP95Milliseconds":float(np.percentile(timings[1:],95)),
            "peakRSSBytes":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss*(1 if os.uname().sysname=="Darwin" else 1024),
            "decisionQuestionsPerUtterance":len(QUESTIONS),"utterances":len(timings),
            "modelDiskBytes":args.onnx.stat().st_size + sum(p.stat().st_size for p in args.onnx.parent.glob(args.onnx.name+".data*"))},
        "questions":report_predictions(predictions)}
    (args.output/"predictions.json").write_text(json.dumps(predictions)+"\n")
    (args.output/"report.json").write_text(json.dumps(report,indent=2)+"\n")
    print(report["performance"],flush=True)

def quantize(args):
    import onnx
    from onnxruntime.quantization import QuantType, quantize_dynamic
    args.output.parent.mkdir(parents=True,exist_ok=True)
    started=time.perf_counter()
    # Official exporter recommends per-tensor dynamic INT8; per-channel showed large drift.
    # The old export has stale intermediate shape annotations (1028 vs 256).
    # Regenerate those annotations; operators, inputs, outputs and weights stay intact.
    metadata = onnx.load(str(args.onnx),load_external_data=False)
    metadata.graph.ClearField("value_info")
    input_path = args.onnx.with_name("quantization-input.onnx")
    onnx.save(metadata,str(input_path))
    quantize_dynamic(str(input_path),str(args.output),weight_type=QuantType.QInt8,per_channel=False,
        op_types_to_quantize=["MatMul","Gemm"],use_external_data_format=True)
    print({"seconds":time.perf_counter()-started,"sha256":sha(args.output)},flush=True)

def direct_coreml(args):
    import coremltools as ct
    import torch
    from coremltools.converters.mil.frontend.torch.torch_op_registry import register_torch_op
    from coremltools.converters.mil.frontend.torch.ops import _get_inputs, _make_fill_op
    from coremltools.converters.mil.mil import types
    # coremltools 9 lacks aten::new_ones. Use its existing new_full lowering
    # with the constant one, preserving integer vs float numeric mask values.
    @register_torch_op
    def new_ones(context, node):
        values = _get_inputs(context,node)
        value = np.bool_(True) if types.is_bool(values[0].dtype) else np.int32(1) if types.is_int(values[0].dtype) else np.float32(1)
        context.add(_make_fill_op(values[1],value,node.name))
    model,tokenizer,cfg,cold=load(args.model,"cpu","float32")
    # Bounded input contract for the specialization's five decisions. Test all lengths
    # afterwards; successful conversion alone is not accepted as answer parity.
    group=tokenize(tokenizer,cfg,read_split("calibration")[:1])
    inputs=collate(group,tokenizer.pad_token_id)[:5]
    class Wrapper(torch.nn.Module):
        def __init__(self,model): super().__init__();self.model=model
        def forward(self,ids,attention,positions,mask,qtype):
            return self.model(ids.long(),attention.bool(),positions.long(),mask.bool(),qtype.long())[0]
    wrapper=Wrapper(model).eval()
    with torch.no_grad(): traced=torch.jit.trace(wrapper,inputs,check_trace=False)
    length=ct.RangeDim(32,1024,default=inputs[0].shape[1])
    fields=[ct.TensorType(name="input_ids",shape=(5,length),dtype=np.int32),
            ct.TensorType(name="attention_mask",shape=(5,length),dtype=np.int32),
            ct.TensorType(name="marker_pos",shape=(5,14),dtype=np.int32),
            ct.TensorType(name="marker_mask",shape=(5,14),dtype=np.int32),
            ct.TensorType(name="qtype",shape=(5,),dtype=np.int32)]
    start=time.perf_counter()
    converted=ct.convert(traced,inputs=fields,convert_to="mlprogram",compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,compute_units=ct.ComputeUnit.ALL)
    converted.save(str(args.output))
    conversion_seconds=time.perf_counter()-start
    print({"conversionSeconds":conversion_seconds,"toolVersion":ct.__version__},flush=True)
    # Measure loading the saved Core ML artifact, not the PyTorch source load.
    start=time.perf_counter()
    converted=ct.models.MLModel(str(args.output),compute_units=ct.ComputeUnit.ALL)
    coreml_cold=(time.perf_counter()-start)*1000
    # Conversion success is followed by the same complete frozen corpus parity evaluation.
    predictions,timings=[],[]
    items=tokenize(tokenizer,cfg,read_split("calibration")+read_split("test"))
    for start in range(0,len(items),5):
        group=items[start:start+5];arrays=collate(group,tokenizer.pad_token_id)[:5]
        feed={field.name:x.numpy().astype(np.int32) for field,x in zip(fields,arrays)}
        began=time.perf_counter();result=converted.predict(feed);timings.append((time.perf_counter()-began)*1000)
        logits=next(iter(result.values()))
        predictions += [{key:item[key] for key in ("id","question","split","goldIndex")} |
            {"logits":logits[i,:len(item["markers"])].tolist()} for i,item in enumerate(group)]
    destination=args.output.parent/"direct-coreml-results";destination.mkdir(exist_ok=True)
    (destination/"predictions.json").write_text(json.dumps(predictions)+"\n")
    report={"toolVersion":ct.__version__,"questions":report_predictions(predictions),"performance":{
        "conversionSeconds":conversion_seconds,"coldLoadMilliseconds":coreml_cold,"firstInferenceMilliseconds":timings[0],"warmP50Milliseconds":float(np.percentile(timings[1:],50)),
        "warmP95Milliseconds":float(np.percentile(timings[1:],95)),"peakRSSBytes":resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        "modelDiskBytes":sum(p.stat().st_size for p in args.output.rglob("*") if p.is_file())}}
    (destination/"report.json").write_text(json.dumps(report,indent=2)+"\n")

if __name__=="__main__":
    parser=argparse.ArgumentParser();parser.add_argument("operation",choices=["onnx","quantize","coreml"])
    parser.add_argument("--model",type=Path);parser.add_argument("--onnx",type=Path)
    parser.add_argument("--output",type=Path,required=True);parser.add_argument("--provider",choices=["cpu","coreml"],default="cpu")
    args=parser.parse_args()
    {"onnx":evaluate_onnx,"quantize":quantize,"coreml":direct_coreml}[args.operation](args)
