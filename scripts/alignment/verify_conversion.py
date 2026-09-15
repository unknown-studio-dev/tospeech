"""Compare dynamic-length Core ML emissions with the original PyTorch model."""
from pathlib import Path
import json
import numpy as np
import torch
import coremltools as ct
from transformers import Wav2Vec2ForCTC
from huggingface_hub import snapshot_download

root = Path(__file__).resolve().parents[2]
revision = '22aad52d435eb6dbaf354bdad9b0da84ce7d6156'
folder = snapshot_download('facebook/wav2vec2-base-960h', revision=revision, local_files_only=True)
torch.set_num_threads(2)
reference = Wav2Vec2ForCTC.from_pretrained(folder, attn_implementation='eager').eval()
model = ct.models.MLModel(str(root / 'vendor/alignment/EnglishAlignment.mlpackage'), compute_units=ct.ComputeUnit.CPU_AND_GPU)
rng = np.random.default_rng(42)
results = []
for length in [16000, 64000, 320000]:
    audio = rng.normal(size=(1, length)).astype(np.float32)
    with torch.no_grad():
        expected = reference(torch.from_numpy(audio)).logits.numpy()
    actual = model.predict({'audio': audio})['logits']
    agreement = float(np.mean(actual.argmax(-1) == expected.argmax(-1)))
    error = float(np.max(np.abs(expected - actual)))
    assert expected.shape == actual.shape
    assert agreement >= 0.98, (length, agreement)
    assert error < 0.5, (length, error)
    results.append({'samples': length, 'frames': actual.shape[1], 'argmaxAgreement': agreement, 'maxLogitError': error})
print(json.dumps(results, indent=2))
