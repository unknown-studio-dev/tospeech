"""Freeze the reviewed local alignment package; build staging never regenerates hashes.

Mirrors scripts/assessment/freeze_uk_package.py for the word-alignment package. Only the
shipped subset of vendor/alignment is hashed (EnglishAlignment.mlmodelc, vocab.json,
provenance.json) — EnglishAlignment.mlpackage is the Core ML source artifact, never staged
into the app bundle, and is deliberately excluded.
"""

import hashlib, json, re
from pathlib import Path

native = Path(__file__).resolve().parents[2]
package = native / "vendor/alignment"
required = [
    "EnglishAlignment.mlmodelc/model.mil",
    "EnglishAlignment.mlmodelc/metadata.json",
    "EnglishAlignment.mlmodelc/coremldata.bin",
    "EnglishAlignment.mlmodelc/analytics/coremldata.bin",
    "EnglishAlignment.mlmodelc/weights/weight.bin",
    "vocab.json",
    "provenance.json",
]
assert all((package / name).is_file() for name in required), "vendor/alignment is missing a required file"

hashes = {
    name: hashlib.file_digest((package / name).open("rb"), "sha256").hexdigest()
    for name in required
}
manifest = package / "checksums.json"
manifest.write_text(json.dumps(hashes, sort_keys=True, indent=2) + "\n")
digest = hashlib.sha256(manifest.read_bytes()).hexdigest()

swift = native / "ToSpeech/Services/Production/Assessment/AlignmentPackage.swift"
text = swift.read_text()
text, count = re.subn(
    r'static let manifestHash = "[^"]+"', f'static let manifestHash = "{digest}"', text
)
assert count == 1, "AlignmentPackage.swift must declare exactly one manifestHash literal"
swift.write_text(text)

(native / "scripts/alignment/alignment-manifest.sha256").write_text(
    f"{digest}  checksums.json\n"
)
print(
    "Manifest:", digest,
    "bytes:", sum((package / name).stat().st_size for name in required),
)
