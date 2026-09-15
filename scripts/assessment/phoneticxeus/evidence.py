"""UK CTC evidence, not calibrated pronunciation accuracy. No network/model imports."""
import math
import itertools
import numpy as np

POLICY = 'xeus-uk-ctc-evidence-v5-units'
MAPPING = 'xeus-uk-inventory-v4'
THRESHOLDS = dict(support=.30, margin=math.log(4), entropy=.55, competitor=math.log(6), strength=.65)
# These are tokenization/spelling alternatives, never LOT/PALM or rhoticity merges.
DIPHTHONGS = {'ɛə':['ɛ','ə'], 'eɪ':['e','ɪ'], 'aɪ':['a','ɪ'], 'ɔɪ':['ɔ','ɪ'], 'əʊ':['ə','ʊ'],
              'aʊ':['a','ʊ'], 'ɪə':['ɪ','ə'], 'eə':['ɛ','ə'], 'ʊə':['ʊ','ə']}
UK = 'iː ɪ e ɛ æ ɑː ɒ ɔː ʊ uː ʌ ɐ ɜː ə i u eɪ aɪ ɔɪ əʊ aʊ ɪə eə ʊə ɛː ɪː ʊː p b t d k ɡ f v θ ð s z ʃ ʒ h tʃ dʒ m n ŋ l ɹ j w ʔ l̩ n̩ m̩'.split()

# Class A/B/C — label conventions of this recognizer on English, measured on native RP audio
# (0 length marks in 704 tokens; GOAT always [o ʊ]; initial /b d g/ emitted as unaspirated [p t k]).
# Contrasts survive because quality tokens differ: ɪ/i/iː, ʊ/u/uː, ɒ/ɑ/ɑː, ɔ/ɔː, ʌ, ɜ/ə are distinct ids.
LENGTHLESS = {'iː':'i','uː':'u','ɑː':'ɑ','ɔː':'ɔ','ɜː':'ɜ','ɛː':'ɛ','ɪː':'ɪ','ʊː':'ʊ'}
GOAT = {'əʊ':[['o','ʊ']]}
DEVOICED = {'b':'p','d':'t','g':'k','ɡ':'k'}
ASPIRATED = {'p':'pʰ','t':'tʰ','k':'kʰ'}
# Class D — accent/speaker-dependent realizations. NEVER accepted globally: runtime Stage A licenses
# one of these for one unit only when the reference audio realized it there.
CONDITIONAL = {
    'ɛə':[['ɛ','ɹ'],['e','ɹ'],['ɛ','ə','ɹ'],['ɛ'],['e']], 'eə':[['ɛ','ɹ'],['e','ɹ'],['ɛ'],['e']],
    'ɪə':[['ɪ','ɹ'],['i','ɹ'],['ɪ'],['i'],['i','ə'],['ɪ','ə'],['j','ə']],
    'ʊə':[['ʊ','ɹ'],['u','ɹ'],['ʊ'],['u','ə'],['ʊ','ə']],
    'ɑː':[['ɑ','ɹ']], 'ɔː':[['ɔ','ɹ'],['ʊ','ɹ'],['ʊ','ə'],['o','ɹ'],['o']], 'ɜː':[['ɜ˞'],['ə˞'],['ɜ','ɹ']],
    'ə':[['ɜ˞'],['ə˞'],['ɐ'],['ʌ'],['ɪ'],['ʊ'],['ɜ']], 'ɐ':[['ʌ'],['ə']], 'ʌ':[['ɐ'],['ə']],
    'ɪ':[['i'],['ə']], 'i':[['ɪ'],['ə']], 'ʊ':[['u'],['ə']], 'u':[['ʊ'],['ə']], 'ɒ':[['ə']], 'e':[['ə'],['ɛ']],
    'dʒ':[['t','ʃ'],['t͡ʃ']], 'ɹ':[['ə˞'],['ɜ˞']]}
