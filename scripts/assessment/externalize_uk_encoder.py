"""Turn the exported UK encoder into a graph that reads its weights straight from the
upstream `pytorch_model.bin` (facebook/wav2vec2-xlsr-53-espeak-cv-ft), so the app
downloads the original checkpoint and ships only this small graph.

`torch.save` writes each parameter as an uncompressed ZIP entry, so every tensor sits at a
fixed byte offset in the file. ONNX external data addresses initializers by file, offset and
length, which means no conversion has to happen on the user's machine:
  * initializers equal to a parameter point at that parameter;
  * Linear weights, which the exporter stored transposed, point at the untransposed parameter
    and their MatMul becomes ORT's FusedMatMul(transB=1);
  * the positional convolution's weight-normalised kernel is rebuilt in-graph from weight_g
    and weight_v.
Run after export_uk_reference.py; then place the checkpoint next to encoder.onnx and freeze.
"""

import argparse, collections, hashlib, json, shutil, struct, time, zipfile
from pathlib import Path
import numpy as np, onnx, onnxruntime as ort, torch
from onnx import TensorProto, external_data_helper, helper, numpy_helper

p = argparse.ArgumentParser()
p.add_argument("--encoder", type=Path, required=True, help="self-contained encoder.onnx from export_uk_reference.py")
p.add_argument("--checkpoint", type=Path, required=True, help="upstream pytorch_model.bin")
p.add_argument("--output", type=Path, required=True, help="directory receiving encoder.onnx (+ a checkpoint copy for the parity run)")
a = p.parse_args()
WEIGHTS = "pytorch_model.bin"

# --- where each parameter lives inside the checkpoint zip -------------------------------------
zf = zipfile.ZipFile(a.checkpoint)
entries = {}
with a.checkpoint.open("rb") as f:
    for info in zf.infolist():
        assert info.compress_type == zipfile.ZIP_STORED, info.filename
        f.seek(info.header_offset)
        header = f.read(30)
        assert header[:4] == b"PK\x03\x04"
        name_length, extra_length = struct.unpack("<HH", header[26:30])
        entries[info.filename] = (info.header_offset + 30 + name_length + extra_length, info.file_size)
state = torch.load(a.checkpoint, map_location="cpu", weights_only=True)
by_digest = collections.defaultdict(list)
with a.checkpoint.open("rb") as f:
    for name, (offset, size) in entries.items():
        if not name.startswith("archive/data/"): continue
        f.seek(offset)
        by_digest[hashlib.sha256(f.read(size)).hexdigest()].append((offset, size))
params = {}
for name, tensor in state.items():
    raw = tensor.contiguous().numpy().tobytes()
    matches = by_digest.get(hashlib.sha256(raw).hexdigest())
    assert matches, f"{name} is not a whole zip entry"
    params[name] = (matches[0][0], len(raw), raw, tuple(tensor.shape))
by_bytes = {}
for name, (offset, length, raw, shape) in params.items():
    by_bytes.setdefault(hashlib.sha256(raw).hexdigest(), (name, offset, length, shape))

def external(tensor, offset, length):
    if not tensor.HasField("raw_data"): tensor.raw_data = b""
    external_data_helper.set_external_data(tensor, WEIGHTS, offset=offset, length=length)
    tensor.ClearField("raw_data")

# --- rewrite the graph ------------------------------------------------------------------------
model = onnx.load(str(a.encoder))
graph = model.graph
initializers = {t.name: t for t in graph.initializer}
consumers = collections.defaultdict(list)
for node in graph.node:
    for index, name in enumerate(node.input):
        if name in initializers: consumers[name].append((node, index))
