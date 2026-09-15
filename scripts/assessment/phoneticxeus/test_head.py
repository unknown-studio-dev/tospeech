import contextlib, io, json, unittest, tempfile
from pathlib import Path
import numpy as np
from uk_contrast_head import ContrastHead, fit_logistic, HEAD_FILE, COMPETITORS, US_LABEL

def synthetic_head(tmp, dim=8):
    def contrast(seed):
        w=np.zeros(dim); w[seed]=4.0
        return dict(mean=[0.0]*dim, scale=[1.0]*dim, w=w.tolist(), b=0.0)
    data=dict(version='uk-contrast-head-v1', layer=12, dim=dim,
              contrasts={'ɑː-æ':contrast(0),'ɒ-ɑ':contrast(1),'ɒ-ɔː':contrast(2)}, training={'clips':0})
    p=Path(tmp)/HEAD_FILE; p.write_text(json.dumps(data)); return p

class HeadTests(unittest.TestCase):
    def test_probability_uses_min_over_contrasts_and_bands(self):
        with tempfile.TemporaryDirectory() as t:
            head=ContrastHead.load(synthetic_head(t)); self.assertIsNotNone(head)
            x=np.zeros(8); x[0]=1; self.assertGreater(head.probability('ɑː',x),.9)
            x=np.zeros(8); x[0]=-1; self.assertLess(head.probability('ɑː',x),.1)
            x=np.zeros(8); x[1]=1; x[2]=-1; self.assertLess(head.probability('ɒ',x),.1)   # must win both ɒ-ɑ and ɒ-ɔː
            self.assertEqual(ContrastHead.decide(.71),'uk'); self.assertEqual(ContrastHead.decide(.3),'us'); self.assertEqual(ContrastHead.decide(.5),'ambiguous')
            self.assertEqual(head.summary()['layer'],12); self.assertEqual(len(head.summary()['sha256']),64)
    def test_missing_or_malformed_file_yields_none(self):
        with tempfile.TemporaryDirectory() as t:
            stderr=io.StringIO()
            with contextlib.redirect_stderr(stderr):
                self.assertIsNone(ContrastHead.load(Path(t)/'nope.json'))
                (Path(t)/HEAD_FILE).write_text('{"version":"x"}'); self.assertIsNone(ContrastHead.load(Path(t)/HEAD_FILE))
            self.assertIn('FileNotFoundError', stderr.getvalue())
            self.assertIn('ValueError', stderr.getvalue())
    def test_fit_logistic_separates_and_roundtrips(self):
        rng=np.random.default_rng(3); X=rng.normal(size=(200,6)); y=(X[:,2]>0).astype(float)
        mean,scale,w,b=fit_logistic(X,y)
        z=((X-mean)/scale)@w+b; self.assertGreater(float(((z>0)==(y>.5)).mean()),.95)
    def test_competitor_tables(self):
        self.assertIn('æ',COMPETITORS['ɑː']); self.assertIn('ɑ̃',COMPETITORS['ɒ']); self.assertEqual(US_LABEL['ɒ'],'ɑ')
    def test_shipped_head_artifact_is_valid_and_documented(self):
        head=ContrastHead.load(Path(__file__).resolve().parent/HEAD_FILE)
        self.assertIsNotNone(head); self.assertEqual(head.layer,13); self.assertEqual(head.dim,1024)
        data=json.loads((Path(__file__).resolve().parent/HEAD_FILE).read_text())
        self.assertEqual(data['version'],'uk-contrast-head-v1')
        t=data['training']; self.assertGreaterEqual(t['cvByWord']['ɑː-æ'],.97); self.assertGreaterEqual(t['cvByVoice']['ɑː-æ'],.95)
        self.assertGreaterEqual(t['cvByWord']['ɒ-ɑ'],.97); self.assertGreaterEqual(len(t['voices']),12); self.assertLess((Path(__file__).resolve().parent/HEAD_FILE).stat().st_size,1_000_000)
        for name in ('ɑː-æ','ɒ-ɑ','ɒ-ɔː'):
            self.assertGreaterEqual(t['cvByWord'][name],.97); self.assertGreaterEqual(t['cvByVoice'][name],.95)
            c=data['contrasts'][name]
            for k in ('mean','scale','w'): self.assertEqual(len(c[k]),data['dim'])
            self.assertIsInstance(c['b'],(int,float))
        for k in ('words','clips','date','carrier'): self.assertIn(k,t)
if __name__=='__main__': unittest.main()