PAIRS = {('ə','ɹ'):[['ɜ˞'],['ə˞'],['ɛ','ɹ'],['ɹ']], ('ɜː','ɹ'):[['ɜ˞'],['ə˞']]}
# Real, acoustically confusable substitutions for RP L2 learners. `likelyIncorrect`
# fires ONLY when the model's preferred competitor is in the expected phone's set.
# Symmetric pairs below are expanded into both directions at import.
_CONFUSION_PAIRS = [
    ('θ','s'),('θ','f'),('θ','t'),('ð','d'),('ð','z'),('ð','v'),
    ('v','w'),('v','f'),('b','v'),('p','f'),('w','ɹ'),
    ('l','ɹ'),('ʃ','s'),('ʒ','z'),('ʒ','dʒ'),('tʃ','ʃ'),('tʃ','t'),('dʒ','ʒ'),('dʒ','j'),
    ('ŋ','n'),('ɪ','iː'),('æ','e'),('æ','ʌ'),('ʌ','ɑː'),('ʊ','uː'),('ɒ','ɔː'),('ɒ','əʊ'),('e','ɜː'),
    ('z','s'),('d','t'),('b','p'),('ɡ','k'),('v','f')]
CONFUSION = {}
for _a,_b in _CONFUSION_PAIRS:
    CONFUSION.setdefault(_a,set()).add(_b); CONFUSION.setdefault(_b,set()).add(_a)

def _dedupe(seqs): return [list(s) for s in dict.fromkeys(tuple(s) for s in seqs)]
def _nasal(seq, vocab):
    parts=[[s]+([s+'̃'] if s+'̃' in vocab else []) for s in seq]
    return [list(p) for p in itertools.product(*parts)]
def _expand(seqs, vocab):
    return [[vocab[s] for s in v] for seq in seqs for v in _nasal(seq, vocab) if all(s in vocab for s in v)]

def encode(phone, vocab):
    alias = {'r':'ɹ', 'g':'ɡ', 'e':'ɛ', 'tʃ':'t͡ʃ', 'dʒ':'d͡ʒ'}.get(phone, phone)
    symbols = DIPHTHONGS.get(phone, [alias])
    if any(s not in vocab or vocab[s] < 4 for s in symbols): return None
    return [vocab[s] for s in symbols]

def accepted(phone, vocab, word_initial=False):
    """Phonetic realizations of one UK phoneme: allophones plus label-convention classes A/B/C.

    Never a LOT/PALM, BATH/TRAP, rhoticity or quality merge. `word_initial` applies the
    aspiration rule: initial /p t k/ accept only [pʰ tʰ kʰ], so /b d g/→[p t k] stays separable.
    """
    base=encode(phone,vocab)
    if base is None: return []
    if word_initial and phone in ASPIRATED and ASPIRATED[phone] in vocab: return [[vocab[ASPIRATED[phone]]]]
    result=[base]
    symbol={'r':'ɹ','g':'ɡ','e':'ɛ'}.get(phone,phone)
    alternatives={'p':['pʰ'],'t':['tʰ'],'k':['kʰ'],'l':['l̴','lˠ'],
                  'tʃ':['t͡ʃʰ'],'e':['e'],'ɛ':['e']}.get(phone,[])
    if phone in UK[:27]: alternatives += [symbol+'̃']
    for alt in alternatives:
        if alt in vocab: result.append([vocab[alt]])
    for seq in {'tʃ':[['t','ʃ'],['tʰ','ʃ']], 'dʒ':[['d','ʒ']]}.get(phone,[]):
        if all(s in vocab for s in seq): result.append([vocab[s] for s in seq])
    if phone in DIPHTHONGS:
        parts=[[s]+([s+'̃'] if s+'̃' in vocab else []) for s in DIPHTHONGS[phone]]
        result += [[vocab[s] for s in seq] for seq in itertools.product(*parts)]
    if phone in LENGTHLESS: result += _expand([[LENGTHLESS[phone]]], vocab)
    result += _expand(GOAT.get(phone, []), vocab)
    if phone in DEVOICED and DEVOICED[phone] in vocab: result.append([vocab[DEVOICED[phone]]])
    return _dedupe(result)

def conditional(phone, vocab):
    """Class D realizations for Stage A licensing; excludes anything already accepted."""
    allowed={tuple(s) for s in accepted(phone,vocab)}
    return [s for s in _dedupe(_expand(CONDITIONAL.get(phone,[]),vocab)) if tuple(s) not in allowed]

def pair_realizations(p, q, vocab):
    return _dedupe(_expand(PAIRS.get((p,q),[]),vocab))

def alignment_options(phone, vocab):
    """Localization options for a phone: every accepted realization (class A already includes length-less labels)."""
    return accepted(phone,vocab)

