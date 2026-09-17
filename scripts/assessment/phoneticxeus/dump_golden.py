#!/usr/bin/env python
"""Golden-fixture generator for the XEUS native ONNX port (Task 2).

Every number in the fixtures this script writes is the REAL output of the CURRENT Python
scoring pipeline (`evidence.py` + `runtime.py` + `uk_contrast_head.py`), run either on real
audio through the real XEUS model, or through the exact synthetic CTC matrices already used
by `test_evidence.py`. Nothing here is hand-computed or guessed: the Swift port (Tasks 3-9)
diffs its own output against these files for exact decision parity.

This script only READS evidence.py/runtime.py/reference.py/uk_contrast_head.py — it never
edits them. They remain the golden reference implementation.

Two families of fixtures are produced, both under ToSpeechTests/Fixtures/XeusNative/:

  1. Clip-level goldens (real audio -> real model -> real decision):
     <clip>.logits.npy       - float32 [frames, 428] CTC log-probabilities for that audio clip.
     <clip>.decisions.json   - one or more full `runtime.assemble_from_logits(...)` results
                                that use that clip's logits as source and/or take, e.g.
                                "vest-uk.decisions.json" (source-self) and
                                "vest-uk-vs-west-uk.decisions.json" (source=vest-uk,
                                take=west-uk logits.npy - the real /v/->/w/ substitution).
     See manifest.json for the exact source/take logits file each decisions.json used.

  2. Unit-level goldens (synthetic CTC matrices, no model, mirrors test_evidence.py cases):
     ctc-golden.json      - evidence.path() on small hand-built log-prob matrices.
     lattice-golden.json  - evidence.align_variants()/align_units()/build_units().
     assess-golden.json   - evidence.assess_phones() (+ evidence.coverage()).

Usage:
    python dump_golden.py                  # full run: unit goldens + real-audio clip goldens
    python dump_golden.py --skip-model      # unit goldens + the pre-saved "okay" clip only

Environment (matches the 2026-09-16 XEUS native ONNX port dev setup):
    XEUS_CODE_DIR  - directory containing src/model/xeusphoneme/... (default: the snapshot at
                      /tmp/echolab-phoneticxeus-20260913/model)
    XEUS_WEIGHTS   - path to model.safetensors (default: the app container's PhoneticXeus
                      package, revision 8d83dee94817a07dc150f87d08f7e0ee01bdb66d)
    XEUS_AUDIO_DIR - directory holding vest-uk.caf/west-uk.caf/full-source.caf (default:
                      docs/evidence/pronunciation-2026-09-12 under the repo root, which is a
                      local-only, untracked directory - see repo docs policy)
"""
import argparse, itertools, json, math, os, subprocess, sys
from collections import OrderedDict
from pathlib import Path

os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('TRANSFORMERS_OFFLINE', '1')
os.environ.setdefault('HF_HUB_DISABLE_TELEMETRY', '1')

import numpy as np

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent.parent
sys.path.insert(0, str(HERE))

from evidence import (  # noqa: E402 - sys.path must be set up first
    path, align_variants, align_units, accepted, conditional, build_units, assess_phones,
    realization_likelihood, coverage, THRESHOLDS, MAPPING, POLICY, CONFUSION,
)
import runtime  # assemble_from_logits; module-level import is torch-free (see serve.py docstring)

FIXTURES_DIR = REPO_ROOT / 'ToSpeechTests' / 'Fixtures' / 'XeusNative'
LEGACY_FIXTURES = HERE / 'fixtures'
DEFAULT_CODE_DIR = os.environ.get('XEUS_CODE_DIR', '/tmp/echolab-phoneticxeus-20260913/model')
DEFAULT_WEIGHTS = os.environ.get('XEUS_WEIGHTS',
    "/Users/nat/Library/Containers/com.unknownstudio.tospeech/Data/Library/Application Support/"
    "ToSpeech/Production/Packages/PhoneticXeus/8d83dee94817a07dc150f87d08f7e0ee01bdb66d/model.safetensors")
DEFAULT_AUDIO_DIR = os.environ.get('XEUS_AUDIO_DIR', str(REPO_ROOT / 'docs/evidence/pronunciation-2026-09-12'))


