#!/usr/bin/env python3
"""Native-sanity gate: native/clean speech scored as a take must show zero "Sai"
(likelyIncorrect) phones, and coverage is reported.

Runs the saved XEUS CTC logits fixture(s) under fixtures/ through the full per-word
decision pipeline in runtime.assemble_from_logits, source-self (the same clip's saved
logits stand in as both the reference and the take). Native, clean, correctly-pronounced
speech scored against itself must never surface as `likelyIncorrect` -- any red there is a
false alarm ("false-Sai") in the scorer, not a pronunciation error.

Environment note: the 2.3GB XEUS model cannot be loaded standalone in this shell
(runtime.load needs the packaged `src` layout that ships with the app; the signed helper
SIGTRAPs when run unsandboxed here). This harness therefore never performs model
inference -- it replays the saved logits fixture(s) in fixtures/ through the CTC scoring
and decision code exactly as the app would, so it stays runnable offline in this shell.

This is the offline-runnable gate on saved fixtures. The full app-driven native corpus
sweep across every lesson clip lives in native_sweep.py (needs --db/--media/--espeak/
--pcm-extract plus the packaged app runtime) and is the maintainer path for broader
calibration; see the note in calibrate.py.

`load_native_cases()` is also the case loader calibrate.py grid-searches over.
"""
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
VOCAB_PATH = HERE.parent.parent.parent / 'vendor/phoneticxeus/_internal/src/model/xeusphoneme/resources/ipa_vocab.json'
STEP = .02

# Fixture basenames under fixtures/: <name>-source-logits.npy + <name>-request.json.
# Only "okay" is available right now (see fixtures/README-equivalent note in task briefs);
# add more basenames here as more saved-logits fixtures are captured.
FIXTURES = ['okay']


def _load_vocab():
    return json.loads(VOCAB_PATH.read_text())


def _load_fixture(name, vocab):
    lp = np.load(HERE / f'fixtures/{name}-source-logits.npy')
    request = json.loads((HERE / f'fixtures/{name}-request.json').read_text())
    dur = len(lp) * STEP
    # The saved fixture request currently carries exactly one variant per word, so that
    # variant IS the selected one; flattening it gives the per-clip phone sequence that
    # calibrate.py's grid search scores with the simpler assess_phones() path. (The full
    # word-gated decision in run_native_controls()/assemble_from_logits performs its own
    # alignment/variant-selection independent of this flattening.)
    phones = [p for word in request['words'] for p in word['variants'][0]]
    return lp, phones, request, dur


def load_native_cases():
    """(lp, phones, vocab, dur) tuples for calibrate.py: saved source logits, the selected
    per-word phone list (flattened across words), the shared IPA vocab, and clip duration."""
    vocab = _load_vocab()
    cases = []
    for name in FIXTURES:
        lp, phones, _request, dur = _load_fixture(name, vocab)
        cases.append((lp, phones, vocab, dur))
    return cases


def run_native_controls():
    """Yields (name, result): result is the full assemble_from_logits() payload from
    scoring each saved fixture's logits as BOTH source and take (source-self) -- the same
    word-gated decision pipeline the app uses to grade a real take."""
    from runtime import assemble_from_logits
    vocab = _load_vocab()
    for name in FIXTURES:
        lp, _phones, request, dur = _load_fixture(name, vocab)
        result = assemble_from_logits(lp, lp, vocab, request, dur, dur)
        yield name, result


def main():
    fails = []
    cov = []
    for name, result in run_native_controls():
        rows = [p for w in result['words'] for p in w['phones']]
        sai = [p for p in rows if p['status'] == 'likelyIncorrect']
        assert 'coverage' in result and 'coverage' in result['coverage'], 'coverage missing from payload'
        c = result['coverage']['coverage']
        cov.append(c)
        print(f'{name}: phones={len(rows)} coverage={c:.4f} '
              f'correct={result["coverage"]["correct"]} incorrect={result["coverage"]["incorrect"]} '
              f'unassessed={result["coverage"]["unassessed"]}')
        if sai:
            fails.append((name, [p['expected'] for p in sai]))
    print('native coverage mean', sum(cov) / len(cov) if cov else 0)
    assert not fails, f'native false-Sai: {fails}'
    print('OK: native false-Sai == 0')


if __name__ == '__main__':
    main()
