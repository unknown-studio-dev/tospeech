#!/usr/bin/env python3
"""Extract UK/US IPA rows from the kaikki.org English wiktextract dump.

usage: gzip -dc kaikki.org-dictionary-English.jsonl.gz | python3 extract-wiktionary-ipa.py /dev/stdin wiktionary-ipa.tsv wiktionary-forms.tsv

First output (word, accent, ipa, tags): phonemic transcriptions labelled UK/RP or
US/GA, plus unlabelled ones as accent "none" for merge-wiktionary-ipa.py to
assign. Phonetic [..] transcriptions, other dialect labels and multi-word entries
are skipped; slashes and syllable dots are removed.

Second output (base, form, tags): regular inflections and alternative spellings
that point at a word which has IPA somewhere in the dump, gathered from the
base entry's `forms` table, from `form_of` senses on the inflected entry, and
from `alt_of` senses (tags "alt_of"). Both results are committed and pinned by
build-ipa-dictionary.sh.
"""
import collections, json, re, sys

UK = {"UK", "RP", "Received-Pronunciation", "British", "England", "Southern-England"}
US = {"US", "GA", "General-American", "American", "GenAm"}
FORM_TAGS = {"plural", "third-person", "past", "participle", "comparative", "superlative"}
SKIP_TAGS = {"table-tags", "inflection-template", "alternative", "archaic", "obsolete", "nonstandard", "rare",
             "dated", "error-unrecognized-form"}
# Alternative spellings worth a pronunciation: not misspellings, eye dialect or dead forms.
ALT_SKIP_TAGS = {"misspelling", "obsolete", "archaic", "nonstandard", "rare", "dated", "eye-dialect",
                 "pronunciation-spelling", "abbreviation", "initialism", "acronym", "informal", "slang", "humorous"}
WORD = re.compile(r"[A-Za-z][A-Za-z'\-]*")

src, dst, forms_dst = sys.argv[1], sys.argv[2], sys.argv[3]
seen = set(); forms = set(); ipa_words = set(); counts = collections.Counter(); n = 0
with open(src, encoding="utf-8") as f, open(dst, "w", encoding="utf-8") as out:
    for line in f:
        n += 1
        if '"ipa"' not in line and '"forms"' not in line and '"form_of"' not in line and '"alt_of"' not in line:
            continue
        d = json.loads(line)
        w = d.get("word", "")
        if not w or not WORD.fullmatch(w):
            continue
        w = w.lower()
        for s in d.get("sounds", []):
            ipa = s.get("ipa"); tags = set(s.get("tags", []))
            if not ipa or ipa.startswith("["):
                continue
            accent = "uk" if tags & UK else "us" if tags & US else "none" if not tags else None
            if accent is None:
                continue
            ipa = ipa.strip("/").replace(".", "").strip()
            key = (w, accent, ipa)
            if not ipa or key in seen:
                continue
            seen.add(key); counts[accent] += 1; ipa_words.add(w)
            out.write(f"{w}\t{accent}\t{ipa}\t{','.join(sorted(tags))}\n")
        for fm in d.get("forms", []):
            form = fm.get("form", "").lower(); tags = set(fm.get("tags", []))
            if tags & FORM_TAGS and not tags & SKIP_TAGS and WORD.fullmatch(form) and form != w:
                forms.add((w, form, ",".join(sorted(tags))))
        for sense in d.get("senses", []):
            tags = set(sense.get("tags", []))
            for ref in sense.get("form_of", []):
                base = ref.get("word", "").lower()
                if base and WORD.fullmatch(base) and base != w and tags & FORM_TAGS and not tags & SKIP_TAGS:
                    forms.add((base, w, ",".join(sorted(tags & (FORM_TAGS | {"singular", "present"})))))
            if tags & ALT_SKIP_TAGS:
                continue
            for ref in sense.get("alt_of", []):
                base = ref.get("word", "").lower()
                if base and WORD.fullmatch(base) and base != w:
                    forms.add((base, w, "alt_of"))
# A base is usable when it has IPA itself or resolves to one through other rows
# (customised -> customized -> customize), so close the relation before writing.
resolvable = set(ipa_words)
while True:
    added = {form for base, form, _ in forms if base in resolvable and form not in resolvable}
    if not added:
        break
    resolvable |= added
with open(forms_dst, "w", encoding="utf-8") as forms_out:
    for base, form, tags in sorted(forms):
        if base in resolvable:
            counts["forms"] += 1
            forms_out.write(f"{base}\t{form}\t{tags}\n")
print(f"lines {n}; rows uk {counts['uk']} us {counts['us']} none {counts['none']}; forms {counts['forms']}")
