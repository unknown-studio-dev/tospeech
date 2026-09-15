#!/usr/bin/env python3
"""Fit XEUS decision thresholds so native controls yield zero false 'Sai'.

Grid-searches strength/competitor upward from defaults until no native unit is
likelyIncorrect, maximizing coverage subject to that hard constraint. Offline: scores the
saved logits fixture(s) native_sanity.load_native_cases() returns (see that file's docstring
for why this never loads the XEUS model directly in this shell).

CALIBRATION SCOPE: this grid search currently runs over a single native control clip
("okay") -- the only saved-logits fixture available offline. It is enough to confirm the
default thresholds already produce zero false-Sai on native speech and to pin that result
as a versioned artifact, but it is NOT a broad-corpus calibration. Fitting thresholds
against the full native lesson corpus (many speakers/clips) requires the packaged app
runtime and DB/media assets and is deferred to a maintainer run of native_sweep.py against
the app-generated native corpus (see native_sweep.py's --db/--media/--espeak/--pcm-extract
flags). Do NOT fabricate a larger synthetic corpus here to make this search look broader
than it is.
"""
import itertools
import json
from pathlib import Path

from evidence import assess_phones, THRESHOLDS


def native_false_sai(cases, thresholds):
    bad = 0
    scored = 0
    total = 0
    for lp, phones, vocab, dur in cases:
        for r in assess_phones(lp, phones, vocab, dur, thresholds=thresholds):
            total += 1
            if r['status'] == 'likelyIncorrect':
                bad += 1
            if r['status'] in ('correct', 'likelyIncorrect'):
                scored += 1
    return bad, (scored / total if total else 0.0)


def fit(cases):
    grid = dict(competitor=[t / 10 for t in range(18, 40, 2)], strength=[.65, .7, .75, .8, .85, .9])
    best = None
    for comp, strg in itertools.product(grid['competitor'], grid['strength']):
        th = dict(THRESHOLDS, competitor=comp, strength=strg)
        bad, cov = native_false_sai(cases, th)
        if bad == 0 and (best is None or cov > best[0]):
            best = (cov, th)
    return best[1] if best else dict(THRESHOLDS)


if __name__ == '__main__':
    from native_sanity import load_native_cases  # Task 8 provides this loader
    th = fit(load_native_cases())
    th['calibration'] = 'native-zero-false-sai-v1'
    Path(__file__).with_name('thresholds.json').write_text(json.dumps(th, indent=2))
    print('wrote', th)
