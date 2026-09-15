"""Verify saved start offsets from the original EUSTACE ESPS archives.

Download eustace_esps_{f1,f2,f3,m1,m2,m3}.tar.gz from the corpus site and
name them {speaker}-esps.tar.gz under --archives. No data are uploaded.
WAV copies discard the ESPS start_time. Lab timestamps retain that offset.
"""

import argparse, json, math, struct, tarfile
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--archives", type=Path, required=True)
a = p.parse_args()
expected = json.loads(Path(__file__).with_name("eustace-start-times.json").read_text())
actual = {}
for speaker in ["f1", "f2", "f3", "m1", "m2", "m3"]:
    with tarfile.open(a.archives / f"{speaker}-esps.tar.gz", "r|gz") as archive:
        for member in archive:
            if not member.name.endswith(".sd"):
                continue
            header = archive.extractfile(member).read(4096)
            i = header.find(b"start_time\0")
            assert i >= 0, member.name
            start = struct.unpack(">d", header[i + 18 : i + 26])[0]
            assert math.isfinite(start) and 0 <= start < 5000
            actual[Path(member.name).stem] = start
assert len(actual) == 384 and actual == expected
print("Verified all 384 offsets against original ESPS headers.")