# --------------------------------------------------------------------------------------------
# JSON-safety: allow_nan=False catches accidental NaN/Inf everywhere except the handful of
# CTC cases that legitimately produce -inf (an impossible alignment). Those are converted to
# quoted sentinel strings ("-Infinity"/"Infinity"/"NaN") - valid JSON, explicit on both ends.
# --------------------------------------------------------------------------------------------
def jsonable(obj):
    if isinstance(obj, bool):
        return obj
    if isinstance(obj, float):
        if math.isnan(obj): return 'NaN'
        if math.isinf(obj): return 'Infinity' if obj > 0 else '-Infinity'
        # 12 decimal digits is far below any reasonable Swift-side comparison tolerance, and
        # keeps the fixtures legible/diffable instead of full float64 repr noise.
        return round(obj, 12)
    if isinstance(obj, np.floating):
        return jsonable(float(obj))
    if isinstance(obj, np.integer):
        return int(obj)
    if isinstance(obj, np.ndarray):
        return jsonable(obj.tolist())
    if isinstance(obj, dict):
        return {str(k): jsonable(v) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [jsonable(v) for v in obj]
    return obj


def dump_json(obj, out_path):
    out_path.write_text(json.dumps(jsonable(obj), ensure_ascii=False, indent=2, allow_nan=False, sort_keys=False))
    print(f'wrote {out_path.relative_to(REPO_ROOT)}')


# --------------------------------------------------------------------------------------------
# Synthetic log-prob matrices, byte-for-byte the same recipe as test_evidence.py's `self.lp`:
# start from a floor of 1e-8 everywhere, overwrite the given token probabilities, renormalize
# each frame to sum to 1, then take the log. `rows` is dumped alongside the resolved matrix so
# the fixture is both human-legible (which tokens were set to which probability) and exact
# (the actual float64 log-prob matrix `path`/`align_variants`/`assess_phones` consumed).
# --------------------------------------------------------------------------------------------
VOCAB_SIZE = 428
FLOOR = 1e-8


def lp_from_rows(rows, vocab_size=VOCAB_SIZE, floor=FLOOR):
    p = np.full((len(rows), vocab_size), floor)
    for i, values in enumerate(rows):
        for token, prob in values.items():
            p[i, token] = prob
    p /= p.sum(1, keepdims=True)
    return np.log(p)


def rows_repeated(spec, count):
    return [dict(spec) for _ in range(count)]


# ==============================================================================================
# ctc-golden.json - evidence.path()
# ==============================================================================================
def build_ctc_golden():
    cases = []

    # Case 1: forward algorithm matches brute-force enumeration over every frame path, for a
    # target, its double, an ordering swap and the empty target. Mirrors
    # test_forward_matches_exhaustive_paths_and_repeats.
    rows = [{0: .4, 4: .4, 5: .2}, {0: .3, 4: .3, 5: .4}, {0: .2, 4: .5, 5: .3}]
    lp = lp_from_rows(rows)
    targets = [[], [4], [4, 4], [4, 5], [5, 4]]
    results = []
    for target in targets:
        score = path(lp, target)
        # Cross-check against brute-force enumeration, exactly like the unit test does, so a
        # regression in `path` cannot silently produce a wrong golden.
        total = 0.0
        for seq in itertools.product([0, 4, 5], repeat=len(rows)):
            collapsed = [x for x, _ in itertools.groupby(seq) if x != 0]
            if collapsed == target:
                total += math.exp(sum(lp[t, k] for t, k in enumerate(seq)))
        assert total == 0 or abs(math.exp(score) - total) < 1e-9, (target, score, total)
        results.append(dict(target=target, score=score))
    cases.append(dict(
        name='forward_matches_exhaustive_paths_and_repeats',
        description='CTC forward-algorithm log-likelihood for several targets over the same 3-frame lattice; '
                    'cross-checked against brute-force enumeration of every frame path.',
        rows=rows, lp=lp, cases=results))

    # Case 2: a target that repeats a label with no room for the mandatory blank between the
    # two occurrences is impossible; path() must report -inf / no trace. Mirrors
    # test_impossible_repeat_rejected.
    rows2 = [{4: 1}, {4: 1}]
    lp2 = lp_from_rows(rows2)
    score2, spans2 = path(lp2, [4, 4], trace=True)
    assert math.isinf(score2) and score2 < 0 and spans2 is None
    cases.append(dict(
        name='impossible_repeat_rejected',
        description='Two frames cannot host [4,4] (repeated label needs an intervening blank frame): '
                    'score is -inf and trace is null.',
        rows=rows2, lp=lp2, target=[4, 4], trace=True, score=score2, spans=spans2))

    # Case 3: realization_likelihood sums disjoint collapsed sequences without double-counting,
    # cross-checked against brute-force enumeration. Mirrors
    # test_realization_probability_sums_disjoint_ctc_sequences_once.
    rows3 = [{0: .4, 4: .3, 5: .3}, {0: .2, 4: .4, 5: .4}]
    lp3 = lp_from_rows(rows3)
    sequences = [[4], [5], [4]]  # [4] appears twice; must be counted once
    score3 = realization_likelihood(lp3, sequences)
    total3 = 0.0
    for seq in itertools.product([0, 4, 5], repeat=2):
        collapsed = [x for x, _ in itertools.groupby(seq) if x != 0]
        if collapsed in [[4], [5]]:
            total3 += math.exp(sum(lp3[t, k] for t, k in enumerate(seq)))
    assert abs(math.exp(score3) - total3) < 1e-9
    cases.append(dict(
        name='realization_likelihood_sums_disjoint_sequences_once',
        description='realization_likelihood([[4],[5],[4]]) must equal the probability of collapsed '
                    'output in {[4],[5]}, not double-counting the repeated [4] sequence.',
        rows=rows3, lp=lp3, sequences=sequences, score=score3))

    # Case 4: a positive trace, used by the higher-level alignment code to recover phone spans.
    # Mirrors the trace half of test_wrong_target_not_green_just_because_alignment_succeeds.
    rows4 = [{0: .95, 5: .05}, {5: .98, 4: .001}, {5: .95, 4: .001}, {0: .99}]
    lp4 = lp_from_rows(rows4)
    score4, spans4 = path(lp4, [4], trace=True)
    assert spans4 is not None
    cases.append(dict(
        name='trace_recovers_emission_span_for_a_present_target',
        description='Even though the dominant label is 5 (not the target 4), the target 4 has enough mass '
                    'in frames 1-2 for a finite-probability alignment with a recoverable span.',
        rows=rows4, lp=lp4, target=[4], trace=True, score=score4, spans=spans4))

    return cases


# ==============================================================================================
# lattice-golden.json - evidence.align_variants() / align_units() / build_units()
# ==============================================================================================
def build_lattice_golden():
    cases = []

    # Case 1: global Viterbi lattice selects the whole-variant combination with the best total
    # score, verified against exhaustive search over every (word, variant) combination on a
    # concrete, fixed probability matrix (the first draw of the same seeded RNG
    # test_lattice_selects_whole_variants_against_exhaustive_viterbi uses, persisted here so the
    # fixture never depends on numpy's RNG algorithm at Swift-test time).
    vocab1 = {'<blank>': 0, 'b': 4, 'd': 5, 'v': 6}
    words1 = [[['b', 'd'], ['d', 'b']], [['b'], ['v', 'd']]]
    rng = np.random.default_rng(17)
    p = rng.dirichlet([1, 1, 1, 1], size=7)
    rows1 = [dict(zip([0, 4, 5, 6], row)) for row in p]
    lp1 = lp_from_rows(rows1)
    selected1, spans1 = align_variants(lp1, words1, vocab1)

    def score_combo(indices):
        ids = [vocab1[ph] for w, i in zip(words1, indices) for ph in w[i]]
        return path(lp1, ids, True)[0]
    combos = list(itertools.product(range(2), repeat=2))
    best = max(combos, key=score_combo)
    assert selected1 == list(best) or abs(score_combo(selected1) - score_combo(best)) < 1e-9
    cases.append(dict(
        name='lattice_selects_whole_variants_against_exhaustive_viterbi',
        description='Global Viterbi over 2 words x 2 dictionary variants each; the chosen variant indices '
                    'must match the best-scoring combination out of all 4 by exhaustive search. lp is the '
                    'first Dirichlet([1,1,1,1]) draw of numpy default_rng(17), persisted as concrete floats.',
        vocab=vocab1, words=words1, rows=rows1, lp=lp1, selected=selected1, spans=spans1,
        bestComboByExhaustiveSearch=list(best)))

    # Case 2a/2b: a phone repeated across adjacent words needs an intervening blank frame,
    # exactly like a repeated phone within one word. Mirrors
    # test_repeated_phones_across_words_need_blank.
    vocab2 = {'<blank>': 0, 'v': 4}
    words2 = [[['v']], [['v']]]
    lp2a = lp_from_rows([{4: 1}, {4: 1}])
    result2a = align_variants(lp2a, words2, vocab2)
    assert result2a is None
    lp2b = lp_from_rows([{4: 1}, {0: 1}, {4: 1}])
    selected2b, spans2b = align_variants(lp2b, words2, vocab2)
    assert spans2b == [[[0, 1]], [[2, 3]]]
    cases.append(dict(
        name='repeated_phones_across_words_need_blank',
        description='word "v" then word "v" again: with no blank frame between them the lattice cannot '
                    'align (word boundary does not substitute for the CTC blank); with a blank frame it aligns.',
        vocab=vocab2, words=words2,
        withoutBlank=dict(lp=lp2a, result=result2a),
        withBlank=dict(lp=lp2b, selected=selected2b, spans=spans2b)))

    # Case 3: a split affricate (/tʃ/ realized as separate [t][ʃ] tokens) is one target phone
    # whose emission span covers both underlying frames. Mirrors
    # test_split_affricate_is_one_phone_with_both_emissions (alignment half).
    vocab3 = {'<blank>': 0, 't͡ʃ': 4, 't': 5, 'ʃ': 6, 'ə': 7}
    words3 = [[['tʃ', 'ə']]]
    lp3 = lp_from_rows([{0: .99}, {5: .99}, {6: .99}, {0: .99}, {7: .99}, {0: .99}])
    selected3, spans3 = align_variants(lp3, words3, vocab3)
    assert spans3[0][0] == [1, 3]
    cases.append(dict(
        name='split_affricate_span_covers_both_emissions',
        description='/tʃ/ realized as separate [t] then [ʃ] frames is still one target phone; its emission '
                    'span must cover both frames ([1,3]), not just one.',
        vocab=vocab3, words=words3, lp=lp3, selected=selected3, spans=spans3))

    # Case 4: build_units + align_units - a pair unit (schwa+rhotic, e.g. NURSE realized as
    # r-colored schwa) localizes on a single rhotic token via its class-D `cond` set, distinct
    # from its `allowed` set used for grading. Mirrors
    # test_align_units_locates_pair_unit_on_single_rhotic_token and
    # test_build_units_merges_schwa_r_pair_and_marks_word_initial.
    vocab4 = {'<blank>': 0, 'l': 4, 'ɪ': 5, 't': 6, 'ə': 7, 'ɹ': 8, 'ɜ˞': 9}
    phones4 = ['l', 'ɪ', 't', 'ə', 'ɹ']
    units4 = build_units([('w', phones4)], vocab4)
    lp4 = lp_from_rows([{4: .99}, {5: .99}, {6: .99}, {0: .99}, {9: .99}, {0: .99}])
    default_spans = align_units(lp4, units4)
    licensed_spans = align_units(lp4, units4, [[], [], [], [[9]], []])
    assert licensed_spans[3] == [4, 5]
    unit_summary = [dict(display=u.display, indices=u.indices, wordInitial=u.word_initial,
                          allowed=u.allowed, cond=u.cond, id=u.id) for u in units4]
    cases.append(dict(
        name='pair_unit_localizes_on_single_rhotic_token_via_licensed_class_d',
        description='build_units merges the schwa+/ɹ/ pair (positions 3-4 of "l ɪ t ə ɹ") into one unit; '
                    'without licensing the class-D [ɜ˞] realization the pair unit cannot align on the single '
                    'r-colored-schwa frame, but with it licensed as `extra`, align_units locates it at [4,5].',
        vocab=vocab4, phones=phones4, units=unit_summary, lp=lp4,
        withoutLicensedExtra=dict(spans=default_spans),
        withLicensedExtraForPairUnit=dict(extra=[[], [], [], [[9]], []], spans=licensed_spans)))

    return cases


# ==============================================================================================
# assess-golden.json - evidence.assess_phones() (+ evidence.coverage())
# ==============================================================================================
def _phone_case(name, description, rows, phones, vocab, duration, thresholds=None, **extra):
    lp = lp_from_rows(rows, vocab_size=VOCAB_SIZE)
    kwargs = dict(step=.02)
    if thresholds is not None:
        kwargs['thresholds'] = thresholds
    result = assess_phones(lp, phones, vocab, duration, **kwargs)
    case = dict(name=name, description=description, rows=rows, vocab=vocab, phones=phones,
                duration=duration, lp=lp, result=result)
    if thresholds is not None:
        case['thresholds'] = thresholds
    case.update(extra)
    return case


def vocab428(**names):
    vocab = {f'x{i}': i for i in range(428)}
    vocab['<blank>'] = 0
    vocab.update(names)
    return vocab


def build_assess_golden():
    cases = []

    # 1. A confusable substitution (θ target, s observed) with successful alignment must not be
    # graded correct just because the lattice could align the wrong sound. θ/s IS in the v6
    # confusion table, so this reaches `likelyIncorrect`. Mirrors
    # test_wrong_target_not_green_just_because_alignment_succeeds.
    v1 = vocab428(**{'θ': 4, 's': 5})
    c1 = _phone_case(
        'wrong_target_not_green_just_because_alignment_succeeds',
        'θ target, confident s (a confusable competitor) observed throughout: alignment succeeds but the '
        'status must not be "correct"; closestPhone reports the observed competitor.',
        [{0: .95, 5: .05}, {5: .98, 4: .001}, {5: .95, 4: .001}, {0: .99}], ['θ'], v1, .08)
    assert c1['result'][0]['status'] != 'correct'
    assert c1['result'][0]['closestPhone'] == 's'
    cases.append(c1)

    # 2. Blank-only, and evenly-split-ambiguous, targets are both "uncertain" (never "correct").
    # Mirrors test_blank_only_and_ambiguous_are_not_correct.
    v2 = vocab428(**{'θ': 4, 's': 5})
    for label, rows in [('blank_only', rows_repeated({0: .9999}, 5)),
                         ('ambiguous_split', rows_repeated({4: .39, 5: .41, 0: .2}, 5))]:
        c = _phone_case(f'not_correct_when_{label}',
            f'{"No non-blank evidence at all" if label == "blank_only" else "Evenly split between θ and s, neither dominant"}: '
            'status must be "uncertain", never "correct".', rows, ['θ'], v2, .1)
        assert c['result'][0]['status'] == 'uncertain'
        cases.append(c)

    # 3. A length-only difference (iː target realized without the length mark, as [i]) is an
    # accepted Class-A quality-preserving realization: correct. Mirrors
    # test_length_only_difference_is_accepted_quality.
    v3 = vocab428(**{'iː': 4, 'i': 5})
    c3 = _phone_case('length_only_difference_is_accepted_quality',
        'Target iː realized without the length mark ([i]) is still the same UK vowel quality: correct.',
        [{0: .95}, {5: .98, 4: .001}, {5: .95, 4: .001}, {0: .99}], ['iː'], v3, .08)
    assert c3['result'][0]['status'] == 'correct'
    cases.append(c3)

    # 4. Dark-l ([l̴]) is a Class-C allophone of /l/, not a different UK phoneme: never
    # likelyIncorrect. Mirrors test_dark_l_is_not_a_different_uk_phoneme.
    v4 = vocab428(**{'l': 4, 'l̴': 5})
    c4 = _phone_case('dark_l_is_not_a_different_uk_phoneme',
        'Target /l/ realized as dark-l [l̴] is an accepted allophone: must not be likelyIncorrect.',
        [{0: .95}, {5: .98, 4: .001}, {5: .95, 4: .001}, {0: .99}], ['l'], v4, .08)
    assert c4['result'][0]['status'] != 'likelyIncorrect'
    cases.append(c4)

    # 5. The v6 confusion gate: likelyIncorrect fires ONLY when the observed competitor is in
    # the expected phone's confusion set. /v/->/w/ is a real, confusable L2 substitution;
    # /v/->x99 (an arbitrary non-confusable id) abstains as "uncertain"/"ambiguousSubstitution"
    # instead of being marked wrong. Mirrors test_confusion_gate_flags_only_confusable_substitutions.
    assert 'w' in CONFUSION['v']
    v5a = vocab428(**{'v': 4, 'w': 5})
    c5a = _phone_case('confusion_gate_flags_confusable_v_w_substitution',
        'Target /v/, confident competitor /w/ (a real, confusable L2 substitution present in CONFUSION): '
        'likelyIncorrect.',
        [{0: .99}, {5: .98, 4: .001}, {5: .98, 4: .001}, {0: .99}], ['v'], v5a, .08)
    assert c5a['result'][0]['status'] == 'likelyIncorrect'
    cases.append(c5a)
    v5b = vocab428(**{'v': 4})
    c5b = _phone_case('confusion_gate_abstains_on_non_confusable_competitor',
        'Target /v/, confident competitor token 99 (not in CONFUSION[\'v\']): the raw scorer abstains as '
        '"uncertain"/"ambiguousSubstitution" rather than marking it wrong.',
        [{0: .99}, {99: .98, 4: .001}, {99: .98, 4: .001}, {0: .99}], ['v'], v5b, .08)
    assert c5b['result'][0]['status'] == 'uncertain' and c5b['result'][0]['reason'] == 'ambiguousSubstitution'
    cases.append(c5b)

    # 6. A weak-form reduction (unstressed /ʊ/ said as schwa) is an accepted Class-D
    # conditional realization: never likelyIncorrect. Mirrors
    # test_weak_form_and_length_never_incorrect.
    v6 = vocab428(**{'ʊ': 4, 'ə': 5})
    assert [v6['ə']] in conditional('ʊ', v6)
    c6 = _phone_case('weak_form_schwa_reduction_never_incorrect',
        'Target /ʊ/ (as in weak "you") realized as schwa: an accepted weak-form reduction, never likelyIncorrect.',
        [{0: .99}, {5: .98, 4: .001}, {5: .95, 4: .001}, {0: .99}], ['ʊ'], v6, .08)
    assert c6['result'][0]['status'] != 'likelyIncorrect'
    cases.append(c6)

    # 7. Split affricate grading: /tʃ/ as separate [t][ʃ] frames is graded correct as one shared
    # unit (both expanded phone rows report "correct"). Mirrors the assess half of
    # test_split_affricate_is_one_phone_with_both_emissions.
    v7 = vocab428(**{'t͡ʃ': 4, 't': 5, 'ʃ': 6, 'ə': 7})
    c7 = _phone_case('split_affricate_is_one_phone_with_both_emissions',
        '/tʃə/ with /tʃ/ realized as separate [t][ʃ] frames: both expanded rows (tʃ, ə) report "correct".',
        [{0: .99}, {5: .99}, {6: .99}, {0: .99}, {7: .99}, {0: .99}], ['tʃ', 'ə'], v7, .12)
    assert [r['status'] for r in c7['result']] == ['correct', 'correct']
    assert [5] not in accepted('tʃ', v7)  # a lone stop cannot be the complete affricate
    cases.append(c7)

    # 8. Probability split between two accepted realizations of the same phoneme (aspirated vs.
    # unaspirated /k/) is not an error, even though neither single token crosses the per-token
    # floor; a confident, non-confusable-set wrong token is. Mirrors
    # test_split_probability_between_accepted_k_realizations_is_not_a_phone_error.
    v8 = vocab428(**{'k': 4, 'kʰ': 5, 'ɡ': 6})
    c8a = _phone_case('k_probability_split_between_accepted_realizations_is_not_an_error',
        'Probability mass split ~44/55 between [k] and [kʰ] (both accepted realizations of /k/): correct, '
        'even though expectedTokenProbability alone is well under 0.60.',
        [{0: .999}, {4: .4426, 5: .5466, 6: .001}, {0: .999}], ['k'], v8, .06)
    assert c8a['result'][0]['status'] == 'correct'
    assert c8a['result'][0]['expectedProbability'] > .98
    assert c8a['result'][0]['expectedTokenProbability'] < .60
    cases.append(c8a)
    c8b = _phone_case('k_confident_wrong_competitor_is_not_correct',
        'Confident, dominant [ɡ] where /k/ was expected (ɡ/k are a confusable devoicing pair): not correct.',
        [{0: .999}, {4: .04, 5: .04, 6: .92}, {0: .999}], ['k'], v8, .06)
    assert c8b['result'][0]['status'] != 'correct'
    cases.append(c8b)

    # 9. A missing glide cannot borrow probability mass from the first vowel of a diphthong: an
    # incomplete /eɪ/ (only the [e] onset present, split with its nasalized variant, no [ɪ]
    # offglide at all) is not correct. Mirrors test_missing_glide_cannot_borrow_from_first_vowel.
    v9 = vocab428(**{'e': 4, 'ɪ': 5, 'ẽ': 6, 'ɪ̃': 7})
    c9 = _phone_case('missing_glide_cannot_borrow_from_first_vowel',
        'Target /eɪ/ with only the [e]/[ẽ] onset present (0.48+0.48) and no [ɪ] offglide at all: not correct.',
        [{0: .999}, {4: .48, 6: .48}, {0: .999}, {0: .999}], ['eɪ'], v9, .08)
    assert c9['result'][0]['status'] != 'correct'
    cases.append(c9)

    # 10. The support floor (0.30) admits a single strong frame spread thin by 20 near-uniform
    # low-probability competitors, given a strong margin; a stricter support threshold (0.60)
    # correctly rejects the same evidence. Mirrors
    # test_support_floor_thirty_admits_one_frame_spike_with_strong_margin.
    v10 = vocab428(**{'ð': 4, 'h': 5})
    spread = {10 + i: .0275 for i in range(20)}
    rows10 = [{0: .99}, {**{4: .45}, **spread}, {0: .99}]
    c10_default = _phone_case('support_floor_default_admits_thin_but_present_evidence',
        'A single frame at 0.45 for the target plus 20 near-uniform low-probability competitors clears the '
        'default support floor (0.30) given a strong margin: correct, even though expectedProbability < 0.60.',
        rows10, ['ð'], v10, .06)
    assert c10_default['result'][0]['status'] == 'correct'
    assert c10_default['result'][0]['expectedProbability'] < .60
    strict_thresholds = dict(THRESHOLDS, support=.60)
    c10_strict = _phone_case('support_floor_stricter_threshold_rejects_the_same_evidence',
        'The identical evidence as support_floor_default_admits_thin_but_present_evidence, graded with '
        'support raised to 0.60: uncertain.',
        rows10, ['ð'], v10, .06, thresholds=strict_thresholds)
    assert c10_strict['result'][0]['status'] == 'uncertain'
    cases.append(c10_default)
    cases.append(c10_strict)

    # 11. assess_phones still rejects a confident wrong competitor (θ target, confident s, a
    # confusable pair) and an ambiguous split, in one call each. Mirrors
    # test_assess_phones_still_rejects_wrong_and_ambiguous.
    v11 = vocab428(**{'θ': 4, 's': 5})
    c11a = _phone_case('assess_phones_rejects_confident_wrong_competitor',
        'θ target, confident s throughout (confusable pair): likelyIncorrect.',
        [{0: .95, 5: .05}, {5: .98, 4: .001}, {5: .95, 4: .001}, {0: .99}], ['θ'], v11, .08)
    assert c11a['result'][0]['status'] == 'likelyIncorrect'
    cases.append(c11a)
    c11b = _phone_case('assess_phones_rejects_ambiguous_split_as_uncertain',
        'θ target, evenly split θ/s evidence: uncertain.',
        rows_repeated({4: .39, 5: .41, 0: .2}, 5), ['θ'], v11, .1)
    assert c11b['result'][0]['status'] == 'uncertain'
    cases.append(c11b)

    # 12. Multi-phone word: source-variant selection prefers the dictionary variant the audio
    # actually matches (nasalization on /æ/, /uː/ vs /u/ before /t/), then every phone grades
    # correct. Mirrors test_source_variant_selection_uses_nasalization_and_keeps_length_ungraded
    # (assess_phones half; variant selection itself belongs to align_variants/lattice, exercised
    # separately in lattice-golden.json).
    v12 = vocab428(**{'k': 4, 'kʰ': 5, 'ə': 6, 'æ': 7, 'æ̃': 8, 'n': 9, 't': 10, 'tʰ': 11, 'uː': 12, 'u': 13, 'ʊ': 14})
    lp12 = lp_from_rows([{0: 1}, {5: .99}, {8: .99}, {9: .99}, {0: 1}, {11: .99}, {13: .99}, {0: 1}], vocab_size=VOCAB_SIZE)
    result12 = assess_phones(lp12, ['k', 'æ', 'n', 't', 'uː'], v12, .16)
    assert result12[1]['status'] == 'correct' and result12[-1]['status'] == 'correct'
    cases.append(dict(name='multi_phone_word_grades_every_phone_after_variant_realization',
        description='"can" realized as [kʰ æ̃ n], "too" realized as [tʰ u]: every phone (including the '
                    'nasalized /æ/ and the length-less /uː/) grades correct.',
        vocab=v12, phones=['k', 'æ', 'n', 't', 'uː'], duration=.16, rows=None, lp=lp12, result=result12))

    coverage_cases = build_coverage_cases()
    return cases, coverage_cases


def build_coverage_cases():
    # Pure-function goldens for evidence.coverage(): total/scored/correct/incorrect/unassessed
    # counts and the coverage fraction, plus the zero-rows edge case. Mirrors
    # test_coverage_counts_scored_fraction and test_coverage_zero_when_no_rows.
    cases = []
    rows_a = [{'status': 'correct'}, {'status': 'likelyIncorrect'}, {'status': 'uncertain'}, {'status': 'correct'}]
    result_a = coverage(rows_a)
    assert result_a == dict(total=4, scored=3, correct=2, incorrect=1, unassessed=1, coverage=.75)
    cases.append(dict(name='coverage_counts_scored_fraction',
        description='2 correct + 1 likelyIncorrect + 1 uncertain: scored=3/4, coverage=0.75.',
        rows=rows_a, result=result_a))
    rows_b = []
    result_b = coverage(rows_b)
    assert result_b == dict(total=0, scored=0, correct=0, incorrect=0, unassessed=0, coverage=0.0)
    cases.append(dict(name='coverage_zero_when_no_rows',
        description='No rows at all: every count is 0 and coverage is 0.0 (not a division-by-zero error).',
        rows=rows_b, result=result_b))
    return cases


# ==============================================================================================
# Clip-level goldens: real audio -> real XEUS model -> real runtime.assemble_from_logits()
# ==============================================================================================
def resolve_vocab_path(code_dir):
    candidates = [
        REPO_ROOT / 'scripts/assessment/phoneticxeus/ipa_vocab.json',
        Path(code_dir) / 'src/model/xeusphoneme/resources/ipa_vocab.json',
    ]
    for c in candidates:
        if c.exists():
            return c
    raise SystemExit('ipa_vocab.json not found; checked: ' + ', '.join(str(c) for c in candidates))


def load_model(code_dir, weights_path, device='cpu'):
    """Mirrors runtime.load()'s body, decoupled into separate code/weights paths (this dev
    environment keeps them apart: code+resources are a source snapshot, weights are the app
    container's downloaded, verified package - see module docstring). Reuses runtime.head_path()
    and uk_contrast_head.ContrastHead as-is; does not reimplement any scoring logic."""
    import torch
    from safetensors.torch import load_file
    from uk_contrast_head import ContrastHead
    code = Path(code_dir)
    sys.path.insert(0, str(code))
    from src.model.xeusphoneme.builders import build_xeus_pr_from_hf
    config = code / 'src/model/xeusphoneme/resources/xeus_config.yaml'
    vocabulary = resolve_vocab_path(code_dir)
    vocab = json.loads(vocabulary.read_text())
    if len(vocab) != 428 or vocab.get('<blank>') != 0:
        raise ValueError('unexpected vocabulary contract')
    model = build_xeus_pr_from_hf(work_dir=str(code), hf_repo=None, config_file=str(config),
                                   vocab_file=str(vocabulary), load_ckpt=False, interctc_use_conditioning=True)
    tensors = load_file(str(weights_path), device='cpu')
    model.load_state_dict({k.removeprefix('model.'): v for k, v in tensors.items()}, strict=True)
    del tensors
    model = model.eval().to(device)
    head_hidden = {'value': None}
    head = ContrastHead.load(runtime.head_path())
    if head is not None:
        layers = list(model.encoder.encoders)
        if not 1 <= head.layer <= len(layers):
            print(f'ContrastHead layer {head.layer} out of range for {len(layers)} encoder layers; disabling head',
                  file=sys.stderr)
            head = None
        else:
            def hook(module, inputs, output):
                x = output[0] if isinstance(output, tuple) else output
                x = x[0] if isinstance(x, tuple) else x
                head_hidden['value'] = x.detach()[0].float().cpu().numpy()
            layers[head.layer - 1].register_forward_hook(hook)
    return model, vocab, head, head_hidden


def infer_with_hidden(model, samples, device, head, head_hidden):
    import torch
    samples = np.asarray(samples, dtype=np.float32)
    if samples.ndim != 1 or not 800 <= len(samples) <= 480000 or not np.isfinite(samples).all():
        raise ValueError(f'invalid input shape/range: {samples.shape}; mono 16k, 0.05-30 seconds required')
    values = torch.from_numpy(samples.copy()).unsqueeze(0).to(device)
    lengths = torch.tensor([len(samples)], device=device)
    head_hidden['value'] = None
    with torch.inference_mode():
        hidden, _ = model.encode(values, lengths)
        if isinstance(hidden, tuple):
            hidden = hidden[0]
        logits = model.ctc.ctc_lo(hidden)
        if logits.shape[0] != 1 or logits.shape[-1] != 428:
            raise ValueError(f'output shape {list(logits.shape)}')
        lp = logits.log_softmax(-1)[0].cpu().numpy()
    h = head_hidden['value']
    if h is not None and (h.ndim != 2 or len(h) != len(lp) or (head and h.shape[1] != head.dim)):
        h = None
    return lp, h


def decode_audio(caf_path, out_f32):
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(caf_path),
                     '-ar', '16000', '-ac', '1', '-f', 'f32le', str(out_f32)], check=True)
    return np.fromfile(out_f32, dtype='<f4')


