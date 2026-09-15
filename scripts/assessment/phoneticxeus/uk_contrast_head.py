"""Tiny logistic head on a XEUS encoder mid-layer for RP contrasts the CTC head collapses (BATH ɑː/æ, LOT ɒ/ɑ, ɒ/ɔː).
numpy only. The head never decides alone: runtime consults it only when the CTC competitor is inside the contrast."""
import json, hashlib, math, sys
from pathlib import Path
import numpy as np

HEAD_FILE='uk-contrast-head.json'
VERSION='uk-contrast-head-v1'
COMPETITORS={'ɑː':{'æ','æ̃','a','ã'}, 'ɒ':{'ɑ','ɑ̃','ɔ','ɔ̃','ʌ','ʌ̃','o','a'}}
US_LABEL={'ɑː':'æ','ɒ':'ɑ'}
CONTRASTS_FOR={'ɑː':['ɑː-æ'], 'ɒ':['ɒ-ɑ','ɒ-ɔː']}
LOW,HIGH=.30,.70

def sigmoid(z): return 1/(1+math.exp(-max(-60,min(60,z))))

def fit_logistic(X, y, l2=1.0, iters=300, lr=.5):
    """Standardized L2 logistic regression by full-batch gradient descent. Returns (mean, scale, w, b)."""
    X=np.asarray(X,np.float64); y=np.asarray(y,np.float64)
    mean=X.mean(0); scale=X.std(0)+1e-6; Z=(X-mean)/scale
    w=np.zeros(Z.shape[1]); b=0.0
    for _ in range(iters):
        p=1/(1+np.exp(-np.clip(Z@w+b,-60,60))); g=p-y
        w-=lr*(Z.T@g/len(y)+l2*w/len(y)); b-=lr*g.mean()
    return mean, scale, w, b

class ContrastHead:
    def __init__(self, data, sha256):
        if data.get('version')!=VERSION or not isinstance(data.get('contrasts'),dict): raise ValueError('head version')
        self.layer=int(data['layer']); self.dim=int(data['dim']); self.sha256=sha256
        self.contrasts={}
        for name,c in data['contrasts'].items():
            arrays={k:np.asarray(c[k],np.float64) for k in ('mean','scale','w')}
            if any(v.shape!=(self.dim,) for v in arrays.values()): raise ValueError('head shape')
            self.contrasts[name]=dict(arrays,b=float(c['b']))
        for names in CONTRASTS_FOR.values():
            if any(n not in self.contrasts for n in names): raise ValueError('head contrasts')
    @classmethod
    def load(cls, path):
        try:
            raw=Path(path).read_bytes(); return cls(json.loads(raw), hashlib.sha256(raw).hexdigest())
        except Exception as e:
            print(f'ContrastHead.load: {type(e).__name__} loading {path}', file=sys.stderr); return None
    def probability(self, display, pooled):
        x=np.asarray(pooled,np.float64)
        if x.shape!=(self.dim,): raise ValueError('pooled shape')
        ps=[sigmoid(float(((x-c['mean'])/c['scale'])@c['w']+c['b'])) for c in (self.contrasts[n] for n in CONTRASTS_FOR[display])]
        return float(min(ps))
    @staticmethod
    def decide(p): return 'uk' if p>=HIGH else 'us' if p<=LOW else 'ambiguous'
    def summary(self): return dict(version=VERSION,layer=self.layer,contrasts=sorted(self.contrasts),sha256=self.sha256)
