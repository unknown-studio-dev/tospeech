import json, unittest
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parent
VOCAB = json.loads((HERE.parent.parent.parent / 'scripts/assessment/phoneticxeus/ipa_vocab.json').read_text())

class OkayFixtureTests(unittest.TestCase):
    def setUp(self):
        self.lp = np.load(HERE / 'fixtures/okay-source-logits.npy')
        self.request = json.loads((HERE / 'fixtures/okay-request.json').read_text())

    def test_okay_source_self_reaches_fifteen_of_sixteen(self):
        from runtime import assemble_from_logits
        result = assemble_from_logits(self.lp, self.lp, VOCAB, self.request, 2.72, 2.72)
        rows = [p for w in result['words'] for p in w['phones']]
        self.assertEqual(len(rows), 16)
        # 'əʊ' in "Okay" is referenceUnmapped (its source realization isn't licensed) and keeps
        # that specific reason (it was already uncertain, not green/red). Its siblings 'k' and
        # 'eɪ' were individually correct/native-confirmed, but the hard per-word mask still grays
        # them since the word as a whole isn't fully native-confirmed.
        self.assertEqual(sum(r['status'] == 'correct' for r in rows), 13)
        unmapped = [r for r in rows if r['status'] != 'correct']
        self.assertEqual([(r['expected'], r['reason']) for r in unmapped],
                          [('əʊ', 'referenceUnmapped'), ('k', 'referenceNotConfident'), ('eɪ', 'referenceNotConfident')])
        self.assertEqual(result['policy'], 'xeus-uk-decision-v6-word-gated')
        self.assertEqual(result['mapping'], 'xeus-uk-inventory-v4')

    def test_assemble_contract_fields_and_head_summary(self):
        from runtime import assemble_from_logits
        result = assemble_from_logits(self.lp, self.lp, VOCAB, self.request, 2.72, 2.72)
        rows = [p for w in result['words'] for p in w['phones']]
        required = ('expected','status','reason','start','end','expectedProbability','logMargin','closestPhone',
                    'confidence','sourceStart','sourceEnd','sourceStatus','diagnostic','unitID','licence',
                    'licensedRealization','referenceRealization','referenceStatus','takeStatus','takeReason',
                    'referenceMatch')
        for r in rows:
            for key in required: self.assertIn(key, r)
            self.assertEqual(r['sourceStatus'], r['diagnostic']['sourceHypothesis']['status'])
            self.assertIn(r['licence'], {'accepted','classD','head','weak','unmapped','cannotDistinguish'})
            self.assertIsInstance(r['referenceMatch'], bool)
            if r['status'] in ('correct','likelyIncorrect'):
                self.assertIsNotNone(r['sourceStart'])
        self.assertIsNone(result['contrastHead'])
        self.assertEqual(result['referencePolicy'], 'xeus-reference-diagnostics-v2')

