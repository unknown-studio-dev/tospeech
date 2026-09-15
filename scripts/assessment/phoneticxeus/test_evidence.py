import unittest,itertools
import numpy as np
from evidence import path,assess_phones,encode,align_variants,accepted,UK,realization_likelihood

class CTCEvidenceTests(unittest.TestCase):
    def lp(self,rows):
        p=np.full((len(rows),428),1e-8)
        for i,values in enumerate(rows):
            for token,prob in values.items():p[i,token]=prob
        p/=p.sum(1,keepdims=True)
        return np.log(p)
    def test_forward_matches_exhaustive_paths_and_repeats(self):
        lp=self.lp([{0:.4,4:.4,5:.2},{0:.3,4:.3,5:.4},{0:.2,4:.5,5:.3}])
        for target in [[],[4],[4,4],[4,5],[5,4]]:
            total=0
            for seq in itertools.product([0,4,5],repeat=3):
                collapsed=[x for x,_ in itertools.groupby(seq) if x!=0]
                if collapsed==target:total+=np.exp(sum(lp[t,k] for t,k in enumerate(seq)))
            self.assertAlmostEqual(np.exp(path(lp,target)),total,places=10)
    def test_uk_mapping_preserves_contrasts(self):
        vocab={'<blank>':0,'ɒ':4,'ɑː':5,'ɪ':6,'iː':7,'ə':8,'ʊ':9,'t͡ʃ':10,'ɹ':11}
        self.assertNotEqual(encode('ɒ',vocab),encode('ɑː',vocab))
        self.assertNotEqual(encode('ɪ',vocab),encode('iː',vocab))
        self.assertEqual(encode('əʊ',vocab),[8,9]);self.assertEqual(encode('tʃ',vocab),[10])
        self.assertIsNone(encode('missing',vocab))
    def test_wrong_target_not_green_just_because_alignment_succeeds(self):
        vocab={f'x{i}':i for i in range(428)};vocab.update({'<blank>':0,'θ':4,'s':5})
        lp=self.lp([{0:.95,5:.05},{5:.98,4:.001},{5:.95,4:.001},{0:.99}])
        _,spans=path(lp,[4],True);self.assertIsNotNone(spans)
        evidence=assess_phones(lp,['θ'],vocab,.08)[0]
        self.assertNotEqual(evidence['status'],'correct')
        self.assertEqual(evidence['closestPhone'],'s')
    def test_blank_only_and_ambiguous_are_not_correct(self):
        vocab={f'x{i}':i for i in range(428)};vocab.update({'<blank>':0,'θ':4,'s':5})
        for rows in [[{0:.9999}]*5,[{4:.39,5:.41,0:.2}]*5]:
            evidence=assess_phones(self.lp(rows),['θ'],vocab,.1)[0]
            self.assertEqual(evidence['status'],'uncertain')
    def test_length_only_difference_is_accepted_quality(self):
        vocab={f'x{i}':i for i in range(428)};vocab.update({'<blank>':0,'iː':4,'i':5})
        lp=self.lp([{0:.95},{5:.98,4:.001},{5:.95,4:.001},{0:.99}])
        row=assess_phones(lp,['iː'],vocab,.08)[0]
        self.assertEqual(row['status'],'correct')
        self.assertEqual(row['expected'],'iː')
    def test_dark_l_is_not_a_different_uk_phoneme(self):
        vocab={f'x{i}':i for i in range(428)};vocab.update({'<blank>':0,'l':4,'l̴':5})
        lp=self.lp([{0:.95},{5:.98,4:.001},{5:.95,4:.001},{0:.99}])
        self.assertNotEqual(assess_phones(lp,['l'],vocab,.08)[0]['status'],'likelyIncorrect')
    def test_impossible_repeat_rejected(self):
        _,spans=path(self.lp([{4:1},{4:1}]),[4,4],True)
        self.assertIsNone(spans)
    def test_lattice_selects_whole_variants_against_exhaustive_viterbi(self):
        vocab={'<blank>':0,'b':4,'d':5,'v':6}
        words=[[['b','d'],['d','b']],[['b'],['v','d']]]
        rng=np.random.default_rng(17)
        for _ in range(30):
            p=rng.dirichlet([1,1,1,1],size=7)
            lp=self.lp([dict(zip([0,4,5,6],row)) for row in p])
            selected,_=align_variants(lp,words,vocab)
            combos=list(itertools.product(range(2),repeat=2))
            def score(indices):
                ids=[vocab[p] for w,i in zip(words,indices) for p in w[i]]
                return path(lp,ids,True)[0]
            self.assertAlmostEqual(score(selected),max(map(score,combos)))
    def test_repeated_phones_across_words_need_blank(self):
        vocab={'<blank>':0,'v':4}
        self.assertIsNone(align_variants(self.lp([{4:1},{4:1}]),[[['v']],[['v']]],vocab))
        _,spans=align_variants(self.lp([{4:1},{0:1},{4:1}]),[[['v']],[['v']]],vocab)
        self.assertEqual(spans,[[[0,1]],[[2,3]]])
    def test_source_variant_selection_uses_nasalization_and_keeps_length_ungraded(self):
        vocab={f'x{i}':i for i in range(428)}
        vocab.update({'<blank>':0,'k':4,'kʰ':5,'ə':6,'æ':7,'æ̃':8,'n':9,'t':10,'tʰ':11,'uː':12,'u':13,'ʊ':14})
        lp=self.lp([{0:1},{5:.99},{8:.99},{9:.99},{0:1},{11:.99},{13:.99},{0:1}])
        selected,_=align_variants(lp,[[['k','ə','n'],['k','æ','n']],[['t','ə'],['t','ʊ'],['t','uː']]],vocab)
        self.assertEqual(selected,[1,2])
        rows=assess_phones(lp,['k','æ','n','t','uː'],vocab,.16)
        self.assertEqual(rows[1]['status'],'correct')
        self.assertEqual(rows[-1]['status'],'correct')
    def test_split_affricate_is_one_phone_with_both_emissions(self):
        vocab={f'x{i}':i for i in range(428)}
        vocab.update({'<blank>':0,'t͡ʃ':4,'t':5,'ʃ':6,'ə':7})
        lp=self.lp([{0:.99},{5:.99},{6:.99},{0:.99},{7:.99},{0:.99}])
        _,spans=align_variants(lp,[[['tʃ','ə']]],vocab)
        self.assertEqual(spans[0][0],[1,3])
        rows=assess_phones(lp,['tʃ','ə'],vocab,.12)
        self.assertEqual([r['status'] for r in rows],['correct','correct'])
        # A stop alone cannot be accepted as the complete affricate.
        self.assertNotIn([5],accepted('tʃ',vocab))
    def test_square_alias_and_length_do_not_merge_uk_contrasts(self):
        vocab={'<blank>':0,'ɛ':4,'ə':5,'ɹ':6,'ɒ':7,'ɑː':8,'ɑ':9}
        self.assertEqual(encode('ɛə',vocab),encode('eə',vocab))
        self.assertNotIn([6],accepted('ɛə',vocab))
        self.assertNotIn([7],accepted('ɑː',vocab))
    def test_realization_probability_sums_disjoint_ctc_sequences_once(self):
        lp=self.lp([{0:.4,4:.3,5:.3},{0:.2,4:.4,5:.4}])
        total=0
        for seq in itertools.product([0,4,5],repeat=2):
            collapsed=[x for x,_ in itertools.groupby(seq) if x!=0]
            if collapsed in [[4],[5]]:total+=np.exp(sum(lp[t,k] for t,k in enumerate(seq)))
        self.assertAlmostEqual(np.exp(realization_likelihood(lp,[[4],[5],[4]])),total,places=10)
    def test_split_probability_between_accepted_k_realizations_is_not_a_phone_error(self):
        vocab={f'x{i}':i for i in range(428)}
        vocab.update({'<blank>':0,'k':4,'kʰ':5,'ɡ':6})
        lp=self.lp([{0:.999},{4:.4426,5:.5466,6:.001},{0:.999}])
        row=assess_phones(lp,['k'],vocab,.06)[0]
        self.assertEqual(row['status'],'correct')
        self.assertGreater(row['expectedProbability'],.98)
        self.assertLess(row['expectedTokenProbability'],.60)
        wrong=self.lp([{0:.999},{4:.04,5:.04,6:.92},{0:.999}])
        self.assertNotEqual(assess_phones(wrong,['k'],vocab,.06)[0]['status'],'correct')
    def test_missing_glide_cannot_borrow_from_first_vowel(self):
        vocab={f'x{i}':i for i in range(428)}
        vocab.update({'<blank>':0,'e':4,'ɪ':5,'ẽ':6,'ɪ̃':7})
        lp=self.lp([{0:.999},{4:.48,6:.48},{0:.999},{0:.999}])
        self.assertNotEqual(assess_phones(lp,['eɪ'],vocab,.08)[0]['status'],'correct')
    def vocab428(self, **names):
        vocab={f'x{i}':i for i in range(428)}; vocab['<blank>']=0; vocab.update(names); return vocab
    def test_class_a_length_never_emitted_is_accepted_without_merging_quality(self):
        from evidence import accepted, MAPPING
        self.assertEqual(MAPPING,'xeus-uk-inventory-v3')
        v=self.vocab428(**{'iː':4,'i':5,'ɪ':6,'uː':7,'u':8,'ʊ':9,'ɑː':10,'ɑ':11,'ɒ':12,'ʌ':13,'ɔː':14,'ɔ':15})
        self.assertIn([5],accepted('iː',v)); self.assertNotIn([6],accepted('iː',v))
        self.assertIn([8],accepted('uː',v)); self.assertNotIn([9],accepted('uː',v))
        self.assertIn([11],accepted('ɑː',v)); self.assertNotIn([12],accepted('ɑː',v)); self.assertNotIn([13],accepted('ɑː',v))
        self.assertIn([15],accepted('ɔː',v)); self.assertNotIn([12],accepted('ɔː',v))
    def test_class_b_goat_accepts_o_glide_sequence_but_never_o_alone(self):
        from evidence import accepted
        v=self.vocab428(**{'ə':4,'ʊ':5,'o':6,'ʊ̃':7})
        self.assertIn([6,5],accepted('əʊ',v)); self.assertIn([6,7],accepted('əʊ',v)); self.assertNotIn([6],accepted('əʊ',v))
    def test_class_c_initial_devoicing_and_aspiration_rule_keep_stops_apart(self):
        from evidence import accepted
        v=self.vocab428(**{'b':4,'p':5,'pʰ':6,'d':7,'t':8,'tʰ':9,'ɡ':10,'k':11,'kʰ':12})
        self.assertEqual(accepted('p',v,word_initial=True),[[6]])
        self.assertIn([5],accepted('b',v)); self.assertNotIn([6],accepted('b',v))
        self.assertIn([11],accepted('g',v)); self.assertNotIn([12],accepted('g',v))
        self.assertEqual(accepted('t',v,word_initial=True),[[9]]); self.assertIn([8],accepted('t',v))
        for a,b in [('b','p'),('d','t'),('g','k')]:
            self.assertFalse({tuple(s) for s in accepted(a,v)} & {tuple(s) for s in accepted(b,v,word_initial=True)})
    def test_conditional_classes_are_not_globally_accepted(self):
        from evidence import accepted, conditional, pair_realizations
        v=self.vocab428(**{'ɛ':4,'ə':5,'ɹ':6,'ɜ˞':7,'ɑː':8,'ɑ':9,'ɪ':10,'i':11})
        self.assertNotIn([9,6],accepted('ɑː',v)); self.assertIn([9,6],conditional('ɑː',v))
        self.assertNotIn([4,6],accepted('ɛə',v)); self.assertIn([4,6],conditional('ɛə',v))
        self.assertIn([11],conditional('ɪ',v)); self.assertNotIn([11],accepted('ɪ',v))
        self.assertIn([7],pair_realizations('ə','ɹ',v))
    def test_contrast_token_sets_stay_disjoint(self):
        from evidence import accepted
        import json; from pathlib import Path
        vocab=json.loads((Path(__file__).resolve().parents[3]/'vendor/phoneticxeus/_internal/src/model/xeusphoneme/resources/ipa_vocab.json').read_text())
        pairs=[('θ','s'),('ð','d'),('v','w'),('f','v'),('ɪ','iː'),('ɪ','i'),('æ','ɛ'),('ʊ','uː'),('ɒ','ɔː'),('ʌ','ɑː'),('ɒ','ɑː'),('ɜː','ə'),('ʃ','s'),('ʒ','ʃ'),('tʃ','ʃ'),('dʒ','tʃ'),('n','ŋ'),('l','ɹ'),('əʊ','ɔː'),('əʊ','ʊ'),('eɪ','ɛ'),('aɪ','ɑː')]
        for a,b in pairs:
            self.assertFalse({tuple(s) for s in accepted(a,vocab)} & {tuple(s) for s in accepted(b,vocab)}, (a,b))
    def test_build_units_merges_schwa_r_pair_and_marks_word_initial(self):
        from evidence import build_units
        v=self.vocab428(**{'l':4,'ɪ':5,'t':6,'tʰ':7,'ə':8,'ɹ':9,'ɜ˞':10,'ʃ':11,'t͡ʃ':12,'ɛ':13})
        units=build_units([('w1',['l','ɪ','t','ə','ɹ','ə','tʃ','ə'])],v)
        self.assertEqual([u.display for u in units],[['l'],['ɪ'],['t'],['ə','ɹ'],['ə'],['tʃ'],['ə']])
        self.assertEqual(units[3].indices,[3,4]); self.assertIn([10],units[3].cond); self.assertNotIn([10],units[3].allowed)
        self.assertTrue(units[0].word_initial); self.assertFalse(units[2].word_initial)
        self.assertEqual(units[3].id,'w1:3')
    def test_align_units_locates_pair_unit_on_single_rhotic_token(self):
        from evidence import build_units, align_units
        v=self.vocab428(**{'l':4,'ɪ':5,'t':6,'ə':7,'ɹ':8,'ɜ˞':9})
        units=build_units([('w',['l','ɪ','t','ə','ɹ'])],v)
        lp=self.lp([{4:.99},{5:.99},{6:.99},{0:.99},{9:.99},{0:.99}])
        from evidence import assess_units
        rows=assess_units(lp,units,[u.allowed for u in units],v,.12)
        self.assertNotEqual(rows[3]['status'],'correct')
        spans=align_units(lp,units,[[],[],[],[[9]]])
        self.assertEqual(spans[3],[4,5])
    def test_align_variants_accepts_per_position_options(self):
        from evidence import align_variants
        vocab={'<blank>':0,'b':4,'d':5,'v':6}
        lp=self.lp([{4:1},{0:1},{5:1}])
        selected,spans=align_variants(lp,[[['x','y']]],vocab,options=lambda wi,vi,pi,phone:[[4]] if pi==0 else [[5]])
        self.assertEqual(spans,[[[0,1],[2,3]]])
    def test_assess_units_reports_pair_as_one_shared_decision(self):
        from evidence import build_units, assess_units, expand_rows
        v=self.vocab428(**{'l':4,'ɪ':5,'t':6,'ə':7,'ɹ':8,'ɜ˞':9})
        units=build_units([('w',['l','ɪ','t','ə','ɹ'])],v)
        allowed=[u.allowed for u in units]; allowed[3]=units[3].allowed+[[9]]
        lp=self.lp([{4:.99},{5:.99},{6:.99},{0:.99},{9:.99},{0:.99}])
        rows=assess_units(lp,units,allowed,v,.12)
        self.assertEqual(len(rows),4); self.assertEqual(rows[3]['status'],'correct'); self.assertEqual(rows[3]['chosen'],['ɜ˞'])
        phones=expand_rows(units,rows)
        self.assertEqual([p['expected'] for p in phones],['l','ɪ','t','ə','ɹ'])
        self.assertTrue(phones[3]['shared'] and phones[4]['shared']); self.assertEqual(phones[3]['unitID'],phones[4]['unitID'])
    def test_support_floor_thirty_admits_one_frame_spike_with_strong_margin(self):
        from evidence import assess_phones, THRESHOLDS
        v=self.vocab428(**{'ð':4,'h':5})
        spread={10+i:.0275 for i in range(20)}
        lp=self.lp([{0:.99},{4:.45,**spread},{0:.99}])
        row=assess_phones(lp,['ð'],v,.06)
        self.assertEqual(row[0]['status'],'correct')
        self.assertLess(row[0]['expectedProbability'],.60)
        from evidence import Unit, assess_units, accepted
        units=[Unit('w',[0],['ð'],accepted('ð',v),[],False)]
        strict=assess_units(lp,units,[units[0].allowed],v,.06,thresholds=dict(THRESHOLDS,support=.60))
        self.assertEqual(strict[0]['status'],'uncertain')
    def test_assess_phones_still_rejects_wrong_and_ambiguous(self):
        from evidence import assess_phones
        v=self.vocab428(**{'θ':4,'s':5})
        self.assertEqual(assess_phones(self.lp([{0:.95,5:.05},{5:.98,4:.001},{5:.95,4:.001},{0:.99}]),['θ'],v,.08)[0]['status'],'likelyIncorrect')
        self.assertEqual(assess_phones(self.lp([{4:.39,5:.41,0:.2}]*5),['θ'],v,.1)[0]['status'],'uncertain')
    def test_confusion_gate_flags_only_confusable_substitutions(self):
        from evidence import assess_phones, CONFUSION
        # v/w is a confusion pair; θ→(random x99) is not.
        self.assertIn('w', CONFUSION['v'])
        v=self.vocab428(**{'v':4,'w':5})
        # strong, sustained /w/ where /v/ was expected -> real confusable error
        lp=self.lp([{0:.99},{5:.98,4:.001},{5:.98,4:.001},{0:.99}])
        self.assertEqual(assess_phones(lp,['v'],v,.08)[0]['status'],'likelyIncorrect')
        # strong competitor that is NOT in the confusion set -> abstain, not wrong
        v2=self.vocab428(**{'v':4})  # x99 is a generic non-confusable token id 99
        lp2=self.lp([{0:.99},{99:.98,4:.001},{99:.98,4:.001},{0:.99}])
        row=assess_phones(lp2,['v'],v2,.08)[0]
        self.assertEqual(row['status'],'uncertain')
        self.assertEqual(row['reason'],'ambiguousSubstitution')
if __name__=='__main__':unittest.main()
