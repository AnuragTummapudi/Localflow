"""Persistent offline benchmark comparator. Never records reasoning or user conversations."""
import os,sys,time,json,resource,copy
os.environ['HF_HUB_OFFLINE']='1';os.environ['TRANSFORMERS_OFFLINE']='1'
import mlx.core as mx
from mlx_lm import load,stream_generate
from mlx_lm.sample_utils import make_sampler
from mlx_lm.models.cache import make_prompt_cache
mx.set_cache_limit(128*1024*1024)
def metrics():
    # ru_maxrss is bytes on macOS: a high-water RSS, explicitly distinct from native current RSS.
    return {'rssBytes':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'mlxActiveBytes':mx.get_active_memory(),'mlxPeakBytes':mx.get_peak_memory()}
def send(x): print(json.dumps(x),flush=True)
start=time.perf_counter();model,tokenizer=load(sys.argv[1]);send(dict(ready=True,coldLoadMS=(time.perf_counter()-start)*1000,**metrics()))
prefix=[];prefix_cache=None
for line in sys.stdin:
    start=time.perf_counter()
    try:
        r=json.loads(line);thinking=r.get('thinking',False)
        prompt=tokenizer.apply_chat_template(r['messages'],tools=r['tools'],enable_thinking=thinking,add_generation_prompt=True,tokenize=True)
        if len(prompt)>8192:raise ValueError('Prompt limit')
        marker=tokenizer.encode('<|im_start|>user\n',add_special_tokens=False)
        boundary=next((i for i in range(len(prompt)-len(marker)+1) if prompt[i:i+len(marker)]==marker),0)
        trusted=prompt[:boundary]
        cache=None;cached=0
        if trusted and prompt[:len(trusted)]==trusted and len(trusted)<len(prompt):
            if prefix!=trusted:
                prefix=[];prefix_cache=make_prompt_cache(model)
                for i in range(0,len(trusted),512):
                    model(mx.array(trusted[i:i+512])[None],cache=prefix_cache)
                    mx.eval([c.state for c in prefix_cache])
                prefix=trusted
            cache=copy.deepcopy(prefix_cache);cached=len(prefix)
        full_count=len(prompt);prompt=prompt[cached:]
        text='';first=None;call=None;last=None;inside=thinking
        think_start=tokenizer.convert_tokens_to_ids('<think>');think_end=tokenizer.convert_tokens_to_ids('</think>')
        gen=stream_generate(model,tokenizer,prompt,max_tokens=r.get('maxTokens',2048 if thinking else 512),sampler=make_sampler(temp=0),prompt_cache=cache)
        for last in gen:
            if first is None:first=(time.perf_counter()-start)*1000
            if last.token==think_start:inside=True;text=''
            elif last.token==think_end:inside=False;text=''
            elif not inside:text+=last.text
            if not inside and '</tool_call>' in text:
                if call is None:call=(time.perf_counter()-start)*1000
                if r.get('firstOnly',True):break
        gen.close()
        accepted=text.strip();envelope=any(x in accepted for x in ['<tool','<function','<parameter','</tool','</function','</parameter'])
        kind=('tool_calls' if accepted.startswith('<tool_call>') else 'invalid') if envelope else ('assistant_stop' if last and last.finish_reason=='stop' and not inside and not accepted.startswith(('{','[')) else 'invalid')
        reply=dict(kind=kind,output=accepted if kind=='tool_calls' else '',promptTokens=full_count,cachedPrefixTokens=cached,ttftMS=first or -1,firstToolCallMS=call or -1,planMS=(time.perf_counter()-start)*1000,tokens=last.generation_tokens if last else 0,tokensPerSecond=last.generation_tps if last else 0,**metrics())
        send({k:str(v) for k,v in reply.items()});mx.clear_cache()
    except Exception as e:send({'error':'Generation failed: '+type(e).__name__})
