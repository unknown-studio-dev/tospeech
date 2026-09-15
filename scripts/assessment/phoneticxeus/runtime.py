"""Pinned FP32 PhoneticXeus runtime. Audio and inference are exclusively local."""
import os
os.environ['HF_HUB_OFFLINE']='1'; os.environ['TRANSFORMERS_OFFLINE']='1'; os.environ['HF_HUB_DISABLE_TELEMETRY']='1'
import argparse, json, sys, time, resource
from pathlib import Path
import numpy as np
from evidence import (assess_units, expand_rows, greedy, align_variants, align_units, build_units, encode,
                      POLICY, MAPPING, THRESHOLDS)
from reference import diagnostics, REFERENCE_POLICY
from uk_contrast_head import ContrastHead, HEAD_FILE, COMPETITORS, US_LABEL, CONTRASTS_FOR
import serve
REVISION='8d83dee94817a07dc150f87d08f7e0ee01bdb66d'
WEIGHT_HASH='ad58bf20a60e9d0380327bd8b2d0e8e90a9b8de2adccbfb479f9b21ea85eda18'
HEAD=None
_HIDDEN={'value':None}

def head_path():
    for base in (Path(getattr(sys,'_MEIPASS','')) if hasattr(sys,'_MEIPASS') else None, Path(__file__).resolve().parent):
        if base and (base/HEAD_FILE).exists(): return base/HEAD_FILE
    return None

def load(root, device='cpu'):
    global HEAD
    import torch
    from safetensors.torch import load_file
    code=Path(getattr(sys,'_MEIPASS',root)); sys.path.insert(0,str(code))
    from src.model.xeusphoneme.builders import build_xeus_pr_from_hf
    config=code/'src/model/xeusphoneme/resources/xeus_config.yaml'; vocabulary=code/'src/model/xeusphoneme/resources/ipa_vocab.json'
    vocab=json.loads(vocabulary.read_text())
    if len(vocab)!=428 or vocab.get('<blank>')!=0: raise ValueError('unexpected vocabulary contract')
    model=build_xeus_pr_from_hf(work_dir=str(code),hf_repo=None,config_file=str(config),vocab_file=str(vocabulary),load_ckpt=False,interctc_use_conditioning=True)
    tensors=load_file(str(root/'model.safetensors'),device='cpu')
    model.load_state_dict({k.removeprefix('model.'):v for k,v in tensors.items()},strict=True); del tensors
    model=model.eval().to(device)
    path=head_path(); HEAD=ContrastHead.load(path) if path else None
    if HEAD is not None:
        layers=list(model.encoder.encoders)
        if not 1<=HEAD.layer<=len(layers):
            print(f'ContrastHead layer {HEAD.layer} out of range for {len(layers)} encoder layers; disabling head', file=sys.stderr)
            HEAD=None
        else:
            def hook(module, inputs, output):
                x=output[0] if isinstance(output,tuple) else output
                x=x[0] if isinstance(x,tuple) else x
                _HIDDEN['value']=x.detach()[0].float().cpu().numpy()
            layers[HEAD.layer-1].register_forward_hook(hook)
    return model,vocab

def infer(model,samples,device):
    return infer_with_hidden(model,samples,device)[0]

def infer_with_hidden(model,samples,device):
    import torch
    samples=np.asarray(samples,dtype=np.float32)
    if samples.ndim!=1 or not 800<=len(samples)<=480000 or not np.isfinite(samples).all():
        raise ValueError(f'invalid input shape/range: {samples.shape}; mono 16k, 0.05–30 seconds required')
    values=torch.from_numpy(samples.copy()).unsqueeze(0).to(device); lengths=torch.tensor([len(samples)],device=device)
    _HIDDEN['value']=None
    with torch.inference_mode():
        hidden,_=model.encode(values,lengths)
        if isinstance(hidden,tuple): hidden=hidden[0]
        logits=model.ctc.ctc_lo(hidden)
        if logits.shape[0]!=1 or logits.shape[-1]!=428: raise ValueError(f'output shape {list(logits.shape)}')
        lp=logits.log_softmax(-1)[0].cpu().numpy()
    h=_HIDDEN['value']
    if h is not None and (h.ndim!=2 or len(h)!=len(lp) or (HEAD and h.shape[1]!=HEAD.dim)):
        print(f'infer_with_hidden: dropping hidden state shape {h.shape} for logits shape {lp.shape}', file=sys.stderr)
        h=None
    return lp,h

