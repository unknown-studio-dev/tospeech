"""Developer-only Core ML conversion. Python is not part of the app runtime."""
from pathlib import Path
import json
import numpy as np
import torch
import coremltools as ct
from transformers import Wav2Vec2ForCTC
from huggingface_hub import snapshot_download

REPO = 'facebook/wav2vec2-base-960h'
root = Path(__file__).resolve().parents[2]
folder = snapshot_download(REPO, revision='22aad52d435eb6dbaf354bdad9b0da84ce7d6156', allow_patterns=['config.json', 'model.safetensors', 'vocab.json', 'preprocessor_config.json'])
model = Wav2Vec2ForCTC.from_pretrained(folder, attn_implementation='eager').eval()
torch.set_num_threads(2)
class Logits(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.model = model
    def forward(self, audio):
        return self.model(audio).logits
traced = torch.jit.trace(Logits().eval(), torch.randn(1, 16000), strict=False)
converted = ct.convert(traced, inputs=[ct.TensorType(name='audio', shape=(1, ct.RangeDim(400, 480000, default=16000)), dtype=np.float32)], outputs=[ct.TensorType(name='logits', dtype=np.float32)], minimum_deployment_target=ct.target.macOS15, compute_precision=ct.precision.FLOAT16)
converted.short_description = 'English CTC acoustic emissions for transcript alignment; not the transcript selection engine.'
converted.license = 'Apache-2.0'
converted.author = 'Meta; ToSpeech Core ML conversion'
converted.user_defined_metadata['source'] = REPO
converted.user_defined_metadata['source_revision'] = Path(folder).name
out = root / 'vendor/alignment'
out.mkdir(parents=True, exist_ok=True)
converted.save(str(out / 'EnglishAlignment.mlpackage'))
(out / 'vocab.json').write_text((Path(folder) / 'vocab.json').read_text())
(out / 'provenance.json').write_text(json.dumps({'model': REPO, 'revision': Path(folder).name, 'torch': torch.__version__, 'coremltools': ct.__version__, 'precision': 'float16', 'sampleRate': 16000, 'stride': 320, 'receptiveField': 400}, indent=2))
print(out, flush=True)
