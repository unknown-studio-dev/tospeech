"""Reference-scoped diagnostics. Distances are experimental, never color grades.

The target lattice locates candidate regions; it does not prove phone boundaries.
Whole greedy emissions crossing display boundaries create shared source groups.
The learner cannot change those groups or choose the reference representation.
"""
import math
import numpy as np
from evidence import validate

REFERENCE_POLICY = 'xeus-reference-diagnostics-v2'
STEP = .02
MIN_PHONE_MASS = .20  # Noise guard for diagnostics, NOT pronunciation calibration.

def emissions(lp, inverse):
    ids = lp.argmax(-1); out = []; start = 0
    for end in range(1, len(ids)+1):
        if end == len(ids) or ids[end] != ids[start]:
            token = int(ids[start])
            if token >= 4:
                out.append(dict(symbol=inverse[token], startFrame=start, endFrame=end,
                                posterior=float(np.exp(lp[start:end, token]).mean())))
            start = end
    return out

def frame_span(row, count):
    if row.get('start') is None or row.get('end') is None: return None
    lo = max(0, round(row['start']/STEP)); hi = min(count, round(row['end']/STEP))
    return (lo, hi) if hi > lo else None

def intersects(token, span):
    return span is not None and token['startFrame'] < span[1] and token['endFrame'] > span[0]

def region(lp, span, tokens, inverse, duration):
    if span is None: return None
    selected = [t for t in tokens if intersects(t, span)]
    # Do not cut the onset of a glide or split a shared rhotic token in half.
    lo = min([span[0]] + [t['startFrame'] for t in selected])
    hi = max([span[1]] + [t['endFrame'] for t in selected])
    probs = np.exp(lp[lo:hi]); active = (lp[lo:hi].argmax(-1) >= 4) & (probs[:,4:].sum(-1) >= MIN_PHONE_MASS)
    means = probs[active].mean(0) if active.any() else np.zeros(428)
    top = np.argsort(means[4:])[-3:][::-1]+4 if active.any() else []
    return dict(startFrame=lo, endFrame=hi, start=lo*STEP, end=min(hi*STEP, duration),
                tokens=selected, speechFrames=int(active.sum()),
                blankMean=float(probs[:,0].mean()),
                topCandidates=[dict(symbol=inverse[int(i)], posterior=float(means[i])) for i in top])

def speech_distributions(lp, value):
    if value is None: return np.empty((0,424))
    window = lp[value['startFrame']:value['endFrame']]; probs = np.exp(window[:,4:]).astype(np.float64)
    mass = probs.sum(-1)
    active = (window.argmax(-1) >= 4) & (mass >= MIN_PHONE_MASS)
    return probs[active] / mass[active, None]

def ordered_distance(a, b):
    """DTW mean JSD on nonblank emission distributions, in temporal order.

    This is a diagnostic distance in [0,1] (base-2 divergence), not an accuracy
    score. Long or blank-only regions are explicitly unavailable. No silence
    normalization, same-file override, or sorting/bag-of-phones comparison.
    """
    if not len(a) or not len(b): return None, 0
    if max(len(a),len(b)) > 256: return None, 0
    costs = np.full((len(a)+1,len(b)+1), np.inf); lengths = np.zeros(costs.shape, np.int32)
    costs[0,0] = 0
    tiny = np.finfo(np.float64).tiny
    for i,p in enumerate(a,1):
        midpoint=(p+b)/2
        values=(np.sum(p*(np.log2(np.maximum(p,tiny))-np.log2(np.maximum(midpoint,tiny))),axis=1)
                + np.sum(b*(np.log2(np.maximum(b,tiny))-np.log2(np.maximum(midpoint,tiny))),axis=1))/2
        for j,value in enumerate(values,1):
            pred = min(((i-1,j-1),(i-1,j),(i,j-1)), key=lambda ij: costs[ij])
            costs[i,j] = costs[pred]+max(0,float(value)); lengths[i,j]=lengths[pred]+1
    return min(1,float(costs[-1,-1]/lengths[-1,-1])), int(lengths[-1,-1])

def edit_distance(a,b):
    prev=list(range(len(b)+1))
    for i,x in enumerate(a,1):
        row=[i]
        for j,y in enumerate(b,1): row.append(min(prev[j]+1,row[-1]+1,prev[j-1]+(x!=y)))
        prev=row
    return prev[-1]

def hypothesis(row):
    return {k:row[k] for k in ('status','reason','expectedProbability','expectedTokenProbability','logMargin','closestPhone') if k in row}