# Real transcripts for the docs/evidence/pronunciation-2026-09-12 clips, hand-transcribed to
# evidence.py's UK phone inventory from the dictionary IPA already recorded in that directory's
# vest-uk.json/west-for-vest.json ("Please wear the vest.") and omitted-word.json's
# sourceAudioChecksum match to full-source.caf ("I never thought it would make such a
# difference."). Multiple variants are supplied for a few words exactly like production
# requests do, so align_variants() picks whichever the audio actually realized.
VEST_WORDS = [
    dict(id='caption-0-word-0', text='Please', variants=[['p', 'l', 'iː', 'z']]),
    dict(id='caption-0-word-1', text='wear', variants=[['w', 'eə'], ['w', 'ɛ', 'ɹ']]),
    dict(id='caption-0-word-2', text='the', variants=[['ð', 'ə'], ['ð', 'iː']]),
    dict(id='caption-0-word-3', text='vest', variants=[['v', 'ɛ', 's', 't']]),
]
FULL_SOURCE_WORDS = [
    dict(id='w0', text='I', variants=[['aɪ']]),
    dict(id='w1', text='never', variants=[['n', 'ɛ', 'v', 'ə']]),
    dict(id='w2', text='thought', variants=[['θ', 'ɔː', 't']]),
    dict(id='w3', text='it', variants=[['ɪ', 't']]),
    dict(id='w4', text='would', variants=[['w', 'ʊ', 'd']]),
    dict(id='w5', text='make', variants=[['m', 'eɪ', 'k']]),
    dict(id='w6', text='such', variants=[['s', 'ʌ', 'tʃ']]),
    dict(id='w7', text='a', variants=[['ə'], ['eɪ']]),
    dict(id='w8', text='difference', variants=[['d', 'ɪ', 'f', 'ɹ', 'ə', 'n', 's'],
                                                ['d', 'ɪ', 'f', 'ə', 'ɹ', 'ə', 'n', 's']]),
]


