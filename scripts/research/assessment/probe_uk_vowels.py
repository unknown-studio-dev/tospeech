"""Held-out-word synthetic controls; diagnostic only, not learner validation."""

import argparse, json
from pathlib import Path
from math import gcd
import numpy as np, soundfile as sf, onnxruntime as ort
from scipy.signal import resample_poly

p = argparse.ArgumentParser()
p.add_argument("--package", type=Path, required=True)
p.add_argument("--audio", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
options = ort.SessionOptions()
options.intra_op_num_threads = 2
session = ort.InferenceSession(str(a.package / "encoder.onnx"), options)
vocab = json.loads((a.package / "vocab.json").read_text())
head = json.loads((a.package / "uk-vowels.json").read_text())


def align(rows, labels):
    states = len(labels) * 2 + 1
    state_labels = np.array(
        [0 if i % 2 == 0 else labels[i // 2] for i in range(states)]
    )
    skip = np.array(
        [
            i > 1 and i % 2 == 1 and labels[i // 2] != labels[i // 2 - 1]
            for i in range(states)
        ]
    )
    previous = np.full(states, -np.inf)
    previous[0] = 0
    trace = []
    for row in rows:
        one = np.r_[-np.inf, previous[:-1]]
        two = np.r_[[-np.inf, -np.inf], previous[:-2]]
        two[~skip] = -np.inf
        scores = np.stack([previous, one, two])
        step = scores.argmax(0)
        previous = scores.max(0) + row[state_labels]
        trace.append(step)
    state = states - 1 if previous[-1] > previous[-2] else states - 2
    starts = [len(rows)] * len(labels)
    ends = [0] * len(labels)
    for t in reversed(range(len(rows))):
        if state % 2:
            starts[state // 2] = t
            ends[state // 2] = max(ends[state // 2], t + 1)
        state -= int(trace[t][state])
    assert all(e > b for b, e in zip(starts, ends))
    return list(zip(starts, ends))


def predict(vector):
    x = (vector - np.array(head["mean"])) / np.array(head["scale"])
    z = np.array(head["weights"]) @ x + head["bias"]
    probs = np.exp(z - z.max())
    probs /= probs.sum()
    i = probs.argmax()
    return {"vowel": head["labels"][i], "probability": float(probs[i])}


controls = {
    "cat": ["k", "æ", "t"],
    "cot": ["k", "ɒ", "t"],
    "cart": ["k", "ɑː", "t"],
    "coat": ["k", "əʊ", "t"],
    "kit": ["k", "ɪ", "t"],
    "ket": ["k", "ɛ", "t"],
}
outputs = {}
for word, phones in controls.items():
    raw, sr = sf.read(a.audio / (word + ".aiff"))
    g = gcd(sr, 16000)
    x = resample_poly(raw, 16000 // g, sr // g).astype("float32")
    x = ((x - x.mean()) / np.sqrt(x.var() + 1e-7)).astype("float32")
    hidden, logits = session.run(None, {"samples": x[None]})
    rows = logits[0]
    rows = rows - np.logaddexp.reduce(rows, axis=1, keepdims=True)
    outputs[word] = (hidden[0], rows)
results = []
for reference, phones in controls.items():
    for take in controls:
        hidden, rows = outputs[take]
        spans = align(rows, [vocab[s] for s in phones])
        begin = (spans[0][1] + spans[1][0]) // 2
        end = (spans[1][1] + spans[2][0]) // 2
        prediction = predict(hidden[begin:end].mean(0))
        results.append(
            {
                "target": reference,
                "take": take,
                "expected_target": phones[1],
                "actual_TTS_category": controls[take][1],
                **prediction,
                "region_frames": [begin, end],
            }
        )
a.output.write_text(
    json.dumps(
        {
            "limitation": "One UK TTS voice; words not in the nine-class training roots. Not human learner validation; native AVAudioConverter is tested separately.",
            "results": results,
        },
        indent=2,
        ensure_ascii=False,
    )
)
print(
    json.dumps(
        [x for x in results if x["target"] == x["take"]], ensure_ascii=False, indent=2
    )
)
