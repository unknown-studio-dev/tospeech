"""UK vowel identity/focus pilot from EUSTACE manually timed nuclei.

Labels are native vowel categories and elicited accent conditions, NOT human
ratings of learner pronunciation. Split by speaker; keep experimental provenance.
"""

import argparse, json, re, time, hashlib
from pathlib import Path
import numpy as np, soundfile as sf, onnxruntime as ort
from scipy.signal import resample_poly
from math import gcd
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, balanced_accuracy_score

p = argparse.ArgumentParser()
p.add_argument("--corpus", type=Path, required=True)
p.add_argument("--package", type=Path, required=True)
p.add_argument("--work", type=Path, required=True)
a = p.parse_args()
a.work.mkdir(parents=True, exist_ok=True)
vowels = {
    "cap": "æ",
    "dog": "ɒ",
    "fis": "ɪ",
    "mac": "eɪ",
    "par": "ɑː",
    "sen": "ɛ",
    "spe": "ɛ",
    "ten": "ɛ",
    "com": "əʊ",
    "dis": "əʊ",
    "jui": "uː",
    "mai": "eɪ",
    "men": "ɛ",
    "por": "ɔː",
    "sup": "əʊ",
}
features = []
labels = []
focus = []
speakers = []
records = []
stress_features = []
stress_labels = []
stress_speakers = []
offsets = json.loads(Path(__file__).with_name("eustace-start-times.json").read_text())
cache = a.work / "training-features.npz"
cache_metadata = a.work / "feature-cache-metadata.json"
with (a.package / "encoder.onnx").open("rb") as stream:
    encoder_hash = hashlib.file_digest(stream, "sha256").hexdigest()
fingerprint = {
    "extractor": "eustace-offset-valid-whole-syllable-v1",
    "encoder": encoder_hash,
    "offsets": hashlib.sha256(
        Path(__file__).with_name("eustace-start-times.json").read_bytes()
    ).hexdigest(),
    "corpus": str(a.corpus.resolve()),
    "onnxruntime": ort.__version__,
    "numpy": np.__version__,
}
if cache.exists():
    if (
        not cache_metadata.exists()
        or json.loads(cache_metadata.read_text()) != fingerprint
    ):
        raise RuntimeError(
            "Feature cache does not match this extractor/model/corpus. Use a fresh --work directory."
        )
    d = np.load(cache)
    X = d["X"]
    Y = d["Y"]
    F = d["F"]
    G = d["G"]
    SX = d["SX"]
    SY = d["SY"]
    SG = d["SG"]
    records = json.loads((a.work / "training-records.json").read_text())
