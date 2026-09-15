#!/usr/bin/env python3
"""A1 regression: every lesson sentence ≤ 30 s (teacher audio) scored against its own UK target.
Teacher audio is gold-correct: scorer-level red = false alarm, neutral = lost coverage. Exits 1 below --expect."""
import argparse, json, sqlite3, subprocess, sys, time
from pathlib import Path
import numpy as np
HERE=Path(__file__).resolve().parent; sys.path.insert(0,str(HERE))
import evidence as ev
SYMBOLS=sorted(set(ev.UK+['r','g','ɛə']),key=len,reverse=True)
def parse(ipa):
    out=[];s=ipa
    while s:
        if s[0] in '/[]. ˈˌ‿': s=s[1:];continue
        f=next((x for x in SYMBOLS if s.startswith(x)),None)
        if not f:return None
        out.append(f);s=s[len(f):]
    return out or None
def espeak(binary,data_dir,word):
    w=word.strip().strip('.,;:!?"“”()').replace('’',"'")
    if not w or len(w)>80 or not any(c.isalnum() for c in w) or not all(c.isalnum() or c in ".'-" for c in w): return None
    try: out=subprocess.run([str(binary),'--path=.','-q','--ipa=1','-v','en-gb','--',w],cwd=data_dir,capture_output=True,text=True,timeout=5).stdout
    except Exception: return None
    toks=[]
    for t in out.strip().split('_'):
        st=''.join(c for c in t if c in 'ˈˌ'); t=''.join(c for c in t if c not in 'ˈˌ')
        toks.append(st+('æ' if t=='a' else t))
    return ''.join(toks) or None
