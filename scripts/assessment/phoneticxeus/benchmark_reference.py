"""Reproduce reference diagnostics and perturbation controls on local audio only."""
import argparse, json, time
from pathlib import Path
import numpy as np
import torch
from runtime import load, infer, assemble

def main():
    p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True)
    p.add_argument('--request',type=Path,required=True);p.add_argument('--learner',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True);torch.set_num_threads(2)
    request=json.loads(a.request.read_text()); source=np.fromfile(request['source'],dtype='<f4')
    start=time.monotonic();model,vocab=load(a.model);loaded=time.monotonic()-start
    source_lp=infer(model,source,'cpu');np.save(a.output/'source-logits.npy',source_lp)
    # Negative controls edit the audio, not the model outputs. Regions correspond
    # to the supplied source fixture and are recorded, not used by production.
    controls={'self':source,'gain-half':source*.5,
              'padding':np.r_[np.zeros(8000,dtype=np.float32),source,np.zeros(4800,dtype=np.float32)],
              'missing-shadowing-glide':np.r_[source[:int(2.62*16000)],source[int(2.72*16000):]],
              'missing-british-onset':np.r_[source[:int(.86*16000)],source[int(1.02*16000):]],
              'silence':np.zeros_like(source),'learner':np.fromfile(a.learner,dtype='<f4')}
    summary={}
    for name,samples in controls.items():
        start=time.monotonic();target=infer(model,samples,'cpu')
        inferred=time.monotonic()-start
        np.save(a.output/(name+'-logits.npy'),target)
        result=assemble(source_lp,target,vocab,request,len(source)/16000,len(samples)/16000,inferred=inferred)
        result['loadSeconds']=loaded
        (a.output/(name+'.json')).write_text(json.dumps(result,ensure_ascii=False,allow_nan=False,indent=2))
        phones=[p for w in result['words'] for p in w['phones']];groups=result['reference']['groups']
        measured=[g['comparison']['jsDistance'] for g in groups if g['comparison']['jsDistance'] is not None]
        summary[name]=dict(seconds=time.monotonic()-start,shape=list(target.shape),units=len(phones),groups=len(groups),
            sharedGroups=sum(g['shared'] for g in groups),measuredGroups=len(measured),
            medianJSD=float(np.median(measured)) if measured else None,maxJSD=max(measured) if measured else None,
            graded={s:sum(p['status']==s for p in phones) for s in ('correct','uncertain','likelyIncorrect')},
            states={s:sum(p['diagnostic']['state']==s for p in phones) for s in set(p['diagnostic']['state'] for p in phones)})
        print(name,json.dumps(summary[name]),flush=True)
        (a.output/'summary.json').write_text(json.dumps(summary,indent=2))
if __name__=='__main__':main()