def read_pcm(path): return np.fromfile(path,dtype='<f4')

def runs(lp):
    ids=lp.argmax(-1); out=[]; start=0
    for end in range(1,len(ids)+1):
        if end==len(ids) or ids[end]!=ids[start]:
            if ids[start]>=4: out.append((int(ids[start]),start,end))
            start=end
    return out

def _realization(span, all_runs):
    if span is None: return []
    a,b=span; return [t for t,s,e in all_runs if s<b and e>a]

def _pooled(hidden,row,head):
    a,b=row.get('windowStart'),row.get('windowEnd')
    if hidden is None or a is None or b is None or b<=a: return None
    if head is not None and hidden.shape[1]!=head.dim: return None
    return hidden[a:b].mean(0)

def _span(row, step=.02):
    if row.get('emissionStart') is None or row.get('emissionEnd') is None: return None
    a=int(round(row['emissionStart']/step)); b=int(round(row['emissionEnd']/step)); return (a,b) if b>a else None

def stage_a(source, units, vocab, duration, head=None, hidden=None):
    """Reference licensing. Returns anchors, licensed allowed sets, licences, realizations and source rows."""
    discovery=align_units(source,units,[u.cond for u in units])
    if discovery is None: raise ValueError('source target lattice could not align')
    rr=runs(source); allowed=[]; licences=[]; realizations=[]
    for i,u in enumerate(units):
        R=_realization(discovery[i],rr)
        if not R or R in u.allowed: lic,al='accepted',u.allowed
        elif R in u.cond: lic,al='classD',u.allowed+[R]
        else: lic,al='unmapped',u.allowed
        allowed.append(al); licences.append(lic); realizations.append(R)
    rows=assess_units(source,units,allowed,vocab,duration)
    for i,(u,row) in enumerate(zip(units,rows)):
        if len(u.display)!=1 or u.display[0] not in CONTRASTS_FOR or row['status']=='correct' or licences[i]=='classD': continue
        if row.get('closestPhone') not in COMPETITORS[u.display[0]]: continue
        pooled=_pooled(hidden,row,head)
        if head is None or pooled is None: licences[i]='cannotDistinguish'; continue
        p=head.probability(u.display[0],pooled); d=ContrastHead.decide(p)
        row['contrast']=dict(name='+'.join(CONTRASTS_FOR[u.display[0]]),pUK=round(p,4),decision=d)
        licences[i]='head' if d=='uk' else 'weak' if d=='ambiguous' else 'unmapped'
    for i,row in enumerate(rows):
        # An `accepted` licence only ever means "the reference realized the target the expected way".
        # It is not evidence that the reference row itself is gradeable: a source row that is not
        # `correct` cannot license grading of the take (Swift's gate rejects that combination), so it
        # is demoted to `weak` and surfaces as `referenceWeak`.
        if licences[i] not in ('accepted','classD'): continue
        if licences[i]=='accepted' and row['status']!='correct': licences[i]='weak'; continue
        if row['status']=='likelyIncorrect' or row.get('logMargin',0)<0 or row.get('start') is None: licences[i]='weak'
    return dict(anchors=discovery,allowed=allowed,licences=licences,realizations=realizations,rows=rows)

def apply_head_take(units, rows, licences, head, hidden):
    for i,(u,row) in enumerate(zip(units,rows)):
        if len(u.display)!=1 or u.display[0] not in CONTRASTS_FOR or row['status']=='correct': continue
        if row.get('closestPhone') not in COMPETITORS[u.display[0]]: continue
        pooled=_pooled(hidden,row,head)
        if head is None or pooled is None: row['status']='uncertain'; row['reason']='modelCannotDistinguish'; continue
        p=head.probability(u.display[0],pooled); d=ContrastHead.decide(p)
        row['contrast']=dict(name='+'.join(CONTRASTS_FOR[u.display[0]]),pUK=round(p,4),decision=d)
        if d=='uk': row['status']='correct'; row['reason']='contrastHead'
        elif d=='us': row['status']='likelyIncorrect'; row['reason']=None; row['closestPhone']=US_LABEL[u.display[0]]
        else: row['status']='uncertain'; row['reason']='ambiguous'
    return rows

