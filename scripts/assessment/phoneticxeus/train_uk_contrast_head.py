#!/usr/bin/env python3
"""Train the RP contrast head on locally synthesized speech (macOS `say`, UK vs US voices).
Nothing is downloaded. The head is a per-contrast logistic regression on mean-pooled XEUS encoder layer 13 (the LAYER constant below).
Refuses to write the artifact when held-out-by-word or held-out-by-voice accuracy is below the gates."""
import argparse, json, subprocess, sys, time, itertools, sqlite3
from pathlib import Path
import numpy as np
HERE=Path(__file__).resolve().parent; sys.path.insert(0,str(HERE))
import evidence as ev
from evidence import build_units, align_units, Unit
from uk_contrast_head import fit_logistic, HEAD_FILE, VERSION
LAYER=13
SETS={'BATH':('ɑː','grass after last bath dance ask path half staff answer class fast chance castle laugh plant'.split()),
      'TRAP':('æ','cat hat back man sad bad hand black flat map'.split()),
      'PALM':('ɑː','father calm palm hard car start far park'.split()),
      'LOT':('ɒ','pop job copy hot stop lot not top dog box clock doctor rock shop'.split()),
      'THOUGHT':('ɔː','law saw thought caught talk walk bought cause'.split())}
VOICES={'UK':['Daniel','Eddy (English (UK))','Flo (English (UK))','Reed (English (UK))','Sandy (English (UK))','Shelley (English (UK))'],
        'US':['Samantha','Eddy (English (US))','Flo (English (US))','Reed (English (US))','Sandy (English (US))','Shelley (English (US))']}
OPEN_VOWELS=['æ','æ̃','ɑ','ɑ̃','ɒ','ɔ','ɔ̃','a','ã','ʌ','ʌ̃','ə','o','ɐ','ɜ']
GATES=dict(byWord=.97,byVoice=.95)

def parse(ipa, symbols):
    out=[]; s=ipa
    while s:
        if s[0] in '/[]. ˈˌ‿': s=s[1:]; continue
        f=next((x for x in symbols if s.startswith(x)),None)
        if not f: return None
        out.append(f); s=s[len(f):]
    return out or None

