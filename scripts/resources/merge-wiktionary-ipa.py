#!/usr/bin/env python3
"""Add Wiktionary pronunciations for words the primary dictionaries lack.

Called by build-ipa-dictionary.sh after ipa-dict (US) and Britfone (UK) are
imported. Rows come from wiktionary-ipa.tsv (word, accent, ipa, tags), extracted
from the kaikki.org wiktextract dump. UK rows are normalised to the Britfone
spelling and must parse with the app's UK phone inventory; anything else is
dropped so the assessment path never meets an unknown symbol.

usage: merge-wiktionary-ipa.py <ipa.sqlite> <wiktionary-ipa.tsv> <source_revision> [wiktionary-forms.tsv]

With the forms table, regular UK inflections (plural, -s, -ed, -ing, -er, -est)
of words that have a UK pronunciation are derived by suffix phonology and stored
as source `wiktionary-inflected`.
"""
import collections, re, sqlite3, sys, unicodedata

MAX_VARIANTS = 3

# Mirror of UKPhoneInventory.symbols in ToSpeech/Domain/Rules/UKPhoneInventory.swift.
# ProductionPersistenceTests.bundledUKPronunciationsParseWithUKInventory checks the
# built database against the Swift parser, so a drift here fails the test suite.
UK_VOWELS = ["iː", "ɪ", "e", "ɛ", "æ", "ɑː", "ɒ", "ɔː", "ʊ", "uː", "ʌ", "ɐ", "ɜː", "ə", "i", "u",
             "eɪ", "aɪ", "ɔɪ", "əʊ", "aʊ", "ɪə", "eə", "ɛə", "ʊə", "ɛː", "ɪː", "ʊː"]
UK_CONSONANTS = ["p", "b", "t", "d", "k", "ɡ", "g", "f", "v", "θ", "ð", "s", "z", "ʃ", "ʒ", "h", "tʃ", "dʒ",
                 "m", "n", "ŋ", "l", "ɹ", "r", "j", "w", "ʔ", "l̩", "n̩", "m̩"]
UK_SYMBOLS = sorted(set(UK_VOWELS + UK_CONSONANTS), key=lambda s: (-len(s), s))


def parses_uk(ipa):
    rest = unicodedata.normalize("NFC", ipa)
    found = False
    while rest:
        if rest[0] in "ˈˌ/[]. ‿":
            rest = rest[1:]
            continue
        for symbol in UK_SYMBOLS:
            if rest.startswith(symbol):
                rest = rest[len(symbol):]
                found = True
                break
        else:
            return False
    return found


def normalize_uk(ipa):
    ipa = unicodedata.normalize("NFC", ipa)
    ipa = ipa.replace("͡", "").replace("̯", "").replace("ɫ", "l").replace("ɾ", "t")
    ipa = ipa.replace("ɚ", "ə").replace("ɝ", "ɜː").replace("r", "ɹ")
    # Modern-RP notation writes TRAP as /a/; the app inventory uses /æ/.
    ipa = re.sub(r"a(?![ɪʊ])", "æ", ipa)
    return ipa


def normalize_us(ipa):
    return unicodedata.normalize("NFC", ipa).replace("͡", "").replace("̯", "")


def expand_optional(ipa):
    """'ˈskɛdʒ(u)(ə)l' -> ['ˈskɛdʒuəl', 'ˈskɛdʒl']: keep-all first, then drop-all."""
    if "(" not in ipa:
        return [ipa]
    kept = re.sub(r"[()]", "", ipa)
    dropped = re.sub(r"\([^()]*\)", "", ipa)
    return [kept] if kept == dropped else [kept, dropped]


US_MARKERS = re.compile(r"[ɚɝɾ]|oʊ|ɹ(?=[^aeiouæɑɒɔəɛɜɪʊʌː]|$)")  # r-coloured vowels, GOAT as oʊ, flap, rhotic coda
UK_MARKERS = re.compile(r"[ɒ]|əʊ|ɜː|ɪə|eə|ʊə")


LINKING_R = re.compile(r"\((ɹ|r)\)")  # Wiktionary's non-rhotic notation for a linking r


def untagged_accents(ipa):
    """Accents an unlabelled Wiktionary transcription is compatible with."""
    accents = []
    if not US_MARKERS.search(normalize_us(LINKING_R.sub("", ipa))):
        accents.append("uk")
    if not UK_MARKERS.search(normalize_us(ipa)):
        accents.append("us")
    return accents


SIBILANTS = {"s", "z", "ʃ", "ʒ", "tʃ", "dʒ"}
VOICELESS = {"p", "t", "k", "f", "θ", "s", "ʃ", "tʃ", "h"}


def last_phone(ipa):
    for symbol in UK_SYMBOLS:
        if ipa.endswith(symbol):
            return symbol
    return None


def inflection_kind(tags):
    tags = set(tags.split(","))
    if "plural" in tags or {"third-person", "singular"} <= tags:
        return "s"
    if "past" in tags:
        return "ed"
    if {"participle", "present"} <= tags:
        return "ing"
    if "comparative" in tags:
        return "er"
    if "superlative" in tags:
        return "est"
    return None


def regular_spelling(base, form, kind):
    """Only regular suffixation is derived; children, went, knives are left out."""
    b = base
    y = b[:-1] if b.endswith("y") else None
    doubled = b + b[-1]
    options = {
        "s": [b + "s", b + "es", y and y + "ies"],
        "ed": [b + "ed", b + "d", y and y + "ied", doubled + "ed"],
        "ing": [b + "ing", b[:-1] + "ing", doubled + "ing", b.endswith("ie") and b[:-2] + "ying"],
        "er": [b + "er", b + "r", y and y + "ier", doubled + "er"],
        "est": [b + "est", b + "st", y and y + "iest", doubled + "est"],
    }[kind]
    return form in [o for o in options if o]


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def close_spelling(base, form):
    """Alternative spellings share a pronunciation only when the change is small
    (ise/ize, our/or, re/er, programme). A longer form usually adds a syllable."""
    if form == base + "me" or base == form + "me":
        return True
    return edit_distance(base, form) <= 2 and abs(len(base) - len(form)) <= 1


