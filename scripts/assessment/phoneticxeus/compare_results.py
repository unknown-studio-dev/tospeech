"""Compare two pronunciation-probe result JSONs phone by phone.

Equality claims about a latency change must not depend on eyeballing two files. This loads two
`pronunciation-probe-result*.json` documents and compares, for every phone, the tuple the UI shows
(quality, kind, expected, observed, unassessedReason) and the raw XEUS row
(expected, status, reason, licence, contrast.decision). Labels that are expected to move between
runs — provenance, runtime hash, ids, timings, probabilities — are deliberately not compared.

Usage: compare_results.py <a.json> <b.json>   # exit 0 when identical, 1 on the first difference

A document either side of which yields no phones is reported as `NO PHONES FOUND` and exits 1: two
empty documents compare equal, and that is never the equality anyone is asking about.
"""
import json
import sys

QUALITIES = ["correct", "nearCorrect", "incorrect", "unassessed"]


def load(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def display_phones(job):
    """[(key, tuple)] for the display layer, in document order."""
    rows = []
    for index, word in enumerate(job.get("result", {}).get("words") or []):
        identifier = (word.get("target") or {}).get("id")
        for position, phone in enumerate(word.get("phones") or []):
            rows.append(((index, identifier, position),
                (phone.get("quality"), phone.get("kind"), phone.get("expected"),
                 phone.get("observed"), phone.get("unassessedReason"))))
    return rows


def xeus_phones(job):
    """[(key, tuple)] for the raw helper rows, in document order."""
    rows = []
    evidence = job.get("result", {}).get("phoneticXeus") or {}
    for index, word in enumerate(evidence.get("words") or []):
        identifier = word.get("id")
        for position, phone in enumerate(word.get("phones") or []):
            contrast = phone.get("contrast") or {}
            rows.append(((index, identifier, position),
                (phone.get("expected"), phone.get("status"), phone.get("reason"),
                 phone.get("licence"), contrast.get("decision"))))
    return rows


def counts(rows):
    """Quality table of display rows; unknown qualities are reported under their own name."""
    table = {quality: 0 for quality in QUALITIES}
    for _, tuple_ in rows:
        table[tuple_[0]] = table.get(tuple_[0], 0) + 1
    return table


def format_counts(table, total):
    known = " / ".join(str(table.get(quality, 0)) for quality in QUALITIES)
    extra = {name: value for name, value in table.items() if name not in QUALITIES and value}
    return f"{known} (correct/nearCorrect/incorrect/unassessed) over {total} phones" + (
        f" plus {extra}" if extra else "")


def first_difference(left, right):
    """None when equal, else a human-readable description of the first differing phone."""
    if len(left) != len(right):
        return f"phone count differs: {len(left)} vs {len(right)}"
    for (key_a, tuple_a), (key_b, tuple_b) in zip(left, right):
        if key_a != key_b:
            return f"phone identity differs: {key_a} vs {key_b}"
        if tuple_a != tuple_b:
            index, identifier, position = key_a
            return (f"word {index} ({identifier}) phone {position}: "
                    f"a={tuple_a} b={tuple_b}")
    return None


def compare(a, b):
    """(ok, lines) — the printed report for two already-loaded jobs."""
    lines, ok = [], True
    display_a, display_b = display_phones(a), display_phones(b)
    lines.append("display a: " + format_counts(counts(display_a), len(display_a)))
    lines.append("display b: " + format_counts(counts(display_b), len(display_b)))
    xeus_a, xeus_b = xeus_phones(a), xeus_phones(b)
    # "No difference found" must never be the answer to "no phones were read". A renamed key, a
    # truncated file or a failed job yields zero rows on both sides, which compares equal.
    if not (display_a and display_b and xeus_a and xeus_b):
        lines.append(f"display rows: a={len(display_a)} b={len(display_b)}; "
                     f"xeus rows: a={len(xeus_a)} b={len(xeus_b)}")
        lines.append("NO PHONES FOUND")
        return False, lines
    difference = first_difference(display_a, display_b)
    if difference:
        ok = False
        lines.append("display DIFFERENT — " + difference)
    else:
        lines.append(f"display IDENTICAL ({len(display_a)} phones)")
    difference = first_difference(xeus_a, xeus_b)
    if difference:
        ok = False
        lines.append("xeus DIFFERENT — " + difference)
    else:
        lines.append(f"xeus IDENTICAL ({len(xeus_a)} rows)")
    lines.append("IDENTICAL" if ok else "DIFFERENT")
    return ok, lines


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip())
        return 2
    ok, lines = compare(load(argv[0]), load(argv[1]))
    print("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
