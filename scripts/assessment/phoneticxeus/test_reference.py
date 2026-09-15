import unittest
import numpy as np
from reference import diagnostics, ordered_distance, speech_distributions, region, emissions

def lp(tokens):
    p=np.full((len(tokens),428),.001/427)
    for i,t in enumerate(tokens): p[i,t]=.999
    return np.log(p)

class ReferenceTests(unittest.TestCase):
    def test_identity_requires_speech_and_keeps_order(self):
        a=np.eye(4)[[0,1,2]]
        self.assertEqual(ordered_distance(a,a)[0],0)
        self.assertGreater(ordered_distance(a,a[::-1])[0],.3)
        self.assertGreater(ordered_distance(a,a[:2])[0],.2)
        self.assertIsNone(ordered_distance(a,np.empty((0,4)))[0])

    def test_silence_and_tiny_nonblank_noise_are_not_evidence(self):
        values=lp([0,0,0]); inv={i:str(i) for i in range(428)}
        r=region(values,(0,3),emissions(values,inv),inv,.06)
        self.assertEqual(r['speechFrames'],0)
        self.assertEqual(len(speech_distributions(values,r)),0)

    def test_whole_shared_token_and_independent_timeline(self):
        vocab={str(i):i for i in range(428)}
        words=[dict(id='w')]; selected=[['ə','ɹ']]
        source=lp([0,4,4,4,4,0]); take=lp([0,0,0,4,4,4,4,0])
        def row(p,a,b): return dict(expected=p,start=a*.02,end=b*.02,status='uncertain',reason='ambiguous')
        refs=[row('ə',1,3),row('ɹ',3,5)]
        takes=[row('ə',3,5),row('ɹ',5,7)]
        value,rows=diagnostics(source,take,refs,takes,words,selected,vocab,.12,.16)
        self.assertEqual(len(value['groups']),1)
        g=value['groups'][0]
        self.assertTrue(g['shared']); self.assertEqual(len(g['members']),2)
        self.assertEqual(g['source']['tokens'][0]['startFrame'],1)
        self.assertEqual(g['take']['tokens'][0]['startFrame'],3)
        self.assertEqual(g['comparison']['jsDistance'],0)
        self.assertEqual({r['state'] for r in rows},{'INSUFFICIENT_EVIDENCE'})
        refs=[dict(row('ə',1,3),unitID='a'),dict(row('ɹ',3,5),unitID='b')]
        takes=[dict(row('ə',3,5),unitID='a'),dict(row('ɹ',5,7),unitID='b')]
        _,rows=diagnostics(source,take,refs,takes,words,selected,vocab,.12,.16)
        self.assertEqual({r['state'] for r in rows},{'ALIGNMENT_UNCERTAIN'})

    def test_learner_cannot_merge_reference_units(self):
        vocab={str(i):i for i in range(428)}
        def row(p,a,b,unit):return dict(expected=p,start=a*.02,end=b*.02,status='correct',unitID=unit)
        rows=[row('a',0,2,'w:0'),row('b',2,4,'w:1')]
        value,details=diagnostics(lp([4,4,5,5]),lp([4,4,4,4]),rows,rows,[dict(id='w')],[['a','b']],vocab,.08,.08)
        self.assertEqual(len(value['groups']),2)
        self.assertTrue(all(g['takeBoundaryShared'] for g in value['groups']))
        self.assertTrue(all(r['state']=='ALIGNMENT_UNCERTAIN' for r in details))

    def test_long_regions_are_explicitly_unavailable(self):
        self.assertIsNone(ordered_distance(np.ones((257,1)),np.ones((1,1)))[0])

    def test_v2_states_follow_licence_and_unit_sharing(self):
        vocab={str(i):i for i in range(428)}
        def row(p,a,b,status,**kw): d=dict(expected=p,start=a*.02,end=b*.02,status=status,reason=None); d.update(kw); return d
        refs=[row('ə',1,3,'uncertain',unitID='w:0',licence='classD'),row('ɹ',1,3,'uncertain',unitID='w:0',licence='classD')]
        takes=[row('ə',3,5,'correct',unitID='w:0',licence='classD'),row('ɹ',3,5,'correct',unitID='w:0',licence='classD')]
        value,rows=diagnostics(lp([0,4,4,4,4,0]),lp([0,0,0,4,4,4,4,0]),refs,takes,[dict(id='w')],[['ə','ɹ']],vocab,.12,.16)
        self.assertEqual(value['policy'],'xeus-reference-diagnostics-v2')
        self.assertTrue(value['groups'][0]['shared']); self.assertEqual({r['state'] for r in rows},{'SUPPORTED_BY_REFERENCE_CLASS'})
        self.assertEqual(rows[0]['licence'],'classD'); self.assertEqual(rows[0]['unitID'],'w:0')
        takes=[row('ə',3,5,'uncertain',reason='referenceUnmapped',unitID='w:0',licence='unmapped'),row('ɹ',3,5,'uncertain',reason='referenceUnmapped',unitID='w:0',licence='unmapped')]
        _,rows=diagnostics(lp([0,4,4,4,4,0]),lp([0,0,0,4,4,4,4,0]),refs,takes,[dict(id='w')],[['ə','ɹ']],vocab,.12,.16)
        self.assertEqual({r['state'] for r in rows},{'REFERENCE_UNMAPPED'})
        takes=[row('ə',3,5,'uncertain',reason='referenceWeak',unitID='w:0',licence='weak'),row('ɹ',3,5,'uncertain',reason='referenceWeak',unitID='w:0',licence='weak')]
        _,rows=diagnostics(lp([0,4,4,4,4,0]),lp([0,0,0,4,4,4,4,0]),refs,takes,[dict(id='w')],[['ə','ɹ']],vocab,.12,.16)
        self.assertEqual({r['state'] for r in rows},{'REFERENCE_WEAK'})
        takes=[row('ə',3,5,'correct',reason='contrastHead',unitID='w:0',licence='head'),row('ɹ',3,5,'uncertain',reason='modelCannotDistinguish',unitID='w:1',licence='cannotDistinguish')]
        refs2=[row('ə',1,3,'uncertain',unitID='w:0',licence='head'),row('ɹ',1,3,'uncertain',unitID='w:1',licence='cannotDistinguish')]
        _,rows=diagnostics(lp([0,4,4,4,4,0]),lp([0,0,0,4,4,4,4,0]),refs2,takes,[dict(id='w')],[['ə','ɹ']],vocab,.12,.16)
        self.assertEqual([r['state'] for r in rows],['ALIGNMENT_UNCERTAIN','ALIGNMENT_UNCERTAIN'])   # two units share one emission → still uncertain

if __name__=='__main__':unittest.main()