def inflect_uk(ipa, base, kind):
    """RP suffix phonology on a base transcription that already parses."""
    last = last_phone(ipa)
    if last is None:
        return None
    if kind == "s":
        return ipa + ("ɪz" if last in SIBILANTS else "s" if last in VOICELESS else "z")
    if kind == "ed":
        return ipa + ("ɪd" if last in ("t", "d") else "t" if last in VOICELESS else "d")
    # Non-rhotic base + vowel-initial suffix: the written r surfaces as linking r.
    link = "ɹ" if (base.endswith("r") or base.endswith("re")) and last in UK_VOWELS else ""
    return ipa + link + {"ing": "ɪŋ", "er": "ə", "est": "ɪst"}[kind]


def main(db_path, tsv_path, revision, forms_path=None):
    db = sqlite3.connect(db_path)
    existing = {
        accent: {row[0] for row in db.execute("SELECT DISTINCT lookup_key FROM pronunciations WHERE accent = ?", (accent,))}
        for accent in ("uk", "us")
    }
    tagged, untagged = [], []
    with open(tsv_path, encoding="utf-8") as tsv:
        for line in tsv:
            word, accent, ipa, _tags = line.rstrip("\n").split("\t")
            (untagged if accent == "none" else tagged).append((word.lower(), accent, ipa))
    variants = collections.defaultdict(list)
    dropped = collections.Counter()

    def consider(key, accent, ipa, source):
        if key in existing[accent] or (accent, key) in variants and variants[(accent, key)]["source"] != source:
            dropped[f"{accent}-covered"] += 1
            return
        if accent == "uk":
            ipa = LINKING_R.sub("", ipa)  # RP in isolation has no final r
        for form in expand_optional(ipa):
            if accent == "uk":
                form = normalize_uk(form)
                if not parses_uk(form):
                    dropped["uk-unparseable"] += 1
                    continue
                if US_MARKERS.search(form):
                    dropped["uk-rhotic"] += 1  # editors sometimes omit the parentheses
                    continue
            else:
                form = normalize_us(form)
            bucket = variants.setdefault((accent, key), {"source": source, "ipas": []})
            if form in bucket["ipas"] or len(bucket["ipas"]) >= MAX_VARIANTS:
                continue
            bucket["ipas"].append(form)

    # Labelled UK/US transcriptions first; unlabelled ones only for words that
    # still lack the accent, assigned by phonetic markers and stored under a
    # separate source name so the provenance stays visible.
    for key, accent, ipa in tagged:
        consider(key, accent, ipa, "wiktionary")
    for key, _, ipa in untagged:
        for accent in untagged_accents(ipa):
            consider(key, accent, ipa, "wiktionary-untagged")

    # Regular UK inflections: Wiktionary declares the form and its kind on the
    # base entry, so only the suffix phonology is rule-based.
    if forms_path:
        base_ipa = collections.defaultdict(list)
        for key, ipa in db.execute("SELECT lookup_key, ipa FROM pronunciations WHERE accent = 'uk' ORDER BY lookup_key, variant"):
            base_ipa[key].append(ipa)
        for (accent, key), bucket in variants.items():
            if accent == "uk" and key not in base_ipa:
                base_ipa[key] = list(bucket["ipas"])
        derived_sources = {"wiktionary-inflected", "wiktionary-altspelling"}
        with open(forms_path, encoding="utf-8") as forms:
            form_rows = [line.rstrip("\n").split("\t") for line in forms]
        # Chains such as customised -> customized -> customize need several
        # passes: each pass derives what the previous one made available.
        for _ in range(4):
            new = 0
            for base, form, tags in form_rows:
                if base not in base_ipa or ("uk", form) in variants or form in existing["uk"]:
                    continue
                if tags == "alt_of":
                    if not close_spelling(base, form):
                        dropped["uk-alt-distant"] += 1  # geodesical vs geodesic: not the same sounds
                        continue
                    kind, source = None, "wiktionary-altspelling"
                else:
                    kind, source = inflection_kind(tags), "wiktionary-inflected"
                    if not kind or not regular_spelling(base, form, kind):
                        continue
                for ipa in base_ipa[base][:2]:
                    derived = inflect_uk(ipa, base, kind) if kind else ipa
                    if not derived or not parses_uk(derived):
                        dropped["uk-inflect-unparseable"] += 1
                        continue
                    bucket = variants.setdefault(("uk", form), {"source": source, "ipas": []})
                    if derived not in bucket["ipas"] and len(bucket["ipas"]) < 2:
                        bucket["ipas"].append(derived); new += 1
                        base_ipa[form] = bucket["ipas"]
            if not new:
                break
    rows = [(accent, key, index, ipa, bucket["source"], revision)
            for (accent, key), bucket in variants.items() for index, ipa in enumerate(bucket["ipas"])]
    db.executemany("INSERT INTO pronunciations VALUES (?, ?, ?, ?, ?, ?)", rows)
    db.commit()
    added = collections.Counter((accent, bucket["source"]) for (accent, _), bucket in variants.items())
    print(f"wiktionary: {len(rows)} rows; words added {dict(added)}; dropped {dict(dropped)}")


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    main(*sys.argv[1:5])