def run(model,vocab,request,device):
    a=read_pcm(request['source']); b=read_pcm(request['take'])
    if float(np.std(b))<1e-5: raise ValueError('no_speech')
    start=time.monotonic(); source,hs=infer_with_hidden(model,a,device); take,ht=infer_with_hidden(model,b,device)
    return assemble_from_logits(source,take,vocab,request,len(a)/16000,len(b)/16000,hs,ht,HEAD,device,time.monotonic()-start)

def assemble_from_logits(source,take,vocab,request,source_duration,take_duration,hidden_source=None,hidden_take=None,head=None,device='cpu',inferred=0):
    words=request['words']; variants=[]
    for word in words:
        valid=[v for v in word['variants'] if v and all(encode(p,vocab) for p in v)]
        if not valid: raise ValueError('unsupported UK target: '+word['text'])
        variants.append(valid)
    alignment=align_variants(source,variants,vocab)
    if alignment is None: raise ValueError('source target lattice could not align')
    selected=[v[i] for v,i in zip(variants,alignment[0])]
    units=build_units([(w['id'],v) for w,v in zip(words,selected)],vocab)
    inverse={i:s for s,i in vocab.items()}
    a=stage_a(source,units,vocab,source_duration,head,hidden_source)
    take_rows=assess_units(take,units,a['allowed'],vocab,take_duration)
    take_rows=apply_head_take(units,take_rows,a['licences'],head,hidden_take)
    tr=runs(take)
    for i,(u,row,src) in enumerate(zip(units,take_rows,a['rows'])):
        lic=a['licences'][i]; R=a['realizations'][i]; T=_realization(_span(row),tr)
        row['unitID']=u.id; row['licence']=lic
        row['licensedRealization']=' '.join(inverse[t] for t in R) if lic in ('classD','head') and R else None
        # What the reference audio actually realized, regardless of licence: the residual catalogue
        # needs this for `unmapped`/`weak` rows too, where `licensedRealization` is null by contract.
        row['referenceRealization']=' '.join(inverse[t] for t in R) if R else ''
        row['referenceStatus']=src['status']; row['takeStatus']=row['status']; row['takeReason']=row.get('reason')
        row['referenceMatch']=bool(R) and R==T
        row['sourceStart']=src.get('start'); row['sourceEnd']=src.get('end'); row['sourceStatus']=src['status']
        if lic=='unmapped': row['status']='uncertain'; row['reason']='referenceUnmapped'
        elif lic=='weak': row['status']='uncertain'; row['reason']='referenceWeak'
        # The head could not be consulted for this unit at all: no take-side verdict is licensed,
        # not even a `correct` one from the raw CTC scorer that the head exists to overrule.
        elif lic=='cannotDistinguish': row['status']='uncertain'; row['reason']='modelCannotDistinguish'
    # Hard per-word native competence mask: a word may show a red phone only if the
    # native reference confirmed EVERY unit of that word. Otherwise the whole word is
    # ungradeable for the learner (never an accusation).
    # A 'head' licence is only ever assigned when the raw CTC status is NOT 'correct'
    # (that's why the head was consulted at all), so 'correct' cannot be required of it;
    # the head's own arbitration (a 'head' licence at all) is the confidence signal there.
    from collections import defaultdict
    def _native_ok(i):
        lic=a['licences'][i]
        if lic=='accepted': return a['rows'][i]['status']=='correct'
        return lic in ('classD','head')
    word_units=defaultdict(list)
    for i,u in enumerate(units): word_units[u.word].append(i)
    for wid,idxs in word_units.items():
        if all(_native_ok(i) for i in idxs): continue
        # Only overwrite rows that would otherwise show green/red; already-uncertain rows
        # (referenceWeak/referenceUnmapped/modelCannotDistinguish) keep their specific reason.
        for i in idxs:
            if take_rows[i]['status'] in ('correct','likelyIncorrect'):
                take_rows[i]['status']='uncertain'; take_rows[i]['reason']='referenceNotConfident'
    source_phones=expand_rows(units,a['rows']); take_phones=expand_rows(units,take_rows)
    reference,details=diagnostics(source,take,source_phones,take_phones,words,selected,vocab,source_duration,take_duration)
    results=[]; cursor=0
    for word,variant in zip(words,selected):
        rows=[]
        for _ in variant:
            row=take_phones[cursor]; row['diagnostic']=details[cursor]; cursor+=1
            row.pop('chosen',None); rows.append(row)
        results.append(dict(id=word['id'],phones=rows,variant=variant))
    return dict(revision=REVISION,policy=POLICY,mapping=MAPPING,referencePolicy=REFERENCE_POLICY,device=device,dtype='float32',
        duration=take_duration,sourceDuration=source_duration,sourceShape=list(source.shape),takeShape=list(take.shape),
        inferenceSeconds=inferred,words=results,reference=reference,contrastHead=head.summary() if head else None,
        thresholds={k:round(v,6) for k,v in THRESHOLDS.items()},
        sourceRecognizedPhones=greedy(source,inverse,.02,source_duration),recognizedPhones=greedy(take,inverse,.02,take_duration),
        peakRSS=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)