def align_variants(lp, words, vocab, options=None):
    """Global Viterbi CTC lattice over dictionary variants and phone realizations.

    `options(wi, vi, pi, phone)` returns the token sequences allowed at that position;
    the default localizes each phone with `alignment_options`. A path chooses exactly
    one whole variant per word; it cannot splice halves of different variants. Repeated
    labels require a blank, including at branch boundaries. Every emitted label retains
    its word/variant/phone identity. Returns selected variant indices and independent
    phone emission anchors.
    """
    options = options or (lambda wi, vi, pi, phone: alignment_options(phone, vocab))
    validate(lp)
    if not words or len(words)>128:raise ValueError('invalid target word count')
    labels=[0]; owners=[None]; parents=[[0]]; previous=[0]
    for wi,variants in enumerate(words):
        if not variants or len(variants)>64:raise ValueError('invalid variant count')
        word_ends=[]
        for vi,phones in enumerate(variants):
            if not phones or len(phones)>1024:raise ValueError('invalid variant phone count')
            ends=previous
            for pi,phone in enumerate(phones):
                choices=options(wi,vi,pi,phone)
                if not choices:raise ValueError('unsupported target phone: '+phone)
                next_ends=[]
                for sequence in choices:
                    predecessors=ends
                    for token in sequence:
                        node=len(labels)
                        # A label state followed by its blank state. `ends`
                        # contains preceding label states, except initial blank 0.
                        incoming=[node]
                        for pred in predecessors:
                            incoming.append(0 if pred==0 else pred+1)
                            if pred!=0 and labels[pred]!=token:incoming.append(pred)
                        labels.extend([token,0]); owners.extend([(wi,vi,pi),None])
                        parents.extend([list(dict.fromkeys(incoming)),[node,node+1]])
                        predecessors=[node]
                    next_ends.extend(predecessors)
                ends=next_ends
            word_ends.extend(ends)
        previous=word_ends
    # Bound graph/backtrace memory for untrusted long targets.
    if len(labels)>24000:raise ValueError('target lattice too large')
    width=max(map(len,parents))
    if width>2048:raise ValueError('target lattice too wide')
    predecessors=np.full((len(labels),width),len(labels),np.int32)
    for i,incoming in enumerate(parents):predecessors[i,:len(incoming)]=incoming
    labels=np.asarray(labels); prev=np.full(len(labels)+1,-np.inf);prev[0]=0
    back=np.empty((len(lp),len(labels)),np.int32)
    columns=np.arange(len(labels))
    for t,row in enumerate(lp):
        scores=prev[predecessors]; choice=scores.argmax(1)
        back[t]=predecessors[columns,choice]
        prev[:-1]=scores[columns,choice]+row[labels]
    finals=[i for node in previous for i in [node,node+1]]
    state=max(finals,key=lambda i:prev[i])
    if not math.isfinite(prev[state]):return None
    anchors={}
    for t in range(len(lp)-1,-1,-1):
        owner=owners[state]
        if owner is not None:
            span=anchors.setdefault(owner,[t,t+1]);span[0]=t
        state=int(back[t,state])
    selected=[]; spans=[]
    for wi,variants in enumerate(words):
        choices={vi for w,vi,p in anchors if w==wi}
        if len(choices)!=1:raise ValueError('invalid variant backtrace')
        vi=choices.pop();selected.append(vi)
        spans.append([anchors[(wi,vi,pi)] for pi in range(len(variants[vi]))])
    return selected,spans

class Unit:
    """One scoring unit: 1–2 display phones of one word, their accepted and class-D token sequences."""
    __slots__=('word','indices','display','allowed','cond','word_initial')
    def __init__(self, word, indices, display, allowed, cond, word_initial):
        self.word=word; self.indices=indices; self.display=display; self.allowed=allowed; self.cond=cond; self.word_initial=word_initial
    @property
    def id(self): return f'{self.word}:{self.indices[0]}'

def build_units(words, vocab):
    """words: [(word_id, [phones])] of the selected variants. Adjacent PAIRS become one unit."""
    units=[]
    for wid,phones in words:
        i=0
        while i<len(phones):
            p=phones[i]
            if i+1<len(phones) and (p,phones[i+1]) in PAIRS:
                q=phones[i+1]; ga=accepted(p,vocab,i==0); gb=accepted(q,vocab)
                if not ga or not gb: raise ValueError('unsupported target phone: '+p+' '+q)
                allowed=_dedupe([a+b for a in ga for b in gb])
                cond=[s for s in _dedupe(pair_realizations(p,q,vocab)+[a+b for a in ga+conditional(p,vocab) for b in gb+conditional(q,vocab)]) if s not in allowed]
                units.append(Unit(wid,[i,i+1],[p,q],allowed,cond,i==0)); i+=2
            else:
                allowed=accepted(p,vocab,i==0)
                if not allowed: raise ValueError('unsupported target phone: '+p)
                units.append(Unit(wid,[i],[p],allowed,[s for s in conditional(p,vocab) if s not in allowed],i==0)); i+=1
    return units