def main():
    p=argparse.ArgumentParser(); p.add_argument('--db',type=Path,required=True); p.add_argument('--media',type=Path,required=True)
    p.add_argument('--espeak',type=Path,required=True); p.add_argument('--espeak-data',type=Path,required=True); p.add_argument('--pcm-extract',type=Path,required=True)
    p.add_argument('--model',type=Path,required=True); p.add_argument('--cache',type=Path,required=True); p.add_argument('--expect',type=Path)
    a=p.parse_args(); a.cache.mkdir(parents=True,exist_ok=True)
    import torch; from runtime import load, infer_with_hidden, assemble_from_logits
    import runtime
    torch.set_num_threads(4); model,vocab=load(a.model)
    con=sqlite3.connect(f'file:{a.db}?mode=ro',uri=True)
    rows=con.execute("""select s.lesson_id,s.ordinal,r.id,r.text,r.start_frame,r.end_frame,r.tokens_json,ma.relative_path
      from segments s join segment_revisions r on r.id=s.current_revision_id join media_assets ma on ma.id=r.audio_asset_id order by s.lesson_id,s.ordinal""").fetchall()
    total=dict(units=0,correct=0,red=0,neutral=0,finalRed=0,reasons={}); skipped=[]; per=[]; catalogue={}; contrast_seen=0
    for lesson,ordinal,rid,text,sf,ef,tokens,rel in rows:
        dur=(ef-sf)/48000; words=json.loads(tokens)
        if dur>30 or len(words)>128: skipped.append((ordinal,'too long')); continue
        request=dict(words=[]); bad=None
        for w in words:
            ann=con.execute("select automatic_value,override_value from annotations where revision_id=? and kind='ipa' and lookup_key=?",(rid,w['id']+':uk')).fetchone()
            prons=[x['ipa'] for x in json.loads(ann[1] or ann[0]).get('pronunciations',[])] if ann else ([espeak(a.espeak,a.espeak_data,w['text'])] if espeak(a.espeak,a.espeak_data,w['text']) else [])
            vs=[v for v in (parse(x) for x in prons) if v and all(ev.encode(q,vocab) for q in v)]
            if not vs: bad=(w['text'],prons); break
            request['words'].append(dict(id=w['id'],text=w['text'],variants=vs))
        if bad: skipped.append((ordinal,bad)); continue
        pcm=a.cache/f'{rid}.f32'; npy=a.cache/f'{rid}.npy'; hid=a.cache/f'{rid}.hidden.npy'
        if not npy.exists() or (runtime.HEAD and not hid.exists()):
            subprocess.run([str(a.pcm_extract),str(a.media/rel),str(pcm),str(sf/48000),str(ef/48000)],check=True)
            lp,h=infer_with_hidden(model,np.fromfile(pcm,dtype='<f4'),'cpu'); np.save(npy,lp)
            if h is not None: np.save(hid,h)
        lp=np.load(npy); h=np.load(hid) if hid.exists() else None
        result=assemble_from_logits(lp,lp,vocab,request,dur,dur,h,h,runtime.HEAD)
        phones=[(w['text'],ph) for w,rw in zip(words,result['words']) for ph in rw['phones']]
        c=sum(ph['takeStatus']=='correct' for _,ph in phones); r=sum(ph['takeStatus']=='likelyIncorrect' for _,ph in phones); n=len(phones)-c-r
        fr=sum(ph['status']=='likelyIncorrect' for _,ph in phones)
        total['units']+=len(phones); total['correct']+=c; total['red']+=r; total['neutral']+=n; total['finalRed']+=fr
        for text_,ph in phones:
            if ph.get('expected') in ('ɑː','ɒ') and ph.get('contrast') is not None: contrast_seen+=1
            if ph['status']!='correct': total['reasons'][ph.get('reason')]=total['reasons'].get(ph.get('reason'),0)+1
            if ph['takeStatus']!='correct':
                # `referenceRealization`, not `licensedRealization`: the residual queue is mostly
                # `unmapped`/`weak` rows, where the licensed field is null by contract and what we
                # need to read is what the teacher audio actually realized.
                key=f"/{ph['expected']}/ → [{ph.get('referenceRealization') or ''}] {ph['takeStatus']}/{ph.get('takeReason')} lic={ph.get('licence')}"
                catalogue.setdefault(key,[]).append(text_)
        per.append(dict(ordinal=ordinal,text=text[:60],units=len(phones),correct=c,red=r,neutral=n)); print(f"{lesson[:4]}#{ordinal:02d} {dur:5.1f}s {c:3d}/{r}/{n:<3d} {text[:60]}",flush=True)
    u=total['units']; summary=dict(sentences=len(per),units=u,green=total['correct']/u,falseRed=total['red']/u,neutral=total['neutral']/u,finalRed=total['finalRed'],reasons=total['reasons'],skipped=skipped)
    head_loaded=runtime.HEAD is not None; hook_live=contrast_seen>0 and head_loaded
    summary['hookLiveness']=dict(contrastRows=contrast_seen,headLoaded=head_loaded,live=hook_live)
    print(json.dumps(summary,ensure_ascii=False,indent=1))
    print(f"hook-liveness: contrastRows(expected in ɑː/ɒ with non-null contrast)={contrast_seen} runtime.HEAD={'loaded' if head_loaded else 'None'} live={hook_live}",flush=True)
    for k,v in sorted(catalogue.items(),key=lambda kv:-len(kv[1]))[:40]: print(f"  {k} ×{len(v)}: {sorted(set(v))[:6]}")
    (a.cache/'native-sweep-summary.json').write_text(json.dumps(dict(summary=summary,per=per,catalogue={k:len(v) for k,v in catalogue.items()}),ensure_ascii=False,indent=1))
    fails=[]
    if not hook_live: fails.append('headInert'); print('REGRESSION: head inert (hidden states not captured by hook / head not driving any ɑː-ɒ contrast decision)')
    if a.expect:
        e=json.loads(a.expect.read_text()); fails+=[k for k,(op,val) in e.items() if not (summary[k]>=val if op=='>=' else summary[k]<=val)]
    if fails: print('REGRESSION:',fails); sys.exit(1)
if __name__=='__main__': main()
