"""Local GOPT input-pipeline probe. It never reports a proficiency score.

Requires a compiled Kaldi tree and official m13 chain/extractor archives unpacked
beneath --assets. Supply an explicit ARPAbet pronunciation, with vowel stress.
"""
import argparse,json,subprocess
from pathlib import Path
import soundfile as sf
import numpy as np
from scipy.signal import resample_poly
from math import gcd
p=argparse.ArgumentParser()
p.add_argument('--kaldi-build',type=Path,required=True);p.add_argument('--assets',type=Path,required=True)
p.add_argument('--audio',type=Path,required=True);p.add_argument('--phones',nargs='+',required=True)
p.add_argument('--output',type=Path,required=True)
a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
model=a.assets/'exp/chain_cleaned/tdnn_1d_sp';extractor=a.assets/'exp/nnet3_cleaned/extractor'
log=(a.output/'pipeline.log').open('w')
def run(name,*args):
    candidates=list((a.kaldi_build/'src').glob(f'*/{name}'))
    if len(candidates)!=1:raise RuntimeError(f'Missing binary {name}')
    result=subprocess.run([str(candidates[0]),*map(str,args)],stdout=log,stderr=log)
    if result.returncode:raise RuntimeError(f'{name} failed; see {a.output}/pipeline.log')
def file(name,text):
    path=a.output/name;path.write_text(text);return path
raw,rate=sf.read(a.audio,dtype='float32',always_2d=True);raw=raw.mean(axis=1)
if rate!=16000:
    d=gcd(rate,16000);raw=resample_poly(raw,16000//d,rate//d)
sf.write(a.output/'input.wav',raw,16000,subtype='PCM_16')
file('wav.scp',f'probe {a.output}/input.wav\n');file('spk2utt','speaker probe\n')
config=file('mfcc.conf','--use-energy=false\n--num-mel-bins=40\n--num-ceps=40\n--low-freq=20\n--high-freq=-400\n--dither=0\n')
run('compute-mfcc-feats',f'--config={config}',f'scp:{a.output}/wav.scp',f'ark,scp:{a.output}/mfcc.ark,{a.output}/mfcc.scp')
splice=file('splice.conf','\n'.join((extractor/'splice_opts').read_text().split())+'\n')
items={'cmvn-config':extractor/'online_cmvn.conf','splice-config':splice,'lda-matrix':extractor/'final.mat',
'global-cmvn-stats':extractor/'global_cmvn.stats','diag-ubm':extractor/'final.dubm','ivector-extractor':extractor/'final.ie',
'ivector-period':10,'num-gselect':5,'min-post':.025,'posterior-scale':.1,'max-remembered-frames':1000,'max-count':0}
ieconf=file('ivector.conf','\n'.join(f'--{k}={v}' for k,v in items.items())+'\n')
run('ivector-extract-online2',f'--config={ieconf}',f'ark:{a.output}/spk2utt',f'scp:{a.output}/mfcc.scp',f'ark,scp:{a.output}/ivector.ark,{a.output}/ivector.scp')
run('nnet3-am-copy','--raw=true',model/'final.mdl',a.output/'nnet.raw')
run('nnet3-compute','--use-gpu=no',f'--online-ivectors=scp:{a.output}/ivector.scp','--online-ivector-period=10',a.output/'nnet.raw',f'scp:{a.output}/mfcc.scp',f'ark:{a.output}/probs.ark')
phones={k:int(v) for k,v in [line.split() for line in (model/'phones.txt').read_text().splitlines()]}
ids=[phones[s+('_S' if len(a.phones)==1 else '_B' if i==0 else '_E' if i==len(a.phones)-1 else '_I')] for i,s in enumerate(a.phones)]
file('text.int','probe 1\n');file('text-phone.int','probe.0 '+' '.join(map(str,ids))+'\n')
file('disambig.int','\n'.join(str(v) for k,v in phones.items() if k.startswith('#'))+'\n')
run('compile-train-graphs-without-lexicon',f'--read-disambig-syms={a.output}/disambig.int',model/'tree',model/'final.mdl',f'ark:{a.output}/text.int',f'ark:{a.output}/text-phone.int',f'ark:{a.output}/graphs.ark')
run('align-compiled-mapped','--transition-scale=1.0','--acoustic-scale=0.1','--self-loop-scale=0.1','--beam=10','--retry-beam=40',model/'final.mdl',f'ark:{a.output}/graphs.ark',f'ark:{a.output}/probs.ark',f'ark:{a.output}/ali.ark')
run('ali-to-phones','--per-frame=true',model/'final.mdl',f'ark:{a.output}/ali.ark',f'ark:{a.output}/ali-phone.ark')
import re
pure={};mapping=[]
for phone,id in sorted(phones.items(),key=lambda x:x[1]):
    if phone.startswith('#'):continue
    symbol=re.sub(r'_[BIES]|\d','',phone)
    if symbol not in pure:pure[symbol]=len(pure)
    if id: mapping.append(f'{id} {pure[symbol]}')
file('phone-map.int','\n'.join(mapping)+'\n');file('pure-phones.json',json.dumps(pure,indent=2))
run('compute-gop',f'--phone-map={a.output}/phone-map.int','--skip-phones-string=0:1:2',model/'final.mdl',f'ark:{a.output}/ali.ark',f'ark:{a.output}/ali-phone.ark',f'ark:{a.output}/probs.ark',f'ark,t:{a.output}/gop.txt',f'ark,t:{a.output}/features.txt')
print((a.output/'features.txt').read_text())
