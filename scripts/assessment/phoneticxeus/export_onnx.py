#!/usr/bin/env python
"""Exports PhoneticXeus (XEUS) to a single-file external-data ONNX graph with two
outputs — `log_probs` [1,T,428] (the CTC head, unchanged contract) and `hidden`
[1,T,HEAD.dim] (the encoder layer the UK contrast head reads, see uk_contrast_head.py)
— then verifies ONNX Runtime parity against a torch forward pass.

Maintainer tooling only; nothing here ships in the app. The Python runtime
(runtime.py/evidence.py) stays the golden reference and is not touched by this
script. Run inside the xeus-env used for the export spike (torch 2.10 + onnx;
onnxruntime is a separate opt-in install, see below):

    python export_onnx.py \
        --snapshot /tmp/echolab-phoneticxeus-20260913/model \
        --weights "<container>/PhoneticXeus/<rev>/model.safetensors" \
        --clip docs/evidence/pronunciation-2026-09-12/vest-uk.caf \
        --out .build/xeus-onnx

`--snapshot` is the downloaded HF model source tree (see fetch.py) — the same
kind of tree package.py freezes the shipping helper from. It is never modified
in place: cnn_frontend.py's `x = F.layer_norm(x, x.shape)` uses a dynamic shape
argument that torch.onnx.export (TorchScript tracer) cannot trace, so this
script copies just the `src/` subtree into the --out scratch dir and patches
that copy only. The patch is a mathematically-equivalent static rewrite
(documented parity vs. the unpatched model: max|delta logprob| ~2.5e-5).

Produces (under --out, not committed — the .data file is ~1.2 GB, uploaded
separately):
    xeus.onnx       ONNX graph (small; external-data pointer only)
    xeus.onnx.data  all weights, single file

and writes the committed manifest `onnx-manifest.sha256` (sha256 of both
files, in `shasum -a 256 -c`-checkable form) next to this script.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import wave
from pathlib import Path

os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('TRANSFORMERS_OFFLINE', '1')
os.environ.setdefault('TRANSFORMERS_NO_ADVISORY_WARNINGS', '1')

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
HEAD_JSON = HERE / 'uk-contrast-head.json'

DEFAULT_SNAPSHOT = Path('/tmp/echolab-phoneticxeus-20260913/model')
DEFAULT_WEIGHTS = Path(
    '/Users/nat/Library/Containers/com.unknownstudio.tospeech/Data/Library/'
    'Application Support/ToSpeech/Production/Packages/PhoneticXeus/'
    '8d83dee94817a07dc150f87d08f7e0ee01bdb66d/model.safetensors'
)
DEFAULT_CLIP = REPO_ROOT / 'docs/evidence/pronunciation-2026-09-12/vest-uk.caf'
DEFAULT_OUT = REPO_ROOT / '.build/xeus-onnx'

VOCAB_SIZE = 428
OPSET = 17
MAX_ABS_DELTA = 1e-3

# --- cnn_frontend.py patch: dynamic F.layer_norm(x, x.shape) -> static, trace-safe ---
PATCH_MARKER = 'ONNX-export-safe static equiv of F.layer_norm'
ORIGINAL_LAYERNORM_RE = re.compile(r'(?m)^(?P<indent>[ \t]*)x = F\.layer_norm\(x,\s*x\.shape\)[ \t]*$')


def patch_replacement(indent: str) -> str:
    return (
        f'{indent}_m = x.mean(); _v = x.var(unbiased=False); '
        f'x = (x - _m) * torch.rsqrt(_v + 1e-5)  # {PATCH_MARKER}'
    )


def patch_frontend(src_copy_root: Path) -> bool:
    """Patches the scratch copy of cnn_frontend.py. Idempotent: if the marker is
    already present (e.g. --snapshot was itself already patched by a prior spike),
    this is a no-op. Raises if the known patch site can't be found exactly once,
    so upstream drift fails loudly instead of silently shipping an unpatched/
    untraceable graph."""
    path = src_copy_root / 'src/model/xeusphoneme/cnn_frontend.py'
    text = path.read_text()
    if PATCH_MARKER in text:
        print(f'[patch] {path.name} already patched (marker present) — skipping')
        return False
    new_text, n = ORIGINAL_LAYERNORM_RE.subn(lambda m: patch_replacement(m.group('indent')), text)
    if n != 1:
        raise RuntimeError(
            f'expected exactly one `x = F.layer_norm(x, x.shape)` site in {path}, found {n} — '
            'upstream source drifted; update the patch regex'
        )
    path.write_text(new_text)
    print(f'[patch] {path.name}: patched 1 site (dynamic layer_norm -> static rsqrt form)')
    return True


def stage_patched_copy(snapshot: Path, work: Path) -> Path:
    """Copies only the `src/` model-source subtree (source only, no weights) out of
    --snapshot into a scratch dir and patches the copy. --snapshot itself, and
    anything package.py might freeze from it, is left untouched."""
    if not (snapshot / 'src/model/xeusphoneme/cnn_frontend.py').exists():
        raise FileNotFoundError(f'--snapshot {snapshot} missing src/model/xeusphoneme/cnn_frontend.py')
    dest_root = work / 'src-copy'
    dest_src = dest_root / 'src'
    if dest_src.exists():
        shutil.rmtree(dest_src)
    dest_root.mkdir(parents=True, exist_ok=True)
    shutil.copytree(snapshot / 'src', dest_src)
    patch_frontend(dest_root)
    return dest_root


def load_head_layer_dim():
    data = json.loads(HEAD_JSON.read_text())
    return int(data['layer']), int(data['dim'])


def decode_clip(clip: Path, work: Path):
    """Returns mono float32 PCM @16kHz as a numpy array. Raw `.f32` files are read
    as-is (little-endian float32); anything else is decoded via macOS `afconvert`
    (no extra python audio deps needed)."""
    import numpy as np
    if clip.suffix.lower() == '.f32':
        return np.fromfile(clip, dtype='<f4')
    wav_path = work / (clip.stem + '.16k-mono.wav')
    subprocess.run(
        ['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(clip), str(wav_path)],
        check=True,
    )
    with wave.open(str(wav_path), 'rb') as w:
        if w.getframerate() != 16000 or w.getnchannels() != 1 or w.getsampwidth() != 2:
            raise ValueError(f'unexpected decode of {clip}: {w.getparams()}')
        raw = w.readframes(w.getnframes())
    pcm = np.frombuffer(raw, dtype='<i2')
    return (pcm.astype(np.float32) / 32768.0)


def build_wrap(code_root: Path, weights: Path, head_layer: int, head_dim: int):
    """Loads XeusPRModel from the patched copy + real weights, and wraps it so
    forward(values, lengths) -> (log_probs [1,T,428], hidden [1,T,head_dim]),
    `hidden` being the output of encoder.encoders[head_layer-1] — the exact layer
    runtime.py's forward hook captures for the UK contrast head (see
    uk_contrast_head.py / uk-contrast-head.json)."""
    import torch
    from safetensors.torch import load_file

    sys.path.insert(0, str(code_root))
    from src.model.xeusphoneme.builders import build_xeus_pr_from_hf

    cfg = code_root / 'src/model/xeusphoneme/resources/xeus_config.yaml'
    voc = code_root / 'src/model/xeusphoneme/resources/ipa_vocab.json'
    model = build_xeus_pr_from_hf(
        work_dir=str(code_root), hf_repo=None, config_file=str(cfg), vocab_file=str(voc),
        load_ckpt=False, interctc_use_conditioning=True,
    )
    tensors = load_file(str(weights), device='cpu')
    model.load_state_dict({k.removeprefix('model.'): v for k, v in tensors.items()}, strict=True)
    del tensors
    model = model.eval()

    layers = list(model.encoder.encoders)
    if not 1 <= head_layer <= len(layers):
        raise ValueError(f'head layer {head_layer} out of range for {len(layers)} encoder layers')

    class Wrap(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m
            self._hidden = None
            layers[head_layer - 1].register_forward_hook(self._hook)

        def _hook(self, module, inputs, output):
            x = output[0] if isinstance(output, tuple) else output
            x = x[0] if isinstance(x, tuple) else x
            self._hidden = x.float()

        def forward(self, values, lengths):
            self._hidden = None
            h, _ = self.m.encode(values, lengths)
            if isinstance(h, tuple):
                h = h[0]
            log_probs = self.m.ctc.ctc_lo(h).log_softmax(-1)
            return log_probs, self._hidden

    return Wrap(model).eval()


def export_raw(wrap, vals, lens, raw_path: Path):
    import torch
    torch.onnx.export(
        wrap, (vals, lens), str(raw_path),
        input_names=['values', 'lengths'],
        output_names=['log_probs', 'hidden'],
        dynamic_axes={
            'values': {1: 'samples'},
            'log_probs': {1: 'frames'},
            'hidden': {1: 'frames'},
        },
        opset_version=OPSET, do_constant_folding=True, dynamo=False,
    )


def consolidate_external_data(raw_path: Path, final_path: Path, data_name: str):
    """Re-saves the graph torch.onnx.export produced (which spreads weights across
    one loose file per initializer once >2GB) as a single xeus.onnx + a single
    xeus.onnx.data, matching the packaging contract Task 10 expects."""
    import onnx
    model = onnx.load_model(str(raw_path), load_external_data=True)
    onnx.save_model(
        model, str(final_path),
        save_as_external_data=True, all_tensors_to_one_file=True,
        location=data_name, size_threshold=1024,
    )


def sha256_of(path: Path) -> str:
    with path.open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def run_parity(final_onnx: Path, vals_np, lens_np, ref_log_probs, ref_hidden, head_dim):
    import numpy as np
    try:
        import onnxruntime as ort
    except ImportError as e:
        raise SystemExit(
            'onnxruntime not installed in this interpreter. Install it into the xeus-env with:\n'
            '  python -m pip install onnxruntime\n'
            'then re-run this script.'
        ) from e

    sess = ort.InferenceSession(str(final_onnx), providers=['CPUExecutionProvider'])
    input_names = {i.name for i in sess.get_inputs()}
    feed = {'values': vals_np}
    if 'lengths' in input_names:
        feed['lengths'] = lens_np
    outputs = {o.name: v for o, v in zip(sess.get_outputs(), sess.run(None, feed))}

    onnx_log_probs = outputs['log_probs'][0]
    onnx_hidden = outputs['hidden']

    n = min(len(onnx_log_probs), len(ref_log_probs))
    delta = np.abs(onnx_log_probs[:n] - ref_log_probs[:n])
    max_delta = float(delta.max())
    mean_delta = float(delta.mean())
    mismatches = int((onnx_log_probs[:n].argmax(-1) != ref_log_probs[:n].argmax(-1)).sum())

    print(f'[parity] log_probs: onnx {onnx_log_probs.shape} vs torch {ref_log_probs.shape}')
    print(f'[parity] max|delta logprob|={max_delta:.3e}  mean={mean_delta:.3e}  argmax-mismatch={mismatches}/{n}')

    hidden_delta = None
    if onnx_hidden.shape != ref_hidden.shape:
        print(f'[parity] WARNING hidden shape mismatch: onnx {onnx_hidden.shape} vs torch {ref_hidden.shape}')
    else:
        hidden_delta = float(np.abs(onnx_hidden - ref_hidden).max())
        print(f'[parity] hidden: onnx {onnx_hidden.shape} max|delta|={hidden_delta:.3e}')

    ok_shape = onnx_hidden.ndim == 3 and onnx_hidden.shape[0] == 1 and onnx_hidden.shape[-1] == head_dim
    print(f"[parity] hidden shape sanity [1,T,{head_dim}]: {'PASS' if ok_shape else 'FAIL'} (got {onnx_hidden.shape})")

    passed = max_delta < MAX_ABS_DELTA and mismatches == 0 and ok_shape
    print('[parity] VERDICT:', 'PASS' if passed else 'FAIL')
    if not passed:
        raise SystemExit(1)
    return dict(max_delta=max_delta, mean_delta=mean_delta, mismatches=mismatches,
                n_frames=n, hidden_shape=list(onnx_hidden.shape), hidden_max_delta=hidden_delta)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--snapshot', type=Path, default=DEFAULT_SNAPSHOT, help='downloaded HF model source tree (fetch.py)')
    p.add_argument('--weights', type=Path, default=DEFAULT_WEIGHTS, help='model.safetensors path')
    p.add_argument('--clip', type=Path, default=DEFAULT_CLIP, help='parity-check audio clip (.f32 raw, or anything afconvert reads)')
    p.add_argument('--out', type=Path, default=DEFAULT_OUT, help='output/scratch dir for xeus.onnx(+.data); not committed')
    p.add_argument('--skip-parity', action='store_true', help='export only, skip the onnxruntime parity gate (debugging)')
    args = p.parse_args()

    for path, label in ((args.snapshot, '--snapshot'), (args.weights, '--weights'), (args.clip, '--clip')):
        if not path.exists():
            raise SystemExit(f'{label} not found: {path}')

    args.out.mkdir(parents=True, exist_ok=True)
    head_layer, head_dim = load_head_layer_dim()
    print(f'[config] uk-contrast-head.json: layer={head_layer} dim={head_dim}')

    print(f'[stage] copying+patching src/ from {args.snapshot} ...')
    code_root = stage_patched_copy(args.snapshot, args.out)

    print(f'[load] building model + loading weights from {args.weights} ...')
    wrap = build_wrap(code_root, args.weights, head_layer, head_dim)

    print(f'[clip] decoding {args.clip} ...')
    samples = decode_clip(args.clip, args.out)
    print(f'[clip] {len(samples)} samples ({len(samples) / 16000:.2f}s @16kHz)')

    import numpy as np
    import torch
    vals = torch.from_numpy(samples.copy()).unsqueeze(0)
    lens = torch.tensor([len(samples)])

    print('[torch] running reference forward ...')
    with torch.inference_mode():
        ref_log_probs_t, ref_hidden_t = wrap(vals, lens)
    ref_log_probs = ref_log_probs_t[0].cpu().numpy()
    ref_hidden = ref_hidden_t.cpu().numpy()
    print(f'[torch] log_probs {ref_log_probs.shape}  hidden {ref_hidden.shape}')
    if ref_hidden.ndim != 3 or ref_hidden.shape[0] != 1 or ref_hidden.shape[-1] != head_dim:
        raise SystemExit(f'torch reference hidden shape unexpected: {ref_hidden.shape}, want [1,T,{head_dim}]')

    raw_path = args.out / 'raw-export' / 'xeus.onnx'
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    print(f'[export] torch.onnx.export (opset {OPSET}, dynamo=False) -> {raw_path} ...')
    export_raw(wrap, vals, lens, raw_path)
    print(f'[export] raw export OK, {raw_path.parent} has {len(list(raw_path.parent.glob("*")))} files')

    final_onnx = args.out / 'xeus.onnx'
    data_name = 'xeus.onnx.data'
    print(f'[consolidate] -> single-file external data: {final_onnx.name} + {data_name} ...')
    consolidate_external_data(raw_path, final_onnx, data_name)
    final_data = args.out / data_name
    print(f'[consolidate] {final_onnx.name}: {final_onnx.stat().st_size} bytes')
    print(f'[consolidate] {data_name}: {final_data.stat().st_size} bytes')

    if not args.skip_parity:
        vals_np = samples.reshape(1, -1).astype(np.float32)
        lens_np = np.array([len(samples)], dtype=np.int64)
        run_parity(final_onnx, vals_np, lens_np, ref_log_probs, ref_hidden, head_dim)
    else:
        print('[parity] skipped (--skip-parity)')

    print('[manifest] hashing artifacts ...')
    onnx_hash = sha256_of(final_onnx)
    data_hash = sha256_of(final_data)
    manifest_path = HERE / 'onnx-manifest.sha256'
    manifest_path.write_text(f'{onnx_hash}  {final_onnx.name}\n{data_hash}  {data_name}\n')
    print(f'[manifest] {manifest_path}')
    print(f'  {onnx_hash}  {final_onnx.name}')
    print(f'  {data_hash}  {data_name}')
    print(f'[done] artifacts in {args.out} (not committed); manifest committed at {manifest_path}')


if __name__ == '__main__':
    main()