assemble=assemble_from_logits  # benchmark scripts import this name

def serve_main(model_dir, device):
    import torch; torch.set_num_threads(4)
    from serve import serve, ReferenceCache
    start=time.monotonic(); model,vocab=load(model_dir, device); loaded=time.monotonic()-start
    cache=ReferenceCache(32)
    def handler(request, output):
        a=read_pcm(request['source']); b=read_pcm(request['take'])
        if float(np.std(b))<1e-5: raise ValueError('no_speech')
        key=ReferenceCache.key(a.tobytes()); hit=cache.get(key); cached=hit is not None
        t0=time.monotonic()
        if hit is None: hit=infer_with_hidden(model,a,device); cache.put(key,hit)
        source,hs=hit; take,ht=infer_with_hidden(model,b,device)
        result=assemble_from_logits(source,take,vocab,request,len(a)/16000,len(b)/16000,hs,ht,HEAD,device,time.monotonic()-t0)
        result['loadSeconds']=loaded; result['referenceCached']=cached; return result
    return serve(handler, sys.stdin, sys.stdout, dict(loadSeconds=loaded, head=HEAD.summary() if HEAD else None))

def main():
    import torch
    parser=argparse.ArgumentParser(); parser.add_argument('--model',type=Path,required=True)
    parser.add_argument('--request',type=Path); parser.add_argument('--output',type=Path)
    parser.add_argument('--device',choices=['cpu','mps'],default='cpu'); parser.add_argument('--probe',type=Path)
    parser.add_argument('--serve',action='store_true')
    args=parser.parse_args()
    if args.serve and (args.request or args.probe): parser.error('--serve is mutually exclusive with --request/--probe')
    if not args.serve and not args.output: parser.error('the following argument is required: --output')
    torch.set_num_threads(4)
    if args.serve: sys.exit(serve_main(args.model,args.device))
    start=time.monotonic(); model,vocab=load(args.model,args.device); loaded=time.monotonic()-start
    if args.probe:
        samples=read_pcm(args.probe); start=time.monotonic(); lp=infer(model,samples,args.device)
        output=dict(shape=list(lp.shape),loadSeconds=loaded,inferenceSeconds=time.monotonic()-start,
            peakRSS=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,device=args.device,torch=torch.__version__,
            phones=greedy(lp,{i:s for s,i in vocab.items()},.02,len(samples)/16000))
        np.save(args.output.with_suffix('.npy'),lp)
    else: output=run(model,vocab,json.loads(args.request.read_text()),args.device); output['loadSeconds']=loaded
    args.output.write_text(json.dumps(output,ensure_ascii=False,allow_nan=False))
    print(json.dumps(dict(status='complete',output=str(args.output))),flush=True)
if __name__=='__main__': main()
