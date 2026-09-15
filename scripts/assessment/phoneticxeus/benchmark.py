"""Reproducible UK smoke controls. TTS is not human-rated learner validation."""
import argparse,json,sys,time,resource
from pathlib import Path
import numpy as np
import torch
from runtime import load,infer
from evidence import assess_phones,greedy
p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--manifest',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
torch.set_num_threads(2);start=time.monotonic();model,vocab=load(a.model);r={'loadSeconds':time.monotonic()-start,'samples':[],'note':'Apple Daniel en-GB synthetic smoke controls, not human-rated accuracy.'}
for item in json.loads(a.manifest.read_text()):
 x=np.fromfile(item['pcm'],dtype='<f4');start=time.monotonic();lp=infer(model,x,'cpu');seconds=time.monotonic()-start
 row=dict(id=item['id'],duration=len(x)/16000,inferenceSeconds=seconds,shape=list(lp.shape),
  raw=' '.join(x['symbol'] for x in greedy(lp,{i:s for s,i in vocab.items()},.02,len(x)/16000)))
 if 'phones' in item:row['evidence']=assess_phones(lp,item['phones'].split(),vocab,len(x)/16000)
 if item.get('confusion'):
  target=item['phones'].split();target[item.get('index',0)]=item['confusion'];row['wrongTargetEvidence']=assess_phones(lp,target,vocab,len(x)/16000)
 r['samples'].append(row);r['peakRSS']=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
 a.output.write_text(json.dumps(r,ensure_ascii=False,indent=2,allow_nan=False));print(item['id'],row['raw'],flush=True)