def build_clip_goldens(skip_model, code_dir, weights_path, audio_dir, device, work_dir):
    manifest = OrderedDict()
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)

    # "okay" - reuse the already-saved real logits + request (no model call needed). This is
    # the exact same fixture test_runtime.py's OkayFixtureTests exercises.
    okay_logits_src = LEGACY_FIXTURES / 'okay-source-logits.npy'
    okay_request = json.loads((LEGACY_FIXTURES / 'okay-request.json').read_text())
    okay_lp = np.load(okay_logits_src)
    vocab_path = resolve_vocab_path(code_dir)
    vocab = json.loads(vocab_path.read_text())
    np.save(FIXTURES_DIR / 'okay.logits.npy', okay_lp.astype(np.float32))
    okay_result = runtime.assemble_from_logits(okay_lp, okay_lp, vocab, okay_request, 2.72, 2.72)
    rows = [p for w in okay_result['words'] for p in w['phones']]
    assert len(rows) == 16 and sum(r['status'] == 'correct' for r in rows) == 13
    dump_json(dict(caseName='okay-source-self', sourceLogits='okay.logits.npy', takeLogits='okay.logits.npy',
                    sourceDuration=2.72, takeDuration=2.72, request=okay_request, result=okay_result),
              FIXTURES_DIR / 'okay.decisions.json')
    manifest['okay.logits.npy'] = 'Real "Okay, let\'s get started." source logits (pre-saved fixture, reused).'
    manifest['okay.decisions.json'] = 'assemble_from_logits(okay, okay) - source-self, the OkayFixtureTests case.'

    if skip_model:
        print('--skip-model: only the pre-saved "okay" clip golden was generated. '
              'vest-uk/west-uk/full-source clip goldens (model-derived) are deferred.')
        return manifest

    audio_dir = Path(audio_dir)
    clips = {
        'vest-uk': audio_dir / 'vest-uk.caf',
        'west-uk': audio_dir / 'west-uk.caf',
        'full-source': audio_dir / 'full-source.caf',
    }
    missing = [name for name, p in clips.items() if not p.exists()]
    if missing:
        print(f'--skip-model not given, but audio missing for: {missing} (looked in {audio_dir}); '
              'deferring model-derived clip goldens.', file=sys.stderr)
        return manifest

    print(f'loading XEUS model from code={code_dir} weights={weights_path} device={device} ...')
    model, model_vocab, head, head_hidden = load_model(code_dir, weights_path, device)
    if model_vocab != vocab:
        raise SystemExit('vocab mismatch between model code dir and resolved ipa_vocab.json')

    clip_lp = {}
    for name, caf_path in clips.items():
        f32_path = work_dir / f'{name}.f32'
        samples = decode_audio(caf_path, f32_path)
        lp, hidden = infer_with_hidden(model, samples, device, head, head_hidden)
        clip_lp[name] = (lp, hidden, len(samples) / 16000)
        np.save(FIXTURES_DIR / f'{name}.logits.npy', lp.astype(np.float32))
        manifest[f'{name}.logits.npy'] = f'Real XEUS CTC log-probs [frames,428] for {caf_path.name} (16k mono, ffmpeg-decoded).'
        print(f'{name}: {lp.shape} frames, duration={len(samples) / 16000:.3f}s, '
              f"greedy='{' '.join(d['symbol'] for d in __import__('evidence').greedy(lp, {i: s for s, i in vocab.items()}, .02, len(samples) / 16000))}'")

    # vest-uk source-self.
    lp_v, hidden_v, dur_v = clip_lp['vest-uk']
    req_v = dict(source=str(clips['vest-uk']), take=str(clips['vest-uk']), words=VEST_WORDS)
    result_vv = runtime.assemble_from_logits(lp_v, lp_v, vocab, req_v, dur_v, dur_v,
                                              hidden_v, hidden_v, head, device, 0.0)
    dump_json(dict(caseName='vest-uk-source-self', sourceLogits='vest-uk.logits.npy', takeLogits='vest-uk.logits.npy',
                    sourceDuration=dur_v, takeDuration=dur_v, request=req_v, result=result_vv),
              FIXTURES_DIR / 'vest-uk.decisions.json')
    manifest['vest-uk.decisions.json'] = 'assemble_from_logits(vest-uk, vest-uk) - source-self, "Please wear the vest."'

    # full-source source-self.
    lp_f, hidden_f, dur_f = clip_lp['full-source']
    req_f = dict(source=str(clips['full-source']), take=str(clips['full-source']), words=FULL_SOURCE_WORDS)
    result_ff = runtime.assemble_from_logits(lp_f, lp_f, vocab, req_f, dur_f, dur_f,
                                              hidden_f, hidden_f, head, device, 0.0)
    dump_json(dict(caseName='full-source-source-self', sourceLogits='full-source.logits.npy',
                    takeLogits='full-source.logits.npy', sourceDuration=dur_f, takeDuration=dur_f,
                    request=req_f, result=result_ff),
              FIXTURES_DIR / 'full-source.decisions.json')
    manifest['full-source.decisions.json'] = ('assemble_from_logits(full-source, full-source) - source-self, '
                                               '"I never thought it would make such a difference."')

    # vest-uk (source) vs west-uk (take): the real /v/->/w/ substitution ("vest" said as "west").
    lp_w, hidden_w, dur_w = clip_lp['west-uk']
    req_vw = dict(source=str(clips['vest-uk']), take=str(clips['west-uk']), words=VEST_WORDS)
    result_vw = runtime.assemble_from_logits(lp_v, lp_w, vocab, req_vw, dur_v, dur_w,
                                              hidden_v, hidden_w, head, device, 0.0)
    vest_row = next(p for w in result_vw['words'] for p in w['phones'] if p['expected'] == 'v')
    print(f"v/w case: 'vest' /v/ row -> takeStatus={vest_row['takeStatus']} status={vest_row['status']} "
          f"reason={vest_row.get('takeReason')} closestPhone={vest_row.get('closestPhone')}")
    dump_json(dict(caseName='vest-uk-source-vs-west-uk-take', sourceLogits='vest-uk.logits.npy',
                    takeLogits='west-uk.logits.npy', sourceDuration=dur_v, takeDuration=dur_w,
                    request=req_vw, result=result_vw),
              FIXTURES_DIR / 'vest-uk-vs-west-uk.decisions.json')
    manifest['vest-uk-vs-west-uk.decisions.json'] = ('assemble_from_logits(vest-uk, west-uk) - real /v/->/w/ '
                                                       'substitution at "vest" (take audio says "west").')
    manifest['west-uk.logits.npy'] = 'Real XEUS CTC log-probs for west-uk.caf (used only as a take here).'

    return manifest


