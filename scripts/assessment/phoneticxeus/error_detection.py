#!/usr/bin/env python3
"""Error-detection precision/recall harness: planted minimal-pair substitutions must be
flagged `likelyIncorrect` at precision >= 0.90 on the shown verdicts; recall is reported,
not gated.

SYNTHETIC, NOT REAL AUDIO. The task-9 brief's reference design consumes curated minimal-pair
clips (e.g. the `vest`/`west` fixtures and the Daniel en-GB TTS controls) run through
`assemble_from_logits` on real model logits. That requires the XEUS model, which does NOT run
standalone in this shell (runtime.load needs the packaged `src` layout; the signed helper
SIGTRAPs unsandboxed) -- so this harness cannot produce real learner-error logits from audio.

Instead it builds synthetic CTC logit matrices that plant errors directly at the emission
level, the same technique test_evidence.py uses for its unit tests (a `lp` matrix hand-built
so a specific token dominates specific frames). Each case targets one phone via `assess_phones`
(the brief explicitly allows this instead of the word-level `assemble_from_logits`, since it
"is simplest and matches the confusion-gate semantics" -- no word ids or reference/take
licensing plumbing needed to exercise the confusion gate in evidence.assess_units).

This is a precision/recall check on the confusion-gate LOGIC (Task 1's CONFUSION table +
Task 5's calibrated thresholds), not a claim about real-clip/real-speaker precision. Measuring
precision on real recorded learner errors requires the packaged app + XEUS helper and is
deferred to a maintainer run (produce real (reference, learner) clip pairs with known planted
substitutions, score them through the app's assemble_from_logits path, and compute the same
precision/recall over the real verdicts). No real clips or "passed on real audio" claim is made
here.
"""
import sys
from collections import namedtuple

import numpy as np

from evidence import assess_phones
from runtime import load_thresholds

Case = namedtuple('Case', 'name lp phones vocab duration planted')
# `planted`: set of indices into `phones` that are genuine, confusable substitutions the
# learner made (i.e. the model SHOULD flag them likelyIncorrect). Controls have planted=set()
# -- for those cases ANY likelyIncorrect flag is a false positive.


def _vocab428(**names):
    vocab = {f'x{i}': i for i in range(428)}
    vocab['<blank>'] = 0
    vocab.update(names)
    return vocab


def _lp(rows):
    """Same construction as test_evidence.py's CTCEvidenceTests.lp: a near-deterministic
    per-frame distribution built from {token: probability_mass} rows, log-normalized."""
    p = np.full((len(rows), 428), 1e-8)
    for i, values in enumerate(rows):
        for token, prob in values.items():
            p[i, token] = prob
    p /= p.sum(1, keepdims=True)
    return np.log(p)


def cases():
    """Three confusable-pair minimal-pair probes (v/w, th/s, l/r), each with:
    - a planted TRUE POSITIVE: target phone strongly replaced by its confusable competitor
      (must be flagged likelyIncorrect -- counts toward recall),
    - a CORRECT control: target phone correctly produced (must NOT be flagged),
    - a NON-CONFUSABLE-competitor control: target phone strongly replaced by an arbitrary
      token that is NOT in its confusion set (must abstain -- uncertain/ambiguousSubstitution,
      not likelyIncorrect).
    Any spurious flag on a control immediately drops precision (e.g. 2 TP + 1 FP = 0.667),
    so these controls are a real precision guard, not padding.
    """
    cs = []

    # --- v -> w: confusable pair (CONFUSION['v'] includes 'w') ---
    v1 = _vocab428(v=4, w=5)
    cs.append(Case('v_to_w_confusable_TP', _lp([{0: .99}, {5: .98, 4: .001}, {5: .98, 4: .001}, {0: .99}]),
                    ['v'], v1, .08, {0}))
    cs.append(Case('v_correct_control', _lp([{0: .99}, {4: .98, 5: .001}, {4: .95, 5: .001}, {0: .99}]),
                    ['v'], v1, .08, set()))
    v1b = _vocab428(v=4)  # id 99 -> generic non-confusable label 'x99'
    cs.append(Case('v_nonconfusable_control', _lp([{0: .99}, {99: .98, 4: .001}, {99: .98, 4: .001}, {0: .99}]),
                    ['v'], v1b, .08, set()))

    # --- theta -> s: confusable pair (CONFUSION['θ'] includes 's') ---
    v2 = _vocab428(**{'θ': 4, 's': 5})
    cs.append(Case('theta_to_s_confusable_TP', _lp([{0: .95, 5: .05}, {5: .98, 4: .001}, {5: .95, 4: .001}, {0: .99}]),
                    ['θ'], v2, .08, {0}))
    cs.append(Case('theta_correct_control', _lp([{0: .99}, {4: .98, 5: .001}, {4: .95, 5: .001}, {0: .99}]),
                    ['θ'], v2, .08, set()))
    v2b = _vocab428(**{'θ': 4})
    cs.append(Case('theta_nonconfusable_control', _lp([{0: .99}, {99: .98, 4: .001}, {99: .98, 4: .001}, {0: .99}]),
                    ['θ'], v2b, .08, set()))

    # --- l -> r: confusable pair (CONFUSION['l'] includes 'ɹ') ---
    v3 = _vocab428(l=4, **{'ɹ': 5})
    cs.append(Case('l_to_r_confusable_TP', _lp([{0: .99}, {5: .98, 4: .001}, {5: .98, 4: .001}, {0: .99}]),
                    ['l'], v3, .08, {0}))
    cs.append(Case('l_correct_control', _lp([{0: .99}, {4: .98, 5: .001}, {4: .95, 5: .001}, {0: .99}]),
                    ['l'], v3, .08, set()))
    v3b = _vocab428(l=4)
    cs.append(Case('l_nonconfusable_control', _lp([{0: .99}, {99: .98, 4: .001}, {99: .98, 4: .001}, {0: .99}]),
                    ['l'], v3b, .08, set()))

    return cs


def main():
    thresholds, _ = load_thresholds()
    tp = fp = planted = 0
    for case in cases():
        rows = assess_phones(case.lp, case.phones, case.vocab, case.duration, thresholds=thresholds)
        flagged = [i for i, r in enumerate(rows) if r['status'] == 'likelyIncorrect']
        planted += len(case.planted)
        for i in flagged:
            if i in case.planted:
                tp += 1
            else:
                fp += 1
                print(f'FALSE POSITIVE: case={case.name!r} phone-index={i} expected={case.phones[i]!r}',
                      file=sys.stderr)
    precision = tp / (tp + fp) if (tp + fp) else 1.0
    recall = tp / planted if planted else 0.0
    print(f'precision={precision:.3f} recall={recall:.3f} (tp={tp} fp={fp} planted={planted})')
    assert precision >= 0.90, f'precision {precision:.3f} below 0.90'
    print('OK: precision >= 0.90')


if __name__ == '__main__':
    main()