kept, mapped, transposed = [], 0, 0
pos_conv = None
for name, tensor in initializers.items():
    raw = tensor.raw_data if tensor.HasField("raw_data") else numpy_helper.to_array(tensor).tobytes()
    if tensor.data_type != TensorProto.FLOAT:
        kept.append((name, len(raw))); continue
    direct = by_bytes.get(hashlib.sha256(raw).hexdigest())
    if direct:
        external(tensor, direct[1], direct[2]); mapped += len(raw); continue
    dims = list(tensor.dims)
    if len(dims) == 2 and all(node.op_type == "MatMul" and index == 1 for node, index in consumers[name]):
        flipped = np.frombuffer(raw, dtype=np.float32).reshape(dims).T.copy().tobytes()
        source = by_bytes.get(hashlib.sha256(flipped).hexdigest())
        if source:
            for node, _ in consumers[name]:
                node.op_type, node.domain = "FusedMatMul", "com.microsoft"
                node.attribute.extend([helper.make_attribute("transB", 1), helper.make_attribute("alpha", 1.0)])
            del tensor.dims[:]; tensor.dims.extend([dims[1], dims[0]])
            external(tensor, source[1], source[2]); transposed += len(raw); continue
    if dims == list(params["wav2vec2.encoder.pos_conv_embed.conv.weight_v"][3]):
        pos_conv = (name, np.frombuffer(raw, dtype=np.float32).reshape(dims)); continue
    kept.append((name, len(raw)))
assert pos_conv, "positional convolution kernel not found"

# weight = v * g / ||v||, norm over every axis but the last (torch weight_norm, dim=2)
name, folded = pos_conv
g, v = params["wav2vec2.encoder.pos_conv_embed.conv.weight_g"], params["wav2vec2.encoder.pos_conv_embed.conv.weight_v"]
graph.initializer.remove(initializers[name])
for suffix, source in [("g", g), ("v", v)]:
    tensor = TensorProto(name=f"{name}_{suffix}", data_type=TensorProto.FLOAT, dims=list(source[3]))
    external(tensor, source[0], source[1])
    graph.initializer.append(tensor)
graph.initializer.append(numpy_helper.from_array(np.array([0, 1], dtype=np.int64), f"{name}_axes"))
graph.node.insert(0, helper.make_node("Mul", [f"{name}_v", f"{name}_v"], [f"{name}_sq"]))
graph.node.insert(1, helper.make_node("ReduceSum", [f"{name}_sq", f"{name}_axes"], [f"{name}_sumsq"], keepdims=1))
graph.node.insert(2, helper.make_node("Sqrt", [f"{name}_sumsq"], [f"{name}_norm"]))
graph.node.insert(3, helper.make_node("Div", [f"{name}_g", f"{name}_norm"], [f"{name}_scale"]))
graph.node.insert(4, helper.make_node("Mul", [f"{name}_v", f"{name}_scale"], [name]))
rebuilt = v_np = np.frombuffer(v[2], dtype=np.float32).reshape(v[3])
scale = np.frombuffer(g[2], dtype=np.float32).reshape(g[3]) / np.sqrt((v_np * v_np).sum(axis=(0, 1), keepdims=True))
print("pos_conv rebuild max abs error", float(np.max(np.abs(v_np * scale - folded))))
if not any(o.domain == "com.microsoft" for o in model.opset_import):
    model.opset_import.append(helper.make_opsetid("com.microsoft", 1))
a.output.mkdir(parents=True, exist_ok=True)
# ORT refuses external data outside the model directory, symlinks included: copy the checkpoint.
if not (a.output / WEIGHTS).exists(): shutil.copyfile(a.checkpoint, a.output / WEIGHTS)
onnx.save(model, str(a.output / "encoder.onnx"))
onnx.checker.check_model(str(a.output / "encoder.onnx"))
print("mapped", mapped, "transposed", transposed, "inline", sum(s for _, s in kept), "inline tensors", len(kept))
print("graph bytes", (a.output / "encoder.onnx").stat().st_size)

# --- parity against the self-contained export ---------------------------------------------------
options = ort.SessionOptions(); options.intra_op_num_threads = 2
before = ort.InferenceSession(str(a.encoder), options, providers=["CPUExecutionProvider"])
start = time.monotonic()
after = ort.InferenceSession(str(a.output / "encoder.onnx"), options, providers=["CPUExecutionProvider"])
print("session load seconds", time.monotonic() - start)
checks = []
for n in [16000, 23171, 48000]:
    torch.manual_seed(11)
    x = torch.randn(1, n).numpy()
    expected, actual = before.run(None, {"samples": x}), after.run(None, {"samples": x})
    checks.append({"samples": n, "max_absolute_error": [float(np.max(np.abs(e - z))) for e, z in zip(expected, actual)]})
print(json.dumps(checks))
assert all(max(c["max_absolute_error"]) < 1e-3 for c in checks), checks