# ==============================================================================================
def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--skip-model', action='store_true',
                         help='Skip loading the XEUS model / real audio; only regenerate the "okay" clip '
                              'golden (pre-saved logits) plus all unit-level (ctc/lattice/assess) goldens.')
    parser.add_argument('--code-dir', default=DEFAULT_CODE_DIR)
    parser.add_argument('--weights', default=DEFAULT_WEIGHTS)
    parser.add_argument('--audio-dir', default=DEFAULT_AUDIO_DIR)
    parser.add_argument('--device', default='cpu', choices=['cpu', 'mps'])
    args = parser.parse_args()

    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    assert POLICY == 'xeus-uk-decision-v6-word-gated' and MAPPING == 'xeus-uk-inventory-v4', (
        'evidence.py policy/mapping changed since this generator was written; review every case above '
        'before trusting the regenerated goldens.')

    print('building unit-level goldens (no model needed) ...')
    ctc_cases = build_ctc_golden()
    dump_json(dict(policy=POLICY, mapping=MAPPING, vocabSize=VOCAB_SIZE, floor=FLOOR,
                    note='lp is np.log(rows-with-1e-8-floor, renormalized per frame), identical to '
                         "test_evidence.py's `self.lp` helper. Every case is cross-checked at "
                         'generation time against a brute-force / independent computation (see '
                         'dump_golden.py) - these are not just captured outputs.',
                    cases=ctc_cases),
              FIXTURES_DIR / 'ctc-golden.json')

    lattice_cases = build_lattice_golden()
    dump_json(dict(policy=POLICY, mapping=MAPPING, vocabSize=VOCAB_SIZE, floor=FLOOR,
                    note='lp reconstruction: see ctc-golden.json note. Case 1 pins a concrete lp matrix '
                         '(the first draw of numpy default_rng(17).dirichlet) so this fixture has no '
                         'dependency on reproducing numpy RNG behavior at Swift-test time.',
                    cases=lattice_cases),
              FIXTURES_DIR / 'lattice-golden.json')

    assess_cases, coverage_cases = build_assess_golden()
    dump_json(dict(policy=POLICY, mapping=MAPPING, vocabSize=VOCAB_SIZE, floor=FLOOR,
                    note='lp reconstruction: see ctc-golden.json note. `rows`==null means the case is a '
                         'purpose-built lp (documented inline) rather than the frame-dict recipe.',
                    phoneCases=assess_cases, coverageCases=coverage_cases),
              FIXTURES_DIR / 'assess-golden.json')

    print('building clip-level goldens ...')
    import tempfile
    with tempfile.TemporaryDirectory(prefix='xeus-golden-') as tmp:
        manifest = build_clip_goldens(args.skip_model, args.code_dir, args.weights, args.audio_dir,
                                       args.device, Path(tmp))

    dump_json(OrderedDict([
        ('generatedBy', 'scripts/assessment/phoneticxeus/dump_golden.py'),
        ('policy', POLICY), ('mapping', MAPPING),
        ('note', 'Fields inferenceSeconds/peakRSS/device/loadSeconds inside *.decisions.json are run- and '
                 'machine-dependent; Swift parity tests should ignore them and compare everything else '
                 '(status/reason/licence/start/end/logMargin/closestPhone/coverage/etc.) exactly.'),
        ('files', manifest),
    ]), FIXTURES_DIR / 'manifest.json')
    print('done.')


if __name__ == '__main__':
    main()
