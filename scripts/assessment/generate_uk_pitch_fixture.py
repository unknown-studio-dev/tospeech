"""Generate synthetic pitch parity controls; no recorded speech in test fixtures."""

import argparse, json
from pathlib import Path
import numpy as np, soundfile as sf, onnxruntime as ort

p = argparse.ArgumentParser()
p.add_argument("--model", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
a.output.mkdir(parents=True, exist_ok=True)
x = sum(
    0.1 / i * np.sin(2 * np.pi * 120 * i * np.arange(32000) / 16000)
    for i in range(1, 10)
).astype("float32")
sf.write(a.output / "harmonic-120.wav", x, 16000, subtype="FLOAT")
sf.write(
    a.output / "noise.wav",
    np.random.default_rng(0).normal(0, 0.03, 32000).astype("float32"),
    16000,
    subtype="FLOAT",
)
session = ort.InferenceSession(str(a.model))
hz, confidence = session.run(None, {"input_audio": x[None]})
(a.output / "harmonic-120.json").write_text(
    json.dumps({"hz": hz[0].tolist(), "confidence": confidence[0].tolist()})
)