else:
    opt = ort.SessionOptions()
    opt.intra_op_num_threads = 2
    session = ort.InferenceSession(
        str(a.package / "encoder.onnx"), opt, providers=["CPUExecutionProvider"]
    )
    for lab in sorted((a.corpus / "labels/testsyl").rglob("*.lab")):
        stem = lab.stem
        match = re.fullmatch(r"([fm][123])[lr]([a-z]+)([au])[me]", stem)
        if not match:
            continue
        speaker, key, accent = match.groups()
        if key not in vowels:
            continue
        wav = list(a.corpus.glob("**/speech.wav/**/" + stem + ".wav"))
        if len(wav) != 1:
            continue
        audio, sr = sf.read(wav[0])
        audio = audio.mean(1) if audio.ndim > 1 else audio
        g = gcd(sr, 16000)
        audio = resample_poly(audio, 16000 // g, sr // g).astype("float32")
        offset = offsets[stem]
        # Seven WAV files end before their last labelled sentence; exclude any
        # utterance not wholly inside the actual audio, rather than clipping its label.
        audio_duration = len(audio) / 16000
        extra = {}
        uns = list((a.corpus / "labels/othersyl").rglob(stem + ".uns"))
        if uns:
            fields = {}
            for line in uns[0].read_text().splitlines():
                bits = line.split()
                if len(bits) < 3:
                    continue
                try:
                    ut = float(bits[0]) - offset
                except ValueError:
                    continue
                label = bits[-1]
                if label.startswith("FIRST.") or label.startswith("SECOND."):
                    fields[label] = ut
                elif "_" in label and not label.startswith("note."):
                    ranges = []
                    for name in ["FIRST", "SECOND"]:
                        b = fields.get(name + ".start")
                        if b is None and name == "SECOND" and stem[2] == "l":
                            b = fields.get("FIRST.end")
                        if b is None and name == "FIRST" and stem[2] == "r":
                            b = fields.get("SECOND.end")
                        e = fields.get(name + ".end")
                        if b is not None and e is not None and 0.035 < e - b < 1:
                            ranges.append((b, e))
                    extra[round(ut, 4)] = ranges
                    fields = {}
        marks = {}
        previous = 0
        notes = []
        filecount = 0
        for line in lab.read_text().splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            try:
                t = float(parts[0]) - offset
            except ValueError:
                continue
            label = parts[-1]
            if label.split(".")[0] in ["onset", "nucleus", "coda", "end"]:
                marks[label.split(".")[0]] = t
                if "query" in label:
                    notes.append("discard_query")
            elif label.startswith("note.") or label == "spare":
                notes.append(label)
            elif "_" in label:
                if all(k in marks for k in ["nucleus", "coda"]) and not any(
                    any(
                        flag in n
                        for flag in [
                            "discard",
                            "spare",
                            "nuclear_after",
                            "nuclear_before",
                            "key_non_nuclear",
                            "key_nuclear",
                            "key_prominence",
                            "initial-stress",
                            "initial_stress",
                        ]
                    )
                    for n in notes
                ):
                    nucleus, coda = marks["nucleus"], marks["coda"]
                    start = marks.get("onset", nucleus - 0.02)
                    end = marks.get("end", coda + 0.02)
                    if (
                        0
                        <= previous
                        <= start
                        < nucleus
                        < coda
                        <= end
                        < t
                        <= audio_duration
                        and 0.035 < coda - nucleus < 0.8
                    ):
                        lo = max(previous, start - 1.5)
                        hi = min(t, end + 1.0)
                        y = audio[int(lo * 16000) : int(hi * 16000)]
                        if len(y) < 1600 or len(y) > 160000:
                            continue
                        y = (y - y.mean()) / np.sqrt(y.var() + 1e-7)
                        hidden = session.run(["hidden"], {"samples": y[None]})[0][0]
                        # Interior frames avoid adjacent consonants. Same 20ms geometry as native.
                        b = max(0, int(np.ceil((nucleus - lo) / 0.02)))
                        e = min(len(hidden), int(np.floor((coda - lo) / 0.02)))
                        if e > b:
                            vector = hidden[b:e].mean(0)
                            duration = coda - nucleus
                            features.append(np.r_[vector, np.log(duration)])
                            labels.append(vowels[key])
                            focus.append(int(accent == "a"))
                            speakers.append(speaker)

                            def add_stress(begin, finish, label_value):
                                if not lo <= begin < finish <= hi:
                                    return
                                b = max(0, int(np.ceil((begin - lo) / 0.02)))
                                e = min(
                                    len(hidden), int(np.floor((finish - lo) / 0.02))
                                )
                                if e > b and 0.035 < finish - begin < 1:
                                    stress_features.append(
                                        np.r_[
                                            hidden[b:e].mean(0), np.log(finish - begin)
                                        ]
                                    )
                                    stress_labels.append(label_value)
                                    stress_speakers.append(speaker)

                            # Use full syllables for BOTH classes. Never compare nuclei to whole syllables.
                            if "onset" in marks and "end" in marks:
                                add_stress(start, end, 1)
                                for b, e in extra.get(round(t, 4), []):
                                    add_stress(b, e, 0)
                            records.append(
                                {
                                    "file": stem,
                                    "sentence": label,
                                    "nucleus": nucleus,
                                    "coda": coda,
                                    "context": [lo, hi],
                                    "speaker": speaker,
                                    "vowel": vowels[key],
                                    "accent": accent,
                                }
                            )
                            filecount += 1
                previous = t
                marks = {}
                notes = []
        print(stem, filecount, "total", len(features), flush=True)
    X = np.array(features)
    Y = np.array(labels)
    F = np.array(focus)
    G = np.array(speakers)
    SX = np.array(stress_features)
    SY = np.array(stress_labels)
    SG = np.array(stress_speakers)
    np.savez_compressed(cache, X=X, Y=Y, F=F, G=G, SX=SX, SY=SY, SG=SG)
    (a.work / "training-records.json").write_text(
        json.dumps(records, ensure_ascii=False)
    )
    cache_metadata.write_text(json.dumps(fingerprint, indent=2))


def fit(x, y):
    scaler = StandardScaler().fit(x)
    clf = LogisticRegression(C=0.01, max_iter=1000, class_weight="balanced").fit(
        scaler.transform(x), y
    )
    return scaler, clf


def export(name, x, y, policy, groups=None):
    groups = G if groups is None else groups
    predictions = np.empty_like(y)
    probs = np.zeros(len(y))
    folds = []
    for speaker in sorted(set(groups)):
        train = groups != speaker
        test = ~train
        scaler, clf = fit(x[train], y[train])
        posterior = clf.predict_proba(scaler.transform(x[test]))
        pred = clf.classes_[posterior.argmax(1)]
        predictions[test] = pred
        probs[test] = posterior.max(1)
        folds.append(
            {
                "speaker": speaker,
                "n": int(test.sum()),
                "accuracy": float(accuracy_score(y[test], pred)),
                "balanced_accuracy": float(balanced_accuracy_score(y[test], pred)),
            }
        )
    scaler, clf = fit(x, y)
    metrics = {
        "examples": len(y),
        "speakers": len(set(groups)),
        "folds": folds,
        "accuracy": float(accuracy_score(y, predictions)),
        "balanced_accuracy": float(balanced_accuracy_score(y, predictions)),
        "confidence_0_8": {
            "coverage": float((probs >= 0.8).mean()),
            "accuracy": (
                float(accuracy_score(y[probs >= 0.8], predictions[probs >= 0.8]))
                if (probs >= 0.8).any()
                else None
            ),
        },
        "limitation": "Speaker-disjoint pilot on native elicited speech. Repeated lexical content retained; NOT held-out-text or learner correctness calibration.",
    }
    obj = {
        "labels": [str(v) for v in clf.classes_],
        "mean": scaler.mean_.tolist(),
        "scale": scaler.scale_.tolist(),
        "weights": clf.coef_.tolist(),
        "bias": clf.intercept_.tolist(),
        "confidenceFloor": 0.8,
        "policy": policy,
        "metrics": metrics,
        "training": fingerprint,
    }
    (a.package / name).write_text(json.dumps(obj, ensure_ascii=False))
    print(name, metrics, flush=True)


export("uk-vowels.json", X[:, :1024], Y, "eustace-uk-vowel-identity-v1-experimental")
export("uk-focus.json", X, F, "eustace-uk-focus-v1-experimental")

export("uk-stress.json", SX, SY, "eustace-uk-lexical-stress-v1-experimental", SG)
# The filename suffix e means "edge series", NOT "utterance-final".
# Edge-series recordings also contain medial and (right-headed) initial targets.
# Derive the actual final-keyword condition from the sentence identification label.
families = {
    "lcap": ["cap", "captain", "captaincy"],
    "ldog": ["dog", "dogma", "dogmatist"],
    "lfis": ["fish", "fisherman", "fissure"],
    "lmac": ["mace", "mason", "masonry"],
    "lpar": ["part", "partner", "partnership"],
    "lsen": ["censor", "censorship", "sense"],
    "lspe": ["spec", "speck", "spectacle", "spectre"],
    "lten": ["ten", "tendency", "tendon"],
    "rcom": ["compose", "decompose", "pose"],
    "rdis": ["dispose", "indispose", "pose"],
    "rjui": ["juice", "produce", "reproduce"],
    "rmai": ["humane", "inhumane", "main"],
    "rmen": ["commend", "mend", "recommend"],
    "rpor": ["misreport", "port", "report"],
    "rsen": ["condescend", "descend", "send"],
    "rsup": ["pose", "presuppose", "suppose"],
}
boundary_rows = []
boundary_labels = []
for i, row in enumerate(records):
    tokens = row["sentence"].lower().split("_")
    family = families[row["file"][2:-2]]
    if not tokens[-1].isdigit() or sum(token in family for token in tokens[:-1]) != 1:
        continue
    boundary_rows.append(i)
    boundary_labels.append(int(tokens[-2] in family))
indices = np.array(boundary_rows)
P = np.array(boundary_labels)
print(
    "Boundary actual-position labels:",
    len(P),
    "final:",
    int(P.sum()),
    "excluded:",
    len(records) - len(P),
    flush=True,
)
export(
    "uk-boundary.json",
    X[indices],
    P,
    "eustace-uk-utterance-final-v1-experimental",
    G[indices],
)