def main():
    p=argparse.ArgumentParser(); p.add_argument('--model',type=Path,required=True); p.add_argument('--work',type=Path,required=True)
    p.add_argument('--dictionary',type=Path,default=HERE.parents[2]/'ToSpeech/Resources/IPA/ipa.sqlite'); p.add_argument('--output',type=Path,default=HERE/HEAD_FILE)
    a=p.parse_args(); a.work.mkdir(parents=True,exist_ok=True); clips=a.work/'clips'; clips.mkdir(exist_ok=True)
    extractor=a.work/'pcm_extract'
    if not extractor.exists(): subprocess.run(['swiftc','-O',str(HERE.parent/'pcm_extract.swift'),'-o',str(extractor)],check=True)
    import torch; from runtime import load
    torch.set_num_threads(4); model,vocab=load(a.model)
    store={}
    def hook(m,i,o):
        x=o[0] if isinstance(o,tuple) else o; x=x[0] if isinstance(x,tuple) else x; store['h']=x.detach()[0].float().cpu().numpy()
    list(model.encoder.encoders)[LAYER-1].register_forward_hook(hook)
    from runtime import infer
    ipa=sqlite3.connect(f'file:{a.dictionary}?mode=ro',uri=True); symbols=sorted(set(ev.UK+['r','g','ɛə']),key=len,reverse=True)
    def uk(word):
        rows=ipa.execute("select ipa from pronunciations where accent='uk' and lookup_key=? order by variant",(word.lower(),)).fetchall()
        vs=[parse(r[0],symbols) for r in rows]; return [v for v in vs if v and all(ev.encode(x,vocab) for x in v)]
    carrier_pre=[('please',uk('please')[0]),('say',uk('say')[0])]; carrier_post=[('now',uk('now')[0])]
    vowel_seqs=[[vocab[t]] for t in OPEN_VOWELS if t in vocab]
    X=[]; meta=[]; t0=time.time()
    for sname,(target,words) in SETS.items():
        for word in words:
            vs=uk(word)
            if not vs or target not in vs[0]: print('skip',word,flush=True); continue
            phones=vs[0]; j=phones.index(target)
            for acc,voices in VOICES.items():
                for voice in voices:
                    key=f"{voice.split(' ')[0]}-{acc}-{word}"; f32=clips/(key+'.f32')
                    if not f32.exists():
                        aiff=clips/(key+'.aiff'); subprocess.run(['say','-v',voice,'-o',str(aiff),f'Please say {word} now.'],check=True)
                        subprocess.run([str(extractor),str(aiff),str(f32),'0','30'],check=True); aiff.unlink()
                    x=np.fromfile(f32,dtype='<f4'); lp=infer(model,x,'cpu'); hidden=store['h']
                    units=build_units(carrier_pre+[(word,phones)]+carrier_post,vocab); k=len(carrier_pre[0][1])+len(carrier_pre[1][1])+j
                    units[k]=Unit(units[k].word,units[k].indices,units[k].display,vowel_seqs,[],False)
                    anchors=align_units(lp,units)
                    if anchors is None: print('align fail',key,flush=True); continue
                    lo=anchors[k-1][1]; hi=anchors[k+1][0]
                    if hi<=lo: lo,hi=anchors[k]
                    X.append(hidden[lo:hi].mean(0)); meta.append(dict(set=sname,word=word,accent=acc,voice=voice.split(' ')[0]))
            print(f'{sname} {word} {len(X)} clips {time.time()-t0:.0f}s',flush=True)
    expected=sum(len(w) for _,w in SETS.values())*sum(len(v) for v in VOICES.values())
    if len(X)!=expected: raise SystemExit(f'dataset incomplete: {len(X)} clips, expected {expected} (skipped words or alignment failures above)')
    X=np.stack(X)
    def sel(**kw): return np.array([i for i,m in enumerate(meta) if all(m[k] in v for k,v in kw.items())])
    contrasts={'ɑː-æ':(np.r_[sel(set=['BATH'],accent=['UK']),sel(set=['PALM'])], np.r_[sel(set=['BATH'],accent=['US']),sel(set=['TRAP'])]),
               'ɒ-ɑ':(sel(set=['LOT'],accent=['UK']), np.r_[sel(set=['LOT'],accent=['US']),sel(set=['PALM'])]),
               'ɒ-ɔː':(sel(set=['LOT'],accent=['UK']), sel(set=['THOUGHT']))}
    out=dict(version=VERSION,layer=LAYER,dim=int(X.shape[1]),contrasts={},training=dict(voices=[v for vs in VOICES.values() for v in vs],words={k:v[1] for k,v in SETS.items()},clips=len(meta),cvByWord={},cvByVoice={},date=time.strftime('%Y-%m-%d'),carrier='Please say X now.'))
    for name,(pos,neg) in contrasts.items():
        idx=np.r_[pos,neg]; y=np.r_[np.ones(len(pos)),np.zeros(len(neg))]
        for key,gk in (('cvByWord','word'),('cvByVoice','voice')):
            groups=np.array([meta[i][gk] for i in idx]); pred=np.zeros(len(idx))
            for g in np.unique(groups):
                te=groups==g; mean,scale,w,b=fit_logistic(X[idx][~te],y[~te]); pred[te]=((X[idx][te]-mean)/scale)@w+b
            out['training'][key][name]=round(float(((pred>0)==(y>.5)).mean()),4)
        mean,scale,w,b=fit_logistic(X[idx],y)
        out['contrasts'][name]=dict(mean=mean.round(6).tolist(),scale=scale.round(6).tolist(),w=w.round(6).tolist(),b=round(float(b),6))
        print(name,out['training']['cvByWord'][name],out['training']['cvByVoice'][name],flush=True)
    bad=[n for n in contrasts if out['training']['cvByWord'][n]<GATES['byWord'] or out['training']['cvByVoice'][n]<GATES['byVoice']]
    if bad: raise SystemExit('head below gates: '+', '.join(bad))
    a.output.write_text(json.dumps(out,ensure_ascii=False)); print('wrote',a.output,a.output.stat().st_size,'bytes')
if __name__=='__main__': main()