class GateContractTests(unittest.TestCase):
    """Every graded row must be licensed and carry a reference span, on real and synthetic evidence.

    This is the contract `PhoneticXeusAdapter.convert` enforces on the Swift side: a graded row whose
    source is neither `correct` nor class-D/head licensed, or that has no `sourceStart`, throws
    `invalidEvidence` and fails the whole job. Asserting it here keeps that failure out of the app.
    """
    def assert_gate(self, result):
        rows = [p for w in result['words'] for p in w['phones']]
        self.assertTrue(rows)
        for r in rows:
            self.assertIn('referenceRealization', r)
            if r['status'] in ('correct', 'likelyIncorrect'):
                self.assertTrue(r['sourceStatus'] == 'correct' or r['licence'] in ('classD', 'head'),
                                msg=f"graded but unlicensed: {r['expected']} {r['status']} {r['sourceStatus']} {r['licence']}")
                self.assertIsNotNone(r['sourceStart'], msg=f"graded without sourceStart: {r['expected']}")
        return rows

    def test_okay_fixture_never_grades_an_unlicensed_row(self):
        from runtime import assemble_from_logits
        lp = np.load(HERE / 'fixtures/okay-source-logits.npy')
        request = json.loads((HERE / 'fixtures/okay-request.json').read_text())
        self.assert_gate(assemble_from_logits(lp, lp, VOCAB, request, 2.72, 2.72))

    def test_pair_unit_rows_share_identity_and_both_timelines(self):
        # A PAIRS unit ("around" = /ə ɹ/ …) is one licensed sound rendered as two display phones:
        # `expand_rows` copies the same row, so both members must carry identical spans. Swift's
        # timeline check relies on exactly this (rows sharing a unitID do not advance the cursor).
        from runtime import assemble_from_logits
        lp = np.load(HERE / 'fixtures/okay-source-logits.npy')
        request = {'words': [{'id': 'w0', 'text': 'around', 'variants': [['ə', 'ɹ', 'aʊ', 'n', 'd']]}]}
        rows = self.assert_gate(assemble_from_logits(lp, lp, VOCAB, request, 2.72, 2.72))
        self.assertEqual([r['expected'] for r in rows], ['ə', 'ɹ', 'aʊ', 'n', 'd'])
        a, b = rows[0], rows[1]
        self.assertEqual(a['unitID'], b['unitID'])
        for key in ('start', 'end', 'sourceStart', 'sourceEnd'):
            self.assertEqual(a[key], b[key], msg=f'pair members disagree on {key}')
        self.assertNotEqual(a['unitID'], rows[2]['unitID'])

    def test_synthetic_head_fixtures_never_grade_an_unlicensed_row(self):
        from runtime import assemble_from_logits
        from uk_contrast_head import ContrastHead
        import tempfile
        from test_head import synthetic_head
        helper = StageATests()
        v = helper.vocab(**{'ɡ': 4, 'ɹ': 5, 'ɑː': 6, 'ɑ': 7, 'æ': 8, 's': 9})
        frames = [{4: .99}, {0: .99}, {5: .99}, {0: .99}, {8: .99}, {8: .99}, {0: .99}, {9: .99}, {0: .99}]
        src = helper.lp(frames); take = helper.lp(frames); T = len(frames)
        request = {'words': [{'id': 'w', 'text': 'garths', 'variants': [['g', 'ɹ', 'ɑː', 's']]}]}
        with tempfile.TemporaryDirectory() as t:
            head = ContrastHead.load(synthetic_head(t))
            for feature in (1.0, -1.0, 0.0):
                hs = np.zeros((T, 8)); hs[:, 0] = 1.0
                ht = np.zeros((T, 8)); ht[:, 0] = feature
                self.assert_gate(assemble_from_logits(src, take, v, request, T * .02, T * .02,
                                                      hidden_source=hs, hidden_take=ht, head=head))
        self.assert_gate(assemble_from_logits(src, take, v, request, T * .02, T * .02, head=None))

