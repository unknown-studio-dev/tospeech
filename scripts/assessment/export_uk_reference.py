"""Export the pinned frozen UK-reference research encoder; no scoring calibration implied."""

import argparse, json, hashlib, time
from pathlib import Path
import numpy as np, torch, onnxruntime as ort
from transformers import Wav2Vec2ForCTC

p = argparse.ArgumentParser()
p.add_argument("--checkpoint", type=Path, required=True)
p.add_argument("--output", type=Path, required=True)
a = p.parse_args()
torch.set_num_threads(2)
a.output.mkdir(parents=True, exist_ok=True)
m = Wav2Vec2ForCTC.from_pretrained(
    a.checkpoint, local_files_only=True, attn_implementation="eager"
).eval()


class Export(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, samples):
        h = self.m.wav2vec2(samples).last_hidden_state
        return h, self.m.lm_head(h)


e = Export(m).eval()
x = torch.randn(1, 16000)
start = time.monotonic()
with torch.inference_mode():
    torch.onnx.export(
        e,
        (x,),
        str(a.output / "encoder.onnx"),
        input_names=["samples"],
        output_names=["hidden", "logits"],
        dynamic_axes={
            "samples": {1: "samples_count"},
            "hidden": {1: "frames"},
            "logits": {1: "frames"},
        },
        opset_version=17,
        dynamo=False,
    )
options = ort.SessionOptions()
options.intra_op_num_threads = 2
s = ort.InferenceSession(
    str(a.output / "encoder.onnx"), options, providers=["CPUExecutionProvider"]
)
checks = []
for n in [16000, 23171, 48000]:
    torch.manual_seed(11)
    x = torch.randn(1, n)
    with torch.inference_mode():
        expected = e(x)
    actual = s.run(None, {"samples": x.numpy()})
    checks.append(
        {
            "samples": n,
            "max_absolute_error": [
                float(np.max(np.abs(v.numpy() - z))) for v, z in zip(expected, actual)
            ],
        }
    )
assert all(max(x["max_absolute_error"]) < 0.005 for x in checks), checks
(a.output / "vocab.json").write_bytes((a.checkpoint / "vocab.json").read_bytes())
(a.output / "export-verification.json").write_text(
    json.dumps(
        {
            "torch": torch.__version__,
            "onnxruntime": ort.__version__,
            "revision": "2c733782da5604684829819a5eb744c193fe9398",
            "checks": checks,
            "export_seconds": time.monotonic() - start,
        },
        indent=2,
    )
)
print(checks, flush=True)