def align_units(lp, units, extra=None):
    """Linear-chain alignment of units; may use allowed ∪ extra (licensed class-D sequences) for localization."""
    extra=extra or [[] for _ in units]
    opts=[_dedupe(u.allowed+e) for u,e in zip(units,extra)]
    r=align_variants(lp,[[list(range(len(units)))]],None,options=lambda wi,vi,pi,phone: opts[pi])
    return None if r is None else r[1][0]

def validate(lp):
    if lp.ndim != 2 or lp.shape[1] != 428 or not 1 <= len(lp) <= 1600 or not np.isfinite(lp).all():
        raise ValueError(f'invalid CTC log_probs shape/range: {lp.shape}')
    if not np.allclose(np.exp(lp).sum(-1), 1, atol=2e-4):
        raise ValueError('CTC rows must be log_softmax probabilities')

def path(lp, labels, trace=False):
    """Log-sum CTC likelihood or Viterbi emission spans; empty target is all blank."""
    labels = np.asarray(labels, dtype=np.int64)
    if len(labels) == 0: return (float(lp[:,0].sum()), []) if trace else float(lp[:,0].sum())
    if np.any(labels < 4) or np.any(labels >= lp.shape[1]): raise ValueError('special/unmapped target')
    if len(lp) < len(labels) + int(np.sum(labels[1:] == labels[:-1])):
        return (-math.inf, None) if trace else -math.inf
    ext = np.zeros(len(labels)*2+1, dtype=np.int64); ext[1::2] = labels
    skip = np.zeros(len(ext), bool); skip[3::2] = labels[1:] != labels[:-1]
    prev = np.full(len(ext), -np.inf); prev[0] = 0
    back = np.zeros((len(lp),len(ext)),np.uint8) if trace else None
    for t,row in enumerate(lp):
        one=np.r_[-np.inf,prev[:-1]]; two=np.r_[-np.inf,-np.inf,prev[:-2]]
        two[~skip]=-np.inf
        if trace:
            choices=np.stack([prev,one,two]); back[t]=choices.argmax(0)
            prev=choices.max(0)+row[ext]
        else: prev=np.logaddexp(np.logaddexp(prev,one),two)+row[ext]
    if not trace: return float(np.logaddexp(prev[-1],prev[-2]))
    state=len(ext)-1 if prev[-1]>prev[-2] else len(ext)-2
    score=float(prev[state]); spans=[[len(lp),0] for _ in labels]
    if not math.isfinite(score): return score,None
    for t in range(len(lp)-1,-1,-1):
        if state%2:
            spans[state//2][0]=t; spans[state//2][1]=max(spans[state//2][1],t+1)
        state-=int(back[t,state])
    return score,spans

def realization_likelihood(lp, sequences):
    """Sum disjoint collapsed CTC sequences, deduplicated to avoid double count.

    The accepted UK inventory defines the class; this adds no new aliases.
    Viterbi still provides a representative trace, not the class probability.
    """
    unique=list(dict.fromkeys(tuple(s) for s in sequences))
    scores=[path(lp,s) for s in unique]
    return float(np.logaddexp.reduce(scores)) if scores else -math.inf

def greedy(lp, inverse, step, duration):
    ids=lp.argmax(-1); result=[]; start=0
    for end in range(1,len(ids)+1):
        if end==len(ids) or ids[end]!=ids[start]:
            idx=int(ids[start])
            if idx>=4:
                result.append(dict(symbol=inverse[idx],start=start*step,end=min(end*step,duration),
                                   posterior=float(np.exp(lp[start:end,idx]).mean())))
            start=end
    return result

def assess_units(lp, units, allowed, vocab, duration, thresholds=THRESHOLDS, step=.02):
    """Windowed CTC evidence per unit. `allowed[i]` is the licensed token-sequence set of unit i.

    Localization may use unlicensed class-D sequences (`unit.cond`) so a learner realization such as
    an unlicensed rhotic vowel still lands in its own window; grading uses `allowed[i]` only.
    """
    validate(lp)
    extra=[_dedupe(u.cond+[s for s in al if s not in u.allowed]) for u,al in zip(units,allowed)]
    anchors=align_units(lp,units,extra)
    if anchors is None: return [dict(status='uncertain',reason='alignment') for _ in units]
    bounds=[anchors[0][0]]+[(a[1]+b[0])//2 for a,b in zip(anchors,anchors[1:])]+[anchors[-1][1]]
    inverse={i:s for s,i in vocab.items()}; inventory={p:encode(p,vocab) for p in UK}
    output=[]
    for index,(unit,al,(begin,end)) in enumerate(zip(units,allowed,anchors)):
        lo,hi=bounds[index],bounds[index+1]; window=lp[lo:hi]
        if not len(window): output.append(dict(status='uncertain',reason='alignment')); continue
        chosen=max(al,key=lambda seq:path(window,seq))
        expected_log=realization_likelihood(window,al)
        top=[int(i) for i in np.argsort(window.max(0))[-12:] if i>=4]
        candidates=dict(inventory); candidates.update({inverse[i]:[i] for i in top})
        scores={p:path(window,seq) for p,seq in candidates.items() if seq and seq not in al}
        observed=max(scores,key=scores.get); alternative_log=scores[observed]
        deletion_log=path(window,[]); margin=expected_log-max(alternative_log,deletion_log)
        token_support=[]; token_entropy=[]; best=[]
        _,spans=path(window,chosen,True)
        for position,(token,(a,b)) in enumerate(zip(chosen,spans or [])):
            probabilities=np.exp(window[a:b]); best.append(float(probabilities[:,token].mean()))
            equivalents={seq[position] for seq in al if len(seq)==len(chosen) and all(x==y for j,(x,y) in enumerate(zip(seq,chosen)) if j!=position)}
            token_support.append(min(1.0,float(probabilities[:,sorted(equivalents)].sum(-1).mean())))
            token_entropy.append(float(-(probabilities*window[a:b]).sum(-1).mean()/math.log(lp.shape[1])))
        if not token_support: output.append(dict(status='uncertain',reason='alignment')); continue
        support=min(token_support); confidence=1/(1+math.exp(-min(60,abs(margin))))
        status='uncertain'; reason='ambiguous'
        if support>=thresholds['support'] and margin>=thresholds['margin'] and max(token_entropy)<thresholds['entropy']:
            status='correct'; reason=None
        elif alternative_log>max(expected_log,deletion_log)+thresholds['competitor']:
            competitor=candidates[observed]; _,other=path(window,competitor,True)
            strength=min(float(np.exp(window[a:b,t]).mean()) for t,(a,b) in zip(competitor,other)) if other else 0
            expected_symbols={s for s in unit.display}
            confusable=any(observed in CONFUSION.get(sym,()) for sym in expected_symbols)
            if strength>=thresholds['strength'] and confusable: status='likelyIncorrect'; reason=None
            elif strength>=thresholds['strength']: status='uncertain'; reason='ambiguousSubstitution'
        output.append(dict(status=status,reason=reason,start=lo*step,end=min(duration,hi*step),
            emissionStart=begin*step,emissionEnd=min(duration,end*step),windowStart=int(lo),windowEnd=int(hi),
            expectedProbability=support,expectedTokenProbability=min(best),expectedLogLikelihood=expected_log,
            alternativeLogLikelihood=alternative_log,deletionLogLikelihood=deletion_log,logMargin=margin,
            closestPhone=observed,confidence=confidence,chosen=[inverse[t] for t in chosen]))
    return output

def expand_rows(units, rows):
    out=[]
    for unit,row in zip(units,rows):
        for j,phone in enumerate(unit.display):
            r=dict(row); r.update(expected=phone,unitID=unit.id,shared=len(unit.display)>1); out.append(r)
    return out

def assess_phones(lp, phones, vocab, duration, step=.02):
    """Compatibility wrapper: one unit per phone, no class D, no position rule."""
    units=[Unit('w',[i],[p],accepted(p,vocab),[],False) for i,p in enumerate(phones)]
    if any(not u.allowed for u in units):
        raise ValueError('unsupported target phone(s): '+repr([p for p in phones if not accepted(p,vocab)]))
    rows=assess_units(lp,units,[u.allowed for u in units],vocab,duration,step=step)
    return [{k:v for k,v in r.items() if k not in ('unitID','shared')} for r in expand_rows(units,rows)]