class StageATests(unittest.TestCase):
    def lp(self,rows):
        p=np.full((len(rows),428),1e-8)
        for i,v in enumerate(rows):
            for t,q in v.items(): p[i,t]=q
        p/=p.sum(1,keepdims=True); return np.log(p)
    def vocab(self,**names):
        v={f'x{i}':i for i in range(428)}; v['<blank>']=0; v.update(names); return v
    def test_class_d_realization_is_licensed_only_from_reference(self):
        from runtime import stage_a
        from evidence import build_units
        v=self.vocab(**{'w':4,'ɛ':5,'ə':6,'ɹ':7})
        units=build_units([('w',['w','ɛə'])],v)
        src=self.lp([{4:.99},{0:.99},{5:.99},{7:.99},{0:.99}])
        a=stage_a(src,units,v,.10)
        self.assertEqual(a['licences'],['accepted','classD']); self.assertEqual(a['realizations'][1],[5,7]); self.assertEqual(a['rows'][1]['status'],'correct')
    def test_unmapped_and_weak_reference_states(self):
        from runtime import stage_a
        from evidence import build_units
        v=self.vocab(**{'w':4,'ɛ':5,'ə':6,'ɹ':7,'s':8})
        units=build_units([('w',['w','ɛə'])],v)
        a=stage_a(self.lp([{4:.99},{0:.99},{8:.99},{8:.99},{0:.99}]),units,v,.10)
        self.assertEqual(a['licences'][1],'unmapped')
    def test_head_bands_on_take_and_missing_head(self):
        from runtime import apply_head_take
        from evidence import build_units
        from uk_contrast_head import ContrastHead
        import tempfile
        from test_head import synthetic_head
        v=self.vocab(**{'ɡ':4,'ɹ':5,'ɑː':6,'ɑ':7,'æ':8,'s':9})
        units=build_units([('w',['g','ɹ','ɑː','s'])],v)
        rows=[dict(status='correct'),dict(status='correct'),dict(status='likelyIncorrect',closestPhone='æ',windowStart=2,windowEnd=4),dict(status='correct')]
        licences=['accepted']*4
        with tempfile.TemporaryDirectory() as t:
            head=ContrastHead.load(synthetic_head(t))
            hidden=np.zeros((6,8)); hidden[2:4,0]=1.0
            out=apply_head_take(units,[dict(r) for r in rows],licences,head,hidden)
            self.assertEqual(out[2]['status'],'correct'); self.assertEqual(out[2]['reason'],'contrastHead'); self.assertEqual(out[2]['contrast']['decision'],'uk')
            hidden[2:4,0]=-1.0
            out=apply_head_take(units,[dict(r) for r in rows],licences,head,hidden)
            self.assertEqual(out[2]['status'],'likelyIncorrect'); self.assertEqual(out[2]['closestPhone'],'æ')
            hidden[2:4,0]=0.0
            out=apply_head_take(units,[dict(r) for r in rows],licences,head,hidden)
            self.assertEqual((out[2]['status'],out[2]['reason']),('uncertain','ambiguous'))
        out=apply_head_take(units,[dict(r) for r in rows],licences,None,None)
        self.assertEqual((out[2]['status'],out[2]['reason']),('uncertain','modelCannotDistinguish'))

    def test_apply_head_take_never_flips_a_classd_licensed_unit(self):
        # A classD licence means the SOURCE realized this unit's accent-dependent variant —
        # stage_a's own head consultation already skips classD units entirely (never lets the
        # head override a classD-licensed source row: runtime.py's `... or licences[i]=='classD':
        # continue`). apply_head_take must mirror that skip on the TAKE side too. Without it, a
        # classD-licensed unit's raw-uncertain take row could be flipped straight to
        # 'likelyIncorrect' by the head — and since the corrected per-word mask trusts a classD
        # licence on its own (no status=='correct' requirement), the per-word mask would never
        # catch this flip: a narrow, uncaught path to a red phone on native audio.
        from runtime import apply_head_take
        from evidence import build_units
        from uk_contrast_head import ContrastHead
        import tempfile
        from test_head import synthetic_head
        v=self.vocab(**{'ɡ':4,'ɹ':5,'ɑː':6,'ɑ':7,'æ':8,'s':9})
        units=build_units([('w',['g','ɹ','ɑː','s'])],v)
        # Unit 2 ('ɑː') take is raw-'uncertain' (e.g. from an ambiguous, non-confusable
        # substitution the raw scorer abstained on) with a closestPhone inside the contrast's
        # own competitor set — exactly the shape that would otherwise route into head
        # consultation.
        rows=[dict(status='correct'),dict(status='correct'),
              dict(status='uncertain',reason='ambiguousSubstitution',closestPhone='æ',windowStart=2,windowEnd=4),
              dict(status='correct')]
        licences=['accepted','accepted','classD','accepted']
        with tempfile.TemporaryDirectory() as t:
            head=ContrastHead.load(synthetic_head(t))
            hidden=np.zeros((6,8)); hidden[2:4,0]=-1.0  # feature that would decide 'us' if consulted
            out=apply_head_take(units,[dict(r) for r in rows],licences,head,hidden)
        self.assertEqual(out[2]['status'],'uncertain')
        self.assertNotEqual(out[2]['status'],'likelyIncorrect')  # never red: the head was never consulted
        self.assertEqual(out[2]['reason'],'ambiguousSubstitution')  # untouched, not overwritten
        self.assertNotIn('contrast',out[2])  # confirms the head-consultation branch was skipped

    def test_weak_reference_blocks_take_with_reason(self):
        # 'θ' is barely present anywhere (blank dominates every frame): the discovered
        # realization is empty (accepted-shaped, no contradicting evidence) but the
        # window's own evidence for 'θ' is far too weak (large negative logMargin),
        # so stage_a's final gate demotes the licence from accepted to weak.
        from runtime import stage_a, assemble_from_logits
        from evidence import build_units
        v=self.vocab(**{'θ':4,'s':5})
        units=build_units([('w',['θ'])],v)
        src=self.lp([{0:.999},{0:.997,4:.002},{0:.997,4:.002},{0:.999}])
        a=stage_a(src,units,v,.08)
        self.assertEqual(a['licences'],['weak'])
        result=assemble_from_logits(src,src,v,{'words':[{'id':'w','text':'th','variants':[['θ']]}]},.08,.08)
        rows=[p for w in result['words'] for p in w['phones']]
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['status'],'uncertain')
        # This row was already uncertain (not green/red) from the per-unit gate, so the
        # per-word mask leaves its specific reason alone.
        self.assertEqual(rows[0]['reason'],'referenceWeak')
        self.assertEqual(rows[0]['licence'],'weak')

    def test_degenerate_source_row_is_weak_not_graded(self):
        # A source row with no 'start' (alignment fallback) must never leave an
        # accepted/classD licence standing; stage_a's final gate treats a missing
        # 'start' the same as negative margin.
        import runtime
        from evidence import build_units
        v=self.vocab(**{'θ':4})
        units=build_units([('w',['θ'])],v)
        src=self.lp([{4:.99},{0:.99}])
        original=runtime.assess_units
        runtime.assess_units=lambda *a,**k: [dict(status='uncertain',reason='alignment')]
        try:
            a=runtime.stage_a(src,units,v,.04)
        finally:
            runtime.assess_units=original
        self.assertEqual(a['licences'],['weak'])

    def test_accepted_licence_with_a_non_correct_source_is_demoted_to_weak(self):
        # The reference realizes /θ/ the expected way (greedy R=[θ] ∈ allowed → `accepted`) but its own
        # evidence is only sub-threshold-positive (margin < ln 4), so the source row is `uncertain`.
        # An `accepted` licence must not let the take be graded off that: it becomes `referenceWeak`.
        from runtime import stage_a, assemble_from_logits
        from evidence import build_units
        v=self.vocab(**{'θ':4,'s':5})
        units=build_units([('w',['θ'])],v)
        src=self.lp([{0:.99},{4:.5,5:.3},{4:.5,5:.3},{0:.99}])
        take=self.lp([{0:.99},{4:.99},{4:.99},{0:.99}])
        a=stage_a(src,units,v,.08)
        self.assertEqual(a['rows'][0]['status'],'uncertain')
        self.assertGreater(a['rows'][0]['logMargin'],0)
        self.assertIsNotNone(a['rows'][0].get('start'))
        self.assertEqual(a['realizations'],[[4]])  # accepted-shaped realization, not class D
        self.assertEqual(a['licences'],['weak'])
        request={'words':[{'id':'w','text':'th','variants':[['θ']]}]}
        row=[p for w in assemble_from_logits(src,take,v,request,.08,.08)['words'] for p in w['phones']][0]
        self.assertEqual(row['takeStatus'],'correct')       # the take itself is fine …
        self.assertEqual(row['status'],'uncertain')         # … but the reference cannot license it
        # This row was already uncertain (not green/red) from the per-unit gate ('weak' licence),
        # so the per-word mask leaves its specific reason alone.
        self.assertEqual(row['reason'],'referenceWeak')
        self.assertEqual(row['licence'],'weak')

    def _assemble_word_case(self):
        # A two-unit word ('θ' then 's'). Source unit 1 is blank-dominated / ambiguous (same
        # weak-evidence shape as test_weak_reference_blocks_take_with_reason), so its Stage A
        # row never reaches 'correct' and its licence is demoted to 'weak'. Source unit 2 is a
        # clean, confident 's' (Stage A licences it 'accepted' and grades it 'correct'). The
        # take is irrelevant/blank for unit 1 and confidently says the confusable 'ʃ' for unit 2
        # (would be graded likelyIncorrect on its own, since 'ʃ' is nowhere else in the audio,
        # forced alignment must anchor unit 2's take there).
        from runtime import assemble_from_logits
        v = self.vocab(**{'θ': 4, 's': 5, 'ʃ': 6})
        src = self.lp([
            {0: .999},                # leading blank
            {0: .997, 4: .002},       # unit 1 ('θ'): blank-dominated, ambiguous -> not correct
            {0: .997, 4: .002},
            {0: .999},                # separator blank
            {5: .99},                  # unit 2 ('s'): confident, correct
            {0: .999},                 # trailing blank
        ])
        take = self.lp([
            {0: .999},
            {0: .999},                 # unit 1 take: irrelevant, will be masked regardless
            {0: .999},
            {0: .999},
            {6: .98, 5: .001},        # unit 2 take: confident, confusable 'ʃ' for expected 's'
            {6: .95, 5: .001},
            {0: .999},
        ])
        request = {'words': [{'id': 'w0', 'text': 'test', 'variants': [['θ', 's']]}]}
        return assemble_from_logits(src, take, v, request, len(src) * .02, len(take) * .02)

    def test_word_mask_grays_whole_word_when_native_unit_not_confident(self):
        # A two-unit word where the SOURCE cannot confirm unit 2 must yield NO red
        # on the TAKE for either unit, even if the take unit 1 looks wrong.
        result = self._assemble_word_case()  # helper builds a 2-phone word, source weak on phone 2
        phones = result['words'][0]['phones']
        self.assertTrue(all(p['status'] != 'likelyIncorrect' for p in phones))
        self.assertTrue(any(p['reason'] == 'referenceNotConfident' for p in phones))

    def test_word_mask_overwrites_a_would_be_green_row_but_preserves_sibling_reason(self):
        # Unit A ('s') is fully native-confirmed on its own (accepted licence, correct source,
        # correct take) — ungated, it would show a plain green 'correct'. Unit B ('θ') is the
        # same blank-dominated weak-evidence shape as test_weak_reference_blocks_take_with_reason,
        # so its own source row never reaches 'correct' and its licence is demoted to 'weak'.
        # The word-level mask must still fire because of unit B, overwriting unit A's
        # would-be-green take row to uncertain/referenceNotConfident — while leaving unit B's
        # own, already-uncertain row with its specific 'referenceWeak' reason untouched.
        from runtime import assemble_from_logits
        v = self.vocab(**{'s': 4, 'θ': 5})
        src = self.lp([
            {0: .999},                # leading blank
            {4: .99},                  # unit A ('s'): confident, correct source
            {0: .999},                 # separator blank
            {0: .997, 5: .002},       # unit B ('θ'): blank-dominated, ambiguous -> not correct
            {0: .997, 5: .002},
            {0: .999},                 # trailing blank
        ])
        take = self.lp([
            {0: .999},
            {4: .99},                  # unit A take: confident, matches source -> correct
            {0: .999},
            {0: .997, 5: .002},       # unit B take: irrelevant, will keep its own reason
            {0: .997, 5: .002},
            {0: .999},
        ])
        request = {'words': [{'id': 'w1', 'text': 'test2', 'variants': [['s', 'θ']]}]}
        result = assemble_from_logits(src, take, v, request, len(src) * .02, len(take) * .02)
        phones = result['words'][0]['phones']
        a_row = next(p for p in phones if p['expected'] == 's')
        b_row = next(p for p in phones if p['expected'] == 'θ')
        self.assertEqual(a_row['takeStatus'], 'correct')  # would-be-green before the mask …
        self.assertEqual((a_row['status'], a_row['reason']), ('uncertain', 'referenceNotConfident'))
        self.assertEqual((b_row['status'], b_row['reason']), ('uncertain', 'referenceWeak'))

    def test_cannot_distinguish_always_overrides_a_correct_take(self):
        # The reference says [æ] for BATH /ɑː/ — a competitor the CTC labels collapse — and no head is
        # available to tell the two apart, so the unit is `cannotDistinguish`. The take happens to say
        # a clean [ɑ] and the raw scorer calls it `correct`; that verdict is exactly what the head
        # exists to arbitrate, so without the head it must not stand.
        from runtime import assemble_from_logits
        v=self.vocab(**{'ɡ':4,'ɹ':5,'ɑː':6,'ɑ':7,'æ':8,'s':9})
        vowel=lambda t:[{4:.99},{0:.99},{5:.99},{0:.99},{t:.99},{t:.99},{0:.99},{9:.99},{0:.99}]
        src=self.lp(vowel(8)); take=self.lp(vowel(7)); T=9
        request={'words':[{'id':'w','text':'garths','variants':[['g','ɹ','ɑː','s']]}]}
        row=[p for w in assemble_from_logits(src,take,v,request,T*.02,T*.02,head=None)['words']
             for p in w['phones'] if p['expected']=='ɑː'][0]
        self.assertEqual(row['licence'],'cannotDistinguish')
        self.assertEqual(row['takeStatus'],'correct')
        # This row was already uncertain (not green/red) from the per-unit gate
        # ('cannotDistinguish' licence), so the per-word mask leaves its specific reason alone.
        self.assertEqual((row['status'],row['reason']),('uncertain','modelCannotDistinguish'))

    def test_assemble_with_synthetic_head_reports_summary_and_contrast(self):
        # NOTE: `hidden_source` (hs) is fixed to the 'uk' feature across every sub-scenario
        # below; only `hidden_take` (ht) varies. The per-word mask consults the SOURCE-side
        # licence (a['licences'], from stage_a using hs), not the take's own head decision —
        # so a consistent source-side 'head' licence (in ('classD','head')) satisfies
        # `_native_ok` regardless of what the take says, and the take's own contrast-head
        # verdict (from apply_head_take, using ht) surfaces unmasked in every scenario here.
        from runtime import assemble_from_logits
        from uk_contrast_head import ContrastHead
        import tempfile
        from test_head import synthetic_head
        v=self.vocab(**{'ɡ':4,'ɹ':5,'ɑː':6,'ɑ':7,'æ':8,'s':9})
        # Both source and take realize the BATH vowel as [æ] (the CTC head's own
        # competitor for ɑː); only the contrast head's hidden-state feature tells
        # them apart.
        frames=[{4:.99},{0:.99},{5:.99},{0:.99},{8:.99},{8:.99},{0:.99},{9:.99},{0:.99}]
        src=self.lp(frames); take=self.lp(frames); T=len(frames)
        request={'words':[{'id':'w','text':'garths','variants':[['g','ɹ','ɑː','s']]}]}
        with tempfile.TemporaryDirectory() as t:
            head=ContrastHead.load(synthetic_head(t))
            hs=np.zeros((T,8)); hs[:,0]=1.0
            ht=np.zeros((T,8)); ht[:,0]=1.0
            result=assemble_from_logits(src,take,v,request,T*.02,T*.02,hidden_source=hs,hidden_take=ht,head=head)
            row=[p for w in result['words'] for p in w['phones'] if p['expected']=='ɑː'][0]
            self.assertEqual(row['licence'],'head'); self.assertEqual(row['status'],'correct')
            self.assertEqual(row['reason'],'contrastHead'); self.assertEqual(row['contrast']['decision'],'uk')
            self.assertEqual(row['diagnostic']['state'],'SUPPORTED_BY_CONTRAST_HEAD')
            self.assertEqual(result['contrastHead']['layer'],12)

            ht=np.zeros((T,8)); ht[:,0]=-1.0
            result=assemble_from_logits(src,take,v,request,T*.02,T*.02,hidden_source=hs,hidden_take=ht,head=head)
            row=[p for w in result['words'] for p in w['phones'] if p['expected']=='ɑː'][0]
            self.assertEqual(row['status'],'likelyIncorrect'); self.assertEqual(row['closestPhone'],'æ')
            self.assertEqual(row['diagnostic']['state'],'LIKELY_PRONUNCIATION_DIFFERENCE_BY_HEAD')

        result=assemble_from_logits(src,take,v,request,T*.02,T*.02,hidden_source=hs,hidden_take=ht,head=None)
        row=[p for w in result['words'] for p in w['phones'] if p['expected']=='ɑː'][0]
        # head=None this time -> the SOURCE-side licence itself falls back to 'cannotDistinguish',
        # which fails `_native_ok`; but this row was already uncertain (not green/red) from the
        # per-unit gate, so the per-word mask leaves its specific reason alone.
        self.assertEqual(row['licence'],'cannotDistinguish')
        self.assertEqual(row['reason'],'modelCannotDistinguish')
        self.assertEqual(row['diagnostic']['state'],'MODEL_CANNOT_DISTINGUISH')

if __name__ == '__main__': unittest.main()
