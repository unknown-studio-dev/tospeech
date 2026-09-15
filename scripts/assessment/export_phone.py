"""Export pinned Phone Scorer for batch-one native inference; no Python at runtime."""
import argparse, hashlib, json, sys
from pathlib import Path
import numpy as np
import torch
from torch import nn
from torch.nn import functional as F
from transformers import WhisperFeatureExtractor
import onnxruntime as ort

parser = argparse.ArgumentParser()
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
sys.path.insert(0, str(args.source / 'submission'))
from accent_score.model import load_checkpoint
from accent_score.audio import WhisperAudioCollator

WEIGHT_HASH = 'ead3144c82ab87ad9d6406511c6348a99c944a9f8ac1097756a6a61d78e80338'
model_dir = args.source / 'submission/model'
assert hashlib.sha256((model_dir/'model.safetensors').read_bytes()).hexdigest() == WEIGHT_HASH
model = load_checkpoint(model_dir).eval()
model.encoder.encoder.config._attn_implementation = 'eager'
torch.set_num_threads(2)
extractor = WhisperFeatureExtractor.from_pretrained(model_dir, local_files_only=True)

class Acoustic(nn.Module):
    def __init__(self):
        super().__init__()
        self.encoder = model.encoder
        self.ctc = model.ctc_head
        # Explicit real DFT kernels avoid runtime-dependent complex STFT support.
        phase = 2*torch.pi*torch.arange(201)[:,None]*torch.arange(400)[None,:]/400
        window = torch.hann_window(400)
        self.register_buffer('real', (torch.cos(phase)*window)[:,None,:])
        self.register_buffer('imag', (-torch.sin(phase)*window)[:,None,:])
        self.register_buffer('mel', torch.tensor(extractor.mel_filters.T, dtype=torch.float32))
    def forward(self, samples, valid_samples):
        # Input is zero padded to a multiple of 320 samples by the native decoder.
        padded = F.pad(samples[:,None,:], (200,200), mode='reflect')
        real = F.conv1d(padded, self.real, stride=160)[:,:,:-1]
        imag = F.conv1d(padded, self.imag, stride=160)[:,:,:-1]
        mel = torch.matmul(self.mel, real.square()+imag.square()).clamp(min=1e-10).log10()
        mel = torch.maximum(mel, mel.amax(dim=(1,2),keepdim=True)-8)
        mel = (mel+4)/4
        lengths = (valid_samples+159)//160
        encoded = self.encoder(mel, lengths)
        return encoded.last_hidden_state, self.ctc(encoded.last_hidden_state), mel

class Scorer(nn.Module):
    def __init__(self):
        super().__init__()
        self.scorer = model.scorer
    def forward(self, features, phone_ids):
        # Exact batch-one valid-prefix BiGRU; there are no padded phone tokens.
        x = torch.cat((features, self.scorer.phone_embedding(phone_ids)), dim=-1)
        context, _ = self.scorer.bigru(x)
        raw = self.scorer.ordinal_head(context)
        center, gap = raw[...,0], F.softplus(raw[...,1])
        return 50*(torch.sigmoid(center+0.5*gap)+torch.sigmoid(center-0.5*gap))

args.output.mkdir(parents=True, exist_ok=True)
acoustic, scorer = Acoustic().eval(), Scorer().eval()
with torch.inference_mode():
    torch.onnx.export(acoustic, (torch.randn(1, 48000)*.05, torch.tensor([47913])),
        str(args.output/'acoustic.onnx'), input_names=['samples','valid_samples'],
        output_names=['hidden','logits','mel'], opset_version=17, dynamo=False,
        dynamic_axes={'samples':{1:'samples'}, 'hidden':{1:'frames'},'logits':{1:'frames'},'mel':{2:'mel_frames'}})
    torch.onnx.export(scorer, (torch.randn(1, 10, 772), torch.arange(10)[None,:]),
        str(args.output/'scorer.onnx'),input_names=['features','phone_ids'],output_names=['scores'],
        opset_version=17,dynamo=False,dynamic_axes={'features':{1:'phones'},'phone_ids':{1:'phones'},'scores':{1:'phones'}})

# Verify dynamic waveform lengths and scorer sequence lengths against upstream.
options = ort.SessionOptions(); options.intra_op_num_threads=2
acoustic_ort = ort.InferenceSession(str(args.output/'acoustic.onnx'), sess_options=options)
scorer_ort = ort.InferenceSession(str(args.output/'scorer.onnx'), sess_options=options)
parity = []
for length in [8091, 16320, 47913, 126753]:
    rng = np.random.default_rng(length)
    raw = rng.normal(0,.04,length).astype(np.float32)
    padded = np.pad(raw,(0,(-length)%320))[None,:]
    batch = extractor([raw], sampling_rate=16000, padding='longest', pad_to_multiple_of=320,
        truncation=False, return_attention_mask=True, return_tensors='pt')
    with torch.inference_mode():
        expected = model.encoder(batch.input_features, torch.tensor([(length+159)//160])).last_hidden_state.numpy()
    hidden, logits, mel = acoustic_ort.run(None, {'samples':padded,'valid_samples':np.array([length],np.int64)})
    mel_error = float(np.max(np.abs(mel-batch.input_features.numpy())))
    hidden_error = float(np.max(np.abs(hidden-expected)))
    assert mel_error < .001 and hidden_error < .01, (length,mel_error,hidden_error)
    parity.append({'samples':length,'mel_max_error':mel_error,'hidden_max_error':hidden_error})
for count in [1, 7, 43, 111]:
    features = torch.randn(1,count,772); phones = torch.arange(count)[None,:]%44
    with torch.inference_mode(): expected=model.scorer(features,phones).scores.numpy()
    actual=scorer_ort.run(None,{'features':features.numpy(),'phone_ids':phones.numpy()})[0]
    error=float(np.max(np.abs(expected-actual)))
    assert error < .001, (count,error)
    parity.append({'phones':count,'score_max_error':error})
manifest = {'sourceRevision':'2211f19be4abc6cdfb7908eb9bbb34f9dcccb550', 'checkpointSHA256':WEIGHT_HASH,
    'phoneVocabulary':list(model.config.phone_vocab), 'runtime':'ONNX Runtime 1.24.2 CPU',
    'conversion':'echolab-phone-onnx-v1', 'torch':torch.__version__,
    'files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in args.output.glob('*.onnx')},
    'bytes':sum(p.stat().st_size for p in args.output.glob('*.onnx')), 'parity':parity}
(args.output/'manifest.json').write_text(json.dumps(manifest,indent=2,ensure_ascii=False)+'\n')
print(json.dumps(manifest,indent=2,ensure_ascii=False))
