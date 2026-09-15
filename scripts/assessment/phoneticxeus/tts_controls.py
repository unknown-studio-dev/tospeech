#!/usr/bin/env python3
"""A2 controls: UK vs US TTS on BATH/LOT/TRAP/PALM/THOUGHT words, and wrong-word minimal pairs for consonants.
Target = the correct word's UK IPA; the reference clip is the UK voice saying the correct word; the take is the probe clip.

Gated stats use only Daniel (UK) / Samantha (US): the five compact voices (Eddy/Flo/Reed/Sandy/Shelley
"English (UK/US)") are not reliably intelligible to XEUS at the CTC level even for their own reference clip
(source-self fails Stage A), which is a harness/TTS-voice defect, not a scorer defect. Those voices are kept
as an informational, ungated block so a regression in them is still visible."""
import argparse, json, subprocess, sys, sqlite3
from pathlib import Path
import numpy as np
HERE=Path(__file__).resolve().parent; sys.path.insert(0,str(HERE))
import evidence as ev
from train_uk_contrast_head import SETS, VOICES, parse
from uk_contrast_head import US_LABEL
CONTROL_VOICES={'UK':['Daniel'],'US':['Samantha']}
INFO_VOICES={'UK':[v for v in VOICES['UK'] if v!='Daniel'],'US':[v for v in VOICES['US'] if v!='Samantha']}
PAIRS=[('think','sink','θ'),('then','den','ð'),('vest','west','v'),('van','fan','v'),('ship','sip','ʃ'),('sheep','ship','iː'),('fan','van','f'),('sink','think','s')]
def main():
    p=argparse.ArgumentParser(); p.add_argument('--model',type=Path,required=True); p.add_argument('--work',type=Path,required=True)
    p.add_argument('--pcm-extract',type=Path,required=True); p.add_argument('--expect',type=Path)
    p.add_argument('--baseline',type=Path,help='JSON of the four gated rates; exit 1 only on a drop of more than 0.02 below one of them')
    a=p.parse_args(); (a.work/'clips').mkdir(parents=True,exist_ok=True)
    import torch, runtime; from runtime import load, infer_with_hidden, assemble_from_logits
    torch.set_num_threads(4); model,vocab=load(a.model); inverse={i:s for s,i in vocab.items()}
    ipa=sqlite3.connect(f"file:{HERE.parents[2]/'ToSpeech/Resources/IPA/ipa.sqlite'}?mode=ro",uri=True); symbols=sorted(set(ev.UK+['r','g','ɛə']),key=len,reverse=True)
    def uk(word):
        rows=ipa.execute("select ipa from pronunciations where accent='uk' and lookup_key=? order by variant",(word.lower(),)).fetchall()
        return [v for v in (parse(r[0],symbols) for r in rows) if v and all(ev.encode(x,vocab) for x in v)]
    def clip(voice,word):
        key=f"{''.join(ch for ch in voice if ch.isalnum())}-{word}"; f32=a.work/'clips'/(key+'.f32')
        if not f32.exists():
            aiff=f32.with_suffix('.aiff'); subprocess.run(['say','-v',voice,'-o',str(aiff),f'Please say {word} now.'],check=True)
            subprocess.run([str(a.pcm_extract),str(aiff),str(f32),'0','30'],check=True); aiff.unlink()
        x=np.fromfile(f32,dtype='<f4'); lp,h=infer_with_hidden(model,x,'cpu'); return lp,h,len(x)/16000
    def score(ref,take,word,phone):
        """Returns the phone row for `phone` within the *actually selected* dictionary variant for
        `word` (assemble_from_logits may not select variant 0), or None if that variant doesn't
        contain `phone` at all (a dictionary/word-list mismatch, not a scorer failure)."""
        req=dict(words=[dict(id='w0',text='please',variants=uk('please')),dict(id='w1',text='say',variants=uk('say')),dict(id='w2',text=word,variants=uk(word)),dict(id='w3',text='now',variants=uk('now'))])
        r=assemble_from_logits(ref[0],take[0],vocab,req,ref[2],take[2],ref[1],take[1],runtime.HEAD)
        w2=[w for w in r['words'] if w['id']=='w2'][0]
        if phone not in w2['variant']: return None
        i=w2['variant'].index(phone); return w2['phones'][i]
    def detail(word,voice,take_clip,ph):
        lp,h,dur=take_clip
        return dict(word=word,voice=voice,status=ph.get('status'),reason=ph.get('reason'),licence=ph.get('licence'),
            closestPhone=ph.get('closestPhone'),logMargin=ph.get('logMargin'),expectedProbability=ph.get('expectedProbability'),
            greedy=[g['symbol'] for g in ev.greedy(lp,inverse,.02,dur)])
    def run_controls(uk_voices,us_voices):
        stats=dict(ukGreen=[0,0],usFlagged=[0,0],wrongWordFlagged=[0,0],rightWordRed=[0,0])
        failures=dict(ukGreen=[],usFlagged=[],wrongWordFlagged=[],rightWordRed=[])
        mismatches=[]; competitor_failed=[]
        for sname,(target,words) in SETS.items():
            for word in words:
                vs=uk(word)
                if not vs or target not in vs[0]: continue
                for vuk,vus in zip(uk_voices,us_voices):
                    ref=clip(vuk,word); ph=score(ref,ref,word,target)
                    if ph is None: mismatches.append(dict(stat='ukGreen',word=word,voice=vuk,phone=target))
                    ok=ph is not None and ph['status']=='correct'
                    stats['ukGreen'][1]+=1; stats['ukGreen'][0]+=ok
                    if not ok and ph is not None: failures['ukGreen'].append(detail(word,vuk,ref,ph))
                    if sname in ('BATH','LOT'):
                        take=clip(vus,word); ph=score(ref,take,word,target)
                        if ph is None: mismatches.append(dict(stat='usFlagged',word=word,voice=vus,phone=target))
                        # A red verdict only counts as "caught the US vowel" if it was caught *as* the
                        # US vowel: the closest phone is the US label for this target, or the head
                        # actually weighed in (a `contrast` block). A red for some unrelated competitor
                        # is a different error, not a detection, and is reported as `competitorFailed`.
                        competitor=ph is not None and (ph.get('closestPhone')==US_LABEL.get(target) or ph.get('contrast') is not None)
                        red=ph is not None and ph['status']=='likelyIncorrect'
                        flagged=(red and competitor) or (ph is not None and (ph.get('contrast') or {}).get('decision')=='ambiguous')
                        if red and not competitor:
                            competitor_failed.append(dict(word=word,voice=vus,phone=target,
                                closestPhone=ph.get('closestPhone'),usLabel=US_LABEL.get(target)))
                        stats['usFlagged'][1]+=1; stats['usFlagged'][0]+=flagged
                        if not flagged and ph is not None: failures['usFlagged'].append(detail(word,vus,take,ph))
        for right,wrong,phone in PAIRS:
            vs=uk(right)
            if not vs or phone not in vs[0]: continue
            for vuk in uk_voices:
                ref=clip(vuk,right); ph=score(ref,ref,right,phone)
                if ph is None: mismatches.append(dict(stat='rightWordRed',word=right,voice=vuk,phone=phone))
                bad=ph is not None and ph['status']=='likelyIncorrect'
                stats['rightWordRed'][1]+=1; stats['rightWordRed'][0]+=bad
                if bad: failures['rightWordRed'].append(detail(right,vuk,ref,ph))
                take=clip(vuk,wrong); ph=score(ref,take,right,phone)
                if ph is None: mismatches.append(dict(stat='wrongWordFlagged',word=wrong,voice=vuk,phone=phone))
                flagged=ph is not None and ph['status']=='likelyIncorrect'
                stats['wrongWordFlagged'][1]+=1; stats['wrongWordFlagged'][0]+=flagged
                if not flagged and ph is not None: failures['wrongWordFlagged'].append(detail(wrong,vuk,take,ph))
        return stats,failures,mismatches,competitor_failed
    gated_stats,gated_failures,gated_mismatches,gated_competitor=run_controls(CONTROL_VOICES['UK'],CONTROL_VOICES['US'])
    info_stats,info_failures,info_mismatches,info_competitor=run_controls(INFO_VOICES['UK'],INFO_VOICES['US'])
    summary={k:(v[0]/v[1] if v[1] else None) for k,v in gated_stats.items()}
    info_summary={k:(v[0]/v[1] if v[1] else None) for k,v in info_stats.items()}
    out=dict(counts=gated_stats,rates=summary,variantMismatch=len(gated_mismatches),
        competitorFailed=len(gated_competitor),competitorFailedDetail=gated_competitor,
        # Persisted so a rate change can be attributed to a named case without re-running the harness.
        failures={k:v for k,v in gated_failures.items() if v},
        informationalCompactVoices=dict(counts=info_stats,rates=info_summary,variantMismatch=len(info_mismatches),
            competitorFailed=len(info_competitor)))
    print(json.dumps(out,indent=1,ensure_ascii=False))
    print(f'likelyIncorrect rows that failed the US-competitor check (gated): {len(gated_competitor)}')
    if gated_competitor: print('competitorFailed (gated) detail:',json.dumps(gated_competitor,ensure_ascii=False))
    if gated_mismatches: print('variantMismatch (gated) detail:',json.dumps(gated_mismatches,ensure_ascii=False))
    if info_mismatches: print('variantMismatch (informational) detail:',json.dumps(info_mismatches,ensure_ascii=False))
    (a.work/'tts-controls-summary.json').write_text(json.dumps(out,indent=1,ensure_ascii=False))
    def report(fails,label):
        print(f'{label}:',fails)
        for k in fails:
            print(f'--- diagnostics for {k} ({len(gated_failures[k])} contributing case(s), Daniel/Samantha only) ---')
            for d in gated_failures[k]: print(json.dumps(d,ensure_ascii=False))
        sys.exit(1)
    # `--expect` holds the plan's spec targets (two of which TTS does not reach today, by ruling).
    # `--baseline` holds the last measured rates and only fires on a real drop, so the harness can
    # gate CI without pretending the spec targets are met.
    if a.baseline:
        b={k:v for k,v in json.loads(a.baseline.read_text()).items() if not k.startswith('_')}
        fails=[k for k,val in b.items() if summary.get(k) is None or summary[k] < val-0.02]
        if fails: report(fails,'REGRESSION vs baseline')
    if a.expect:
        e=json.loads(a.expect.read_text()); fails=[k for k,(op,val) in e.items() if summary[k] is None or not (summary[k]>=val if op=='>=' else summary[k]<=val)]
        if fails: report(fails,'REGRESSION')
if __name__=='__main__': main()
