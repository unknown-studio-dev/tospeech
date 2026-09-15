"""Freeze a reviewed local UK package; build staging never regenerates hashes."""

import argparse, hashlib, json, re
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--package", type=Path, required=True)
a = p.parse_args()
native = Path(__file__).resolve().parents[2]
required = [
    "encoder.onnx",
    "pytorch_model.bin",
    "vad.onnx",
    "pitch.onnx",
    "vocab.json",
    "uk-vowels.json",
    "uk-focus.json",
    "uk-stress.json",
    "uk-boundary.json",
    "espeak-ng",
    "espeak-ng-data/en_dict",
]
assert all((a.package / name).is_file() for name in required)
for name in ["uk-vowels.json", "uk-focus.json", "uk-stress.json", "uk-boundary.json"]:
    head = json.loads((a.package / name).read_text())
    assert head["metrics"]["speakers"] == 6 and len(head["metrics"]["folds"]) == 6
    assert head["metrics"]["examples"] > 1000
# Hash all resources, including English G2P data and third-party notices.
hashes = {
    str(f.relative_to(a.package)): hashlib.file_digest(
        f.open("rb"), "sha256"
    ).hexdigest()
    for f in sorted(a.package.rglob("*"))
    if f.is_file() and f.name not in ["checksums.json", "verified.txt"]
}
manifest = a.package / "checksums.json"
manifest.write_text(json.dumps(hashes, sort_keys=True, indent=2) + "\n")
digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
swift = native / "ToSpeech/Services/Production/Assessment/UKReferencePackage.swift"
text = swift.read_text()
text, count = re.subn(
    r'static let manifestHash = "[^"]+"', f'static let manifestHash = "{digest}"', text
)
assert count == 1
swift.write_text(text)
(native / "scripts/assessment/uk-manifest.sha256").write_text(
    f"{digest}  checksums.json\n"
)
(
    native / "docs/evidence/uk-reference-implementation-2026-09-12/package-manifest.json"
).write_bytes(manifest.read_bytes())
print(
    "Manifest:",
    digest,
    "bytes:",
    sum(f.stat().st_size for f in a.package.rglob("*") if f.is_file()),
)
