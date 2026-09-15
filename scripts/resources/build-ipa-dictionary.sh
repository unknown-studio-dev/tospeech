#!/bin/bash
set -euo pipefail

# Generates the offline lookup database shipped with ToSpeech. Source revisions and
# checksums are deliberately pinned: a release build must not silently absorb a
# changed remote dictionary. This script is a release-preparation step, not an app
# runtime dependency; the app never downloads dictionary data.

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
output_dir="${root_dir}/ToSpeech/Resources/IPA"
output_db="${output_dir}/ipa.sqlite"
temp_dir="$(mktemp -d)"
trap 'rm -rf "${temp_dir}"' EXIT

ipa_dict_revision="43c3570eb3553bdd19fccd2bd0091534889af023"
ipa_dict_sha256="2af6f154a5c363275f052d1f85acedef38ed185ca9745aa4314be77f6b70de67"
britfone_revision="1062be14adc96c358f2087ac5449d72130c7a6f4"
britfone_sha256="59f197e98520856d1cc88e380beb54e4314d8712efc4d588b6778819c502d920"
# Wiktionary layer: word/accent/IPA rows extracted from the kaikki.org wiktextract
# English dump (CC BY-SA 4.0). kaikki overwrites its dump weekly, so the extracted
# TSV is committed and pinned instead of the 3 GB source. Regenerate with
# scripts/resources/extract-wiktionary-ipa.py when intentionally refreshing.
wiktionary_tsv="${root_dir}/scripts/resources/wiktionary-ipa.tsv"
wiktionary_revision="kaikki-2026-09-09"
wiktionary_forms="${root_dir}/scripts/resources/wiktionary-forms.tsv"
wiktionary_forms_sha256="df818fcf5919de3aa987c42e6417db2126e74c06b55e92619de7471b3b892154"
wiktionary_sha256="17b2e9f1d8c8dba800e65a071de9e87054b881be97464756e760bbe802a9f52d"
cc_by_sa_sha256="28a9529c7d0bb4dc51f4bf5c116a3d16ef247a052f7591466768ddf563fd1cf5"

fetch() {
  local url="$1"
  local target="$2"
  curl --fail --location --silent --show-error --retry 3 "$url" -o "$target"
}

verify_sha256() {
  local expected="$1"
  local path="$2"
  local actual
  actual="$(shasum -a 256 "$path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    echo "Checksum mismatch for $path" >&2
    exit 1
  fi
}

fetch \
  "https://raw.githubusercontent.com/open-dict-data/ipa-dict/${ipa_dict_revision}/data/en_US.txt" \
  "${temp_dir}/en_US.txt"
fetch \
  "https://raw.githubusercontent.com/open-dict-data/ipa-dict/${ipa_dict_revision}/LICENSE" \
  "${temp_dir}/ipa-dict-MIT.txt"
fetch \
  "https://raw.githubusercontent.com/JoseLlarena/Britfone/${britfone_revision}/britfone.main.3.0.1.csv" \
  "${temp_dir}/britfone.csv"
fetch \
  "https://raw.githubusercontent.com/JoseLlarena/Britfone/${britfone_revision}/LICENSE.txt" \
  "${temp_dir}/britfone-MIT.txt"
fetch \
  "https://creativecommons.org/licenses/by-sa/4.0/legalcode.txt" \
  "${temp_dir}/wiktionary-CC-BY-SA-4.0.txt"
verify_sha256 "$ipa_dict_sha256" "${temp_dir}/en_US.txt"
verify_sha256 "$britfone_sha256" "${temp_dir}/britfone.csv"
verify_sha256 "$wiktionary_sha256" "$wiktionary_tsv"
verify_sha256 "$wiktionary_forms_sha256" "$wiktionary_forms"
verify_sha256 "$cc_by_sa_sha256" "${temp_dir}/wiktionary-CC-BY-SA-4.0.txt"

mkdir -p "$output_dir"
rm -f "$output_db"
sqlite3 "$output_db" <<'SQL'
PRAGMA journal_mode = OFF;
PRAGMA synchronous = OFF;
CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE pronunciations (
  accent TEXT NOT NULL CHECK(accent IN ('us', 'uk')),
  lookup_key TEXT NOT NULL,
  variant INTEGER NOT NULL CHECK(variant >= 0),
  ipa TEXT NOT NULL,
  source TEXT NOT NULL,
  source_revision TEXT NOT NULL,
  PRIMARY KEY (accent, lookup_key, variant)
) WITHOUT ROWID;
SQL
# No secondary index: the primary key already serves (accent, lookup_key) lookups
# and a duplicate index doubled the file size.

# ipa-dict keeps multiple pronunciations in one TSV field; retain each alternative
# as a deterministic variant. Slashes are formatting, not part of the stored IPA.
awk -F '\t' '
  NF >= 2 {
    key = tolower($1)
    count = split($2, values, /, \//)
    for (i = 1; i <= count; i++) {
      value = values[i]
      sub(/^\//, "", value)
      sub(/\/$/, "", value)
      gsub(/^ +| +$/, "", value)
      if (key != "" && value != "") print "us\t" key "\t" (i - 1) "\t" value "\tipa-dict\t43c3570eb3553bdd19fccd2bd0091534889af023"
    }
  }
' "${temp_dir}/en_US.txt" | sqlite3 "$output_db" ".mode tabs" ".import /dev/stdin pronunciations"

# Britfone uses uppercase spellings and a parenthesized number for variants.
awk -F ',' '
  NF >= 2 {
    key = tolower($1)
    variant = 0
    if (match(key, /\([0-9]+\)$/)) {
      suffix = substr(key, RSTART + 1, RLENGTH - 2)
      variant = suffix - 1
      key = substr(key, 1, RSTART - 1)
    }
    value = $2
    sub(/^ +/, "", value)
    gsub(/ +/, "", value)
    if (key != "" && value != "") print "uk\t" key "\t" variant "\t" value "\tbritfone\t1062be14adc96c358f2087ac5449d72130c7a6f4"
  }
' "${temp_dir}/britfone.csv" | sqlite3 "$output_db" ".mode tabs" ".import /dev/stdin pronunciations"

# Wiktionary fills words the two primary sources lack; it never overrides them.
python3 "${root_dir}/scripts/resources/merge-wiktionary-ipa.py" "$output_db" "$wiktionary_tsv" "$wiktionary_revision" "$wiktionary_forms"

sqlite3 "$output_db" <<SQL
INSERT INTO metadata VALUES ('schema_version', '2');
INSERT INTO metadata VALUES ('ipa_dict_revision', '${ipa_dict_revision}');
INSERT INTO metadata VALUES ('britfone_revision', '${britfone_revision}');
INSERT INTO metadata VALUES ('wiktionary_revision', '${wiktionary_revision}');
VACUUM;
SQL
cp "${temp_dir}/ipa-dict-MIT.txt" "${output_dir}/ipa-dict-MIT.txt"
cp "${temp_dir}/britfone-MIT.txt" "${output_dir}/britfone-MIT.txt"
cp "${temp_dir}/wiktionary-CC-BY-SA-4.0.txt" "${output_dir}/wiktionary-CC-BY-SA-4.0.txt"
echo "Built ${output_db}"
