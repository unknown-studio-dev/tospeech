"""Cross-implementation control: sample original PyTorch outputs for native ORT."""

import argparse, json
from pathlib import Path
import numpy as np, soundfile as sf, torch
from transformers import Wav2Vec2ForCTC

p = argparse.ArgumentParser()
p.add_argument("--checkpoint", type=Path, required=True)
p.add_argument("--audio", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
torch.set_num_threads(2)
model = Wav2Vec2ForCTC.from_pretrained(
    a.checkpoint, local_files_only=True, attn_implementation="eager"
).eval()
x, sr = sf.read(a.audio, dtype="float32")
assert sr == 16000 and x.ndim == 1
# Match Wav2Vec2 normalization, accumulating in double as native does.
x = (
    (x.astype("float64") - x.astype("float64").mean())
    / np.sqrt(x.astype("float64").var() + 1e-7)
).astype("float32")
with torch.inference_mode():
    hidden = model.wav2vec2(torch.from_numpy(x)[None]).last_hidden_state
    logp = model.lm_head(hidden).log_softmax(-1)
h = hidden.numpy().ravel()
p = logp.numpy().ravel()
hi = list(range(0, len(h), 337))
pi = list(range(0, len(p), 179))
a.output.write_text(
    json.dumps(
        {
            "frames": int(hidden.shape[1]),
            "hiddenIndices": hi,
            "hidden": h[hi].tolist(),
            "logIndices": pi,
            "logp": p[pi].tolist(),
        }
    )
)
print("PyTorch control saved:", hidden.shape, logp.shape)