def diagnostics(source, take, source_rows, take_rows, words, selected, vocab, source_duration, take_duration):
    validate(source); validate(take)
    inverse={i:s for s,i in vocab.items()}
    st=emissions(source,inverse); tt=emissions(take,inverse)
    members=[dict(wordID=w['id'],phoneIndex=i,displayPhone=p)
             for w,variant in zip(words,selected) for i,p in enumerate(variant)]
    if len(members)!=len(source_rows) or len(members)!=len(take_rows): raise ValueError('diagnostic target mismatch')
    spans=[frame_span(r,len(source)) for r in source_rows]
    parent=list(range(len(members)))
    def root(i):
        while parent[i]!=i: i=parent[i]
        return i
    for token in st:
        overlap=[i for i,span in enumerate(spans) if intersects(token,span)]
        for i in overlap[1:]: parent[root(i)]=root(overlap[0])
    buckets={}
    for i in range(len(members)): buckets.setdefault(root(i),[]).append(i)
    groups=[]; rows=[None]*len(members)
    for indices in buckets.values():
        group_id='group-'+str(indices[0])
        def combined(values,count):
            ranges=[frame_span(values[i],count) for i in indices]
            if any(r is None for r in ranges): return None
            return min(r[0] for r in ranges),max(r[1] for r in ranges)
        a=region(source,combined(source_rows,len(source)),st,inverse,source_duration)
        b=region(take,combined(take_rows,len(take)),tt,inverse,take_duration)
        distance,steps=ordered_distance(speech_distributions(source,a),speech_distributions(take,b))
        comparison=dict(state='UNCALIBRATED' if distance is not None else 'INSUFFICIENT_EVIDENCE',
                        jsDistance=distance,pathSteps=steps,
                        sequenceEditDistance=edit_distance([t['symbol'] for t in a['tokens']],
                            [t['symbol'] for t in b['tokens']]) if a and b else None)
        groups.append(dict(id=group_id,members=[members[i] for i in indices],source=a,take=b,
                           shared=len(indices)>1,comparison=comparison))
        for i in indices:
            ref=source_rows[i]; learner=take_rows[i]
            lic=learner.get('licence') or ref.get('licence') or 'accepted'
            unit_ids={source_rows[j].get('unitID') for j in indices}
            if a is None or b is None: state='ALIGNMENT_UNCERTAIN'
            elif not a['speechFrames'] or not b['speechFrames']: state='INSUFFICIENT_EVIDENCE'
            elif len(indices)>1 and len(unit_ids)>1: state='ALIGNMENT_UNCERTAIN'
            elif lic=='unmapped': state='REFERENCE_UNMAPPED'
            elif lic=='weak': state='REFERENCE_WEAK'
            elif lic=='cannotDistinguish' and learner['status']!='correct': state='MODEL_CANNOT_DISTINGUISH'
            elif learner['status']=='likelyIncorrect': state='LIKELY_PRONUNCIATION_DIFFERENCE_BY_HEAD' if learner.get('contrast') else 'LIKELY_PRONUNCIATION_DIFFERENCE'
            elif learner['status']=='correct':
                state='SUPPORTED_BY_CONTRAST_HEAD' if learner.get('reason')=='contrastHead' else 'SUPPORTED_BY_REFERENCE_CLASS' if lic=='classD' else 'SUPPORTED'
            else: state='INSUFFICIENT_EVIDENCE'
            rows[i]=dict(groupID=group_id,state=state,sourceHypothesis=hypothesis(ref),takeHypothesis=hypothesis(learner),
                         lengthStatus='UNVERIFIED' if 'ː' in members[i]['displayPhone'] else 'NOT_SEPARATELY_ASSESSED',
                         unitID=learner.get('unitID'),licence=lic)
    # Learner emissions spanning distinct source-defined groups are ambiguous;
    # they cannot merge the reference target or create two independent findings.
    for token in tt:
        overlap=[g for g in groups if g['take'] and token in g['take']['tokens']]
        if len(overlap)>1 and len({rows[i]['unitID'] for g in overlap for i,row in enumerate(rows) if row['groupID']==g['id']})>1:
            for g in overlap:
                g['takeBoundaryShared']=True
                for i,row in enumerate(rows):
                    if row['groupID']==g['id']: row['state']='ALIGNMENT_UNCERTAIN'
    return dict(policy=REFERENCE_POLICY,groups=groups),rows
