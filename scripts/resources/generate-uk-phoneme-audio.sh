#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESTINATION="$ROOT/ToSpeech/Resources/UKPhonemes"
WORK="$(mktemp -d /tmp/tospeech-human-phonemes.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$DESTINATION" "$WORK/ncl" "$WORK/source"

NCL_BASE="https://teaching.ncl.ac.uk/ipa/video"
SALFORD_ARCHIVE="https://ndownloader.figshare.com/files/14639609"
SOURCE_CACHE="${TOSPEECH_PHONEME_SOURCE_CACHE:-}"

# UKSoundLibrary order. Newcastle supplies isolated vowels and VCV consonant
# demonstrations from its female-speaker files; the consonant render keeps only the middle
# articulation. The remaining diphthongs and affricates are single contiguous
# excerpts from one female native British English speaker in Salford's corpus.
ncl_vowels=(
  "01:vowelGK1.mp4" "02:vowelGKbit.mp4" "03:vowelGK3.mp4" "04:vowelGK4.mp4"
  "05:vowelGK5.mp4" "06:vowelGK13.mp4" "07:vowelGK6.mp4" "08:vowelGKhorseshoe.mp4"
  "09:vowelGK8.mp4" "10:vowelGK14.mp4" "11:vowelGKbird.mp4" "12:vowelGKschwa.mp4"
)
ncl_consonants=(
  "21:dc.bilabialGK2.mp4" "22:dc.bilabialGK1.mp4" "23:dc.alveolarGK2.mp4"
  "24:c.p.plosiveGK2b.mp4" "25:dc.velarGK2.mp4" "26:c.p.plosiveGK5b.mp4"
  "27:c.p.fricativeGK2a.mp4" "28:c.p.fricativeGK2b.mp4" "29:c.p.fricativeGK3a.mp4"
  "30:c.p.fricativeGK3b.mp4" "31:c.p.fricativeGK4a.mp4" "32:c.p.fricativeGK4b.mp4"
  "33:c.p.fricativeGK5a.mp4" "34:c.p.fricativeGK5b.mp4" "35:c.p.fricativeGK11a.mp4"
  "38:cp-nasalGK1.mp4" "39:cp-nasalGK2.mp4" "40:cp-nasalGK5.mp4"
  "41:c.p.lat.approximantGK1.mp4" "42:c.p.approximantGK2.mp4"
  "43:c.p.approximantGK4.mp4" "44:othersymbolsGK2.mp4"
)

for entry in "${ncl_vowels[@]}" "${ncl_consonants[@]}"; do
  file="${entry#*:}"
  if [[ -n "$SOURCE_CACHE" && -f "$SOURCE_CACHE/ncl/$file" ]]; then
    cp "$SOURCE_CACHE/ncl/$file" "$WORK/ncl/$file"
  else
    curl -L --fail --silent --show-error --retry 3 -A "ToSpeech noncommercial educational app" \
      -o "$WORK/ncl/$file" "$NCL_BASE/$file"
  fi
done

if [[ -n "$SOURCE_CACHE" && -f "$SOURCE_CACHE/HARVARD_Edited_EP_5s.zip" ]]; then
  cp "$SOURCE_CACHE/HARVARD_Edited_EP_5s.zip" "$WORK/source/HARVARD_Edited_EP_5s.zip"
else
  curl -L --fail --silent --show-error --retry 3 -A "ToSpeech noncommercial educational app" \
    -o "$WORK/source/HARVARD_Edited_EP_5s.zip" "$SALFORD_ARCHIVE"
fi
echo "70d168c3f8bdfea1971cee945fb8e6ddb81ca7d1e71a360c6fd675221b906807  $WORK/source/HARVARD_Edited_EP_5s.zip" | shasum -a 256 -c -
unzip -q "$WORK/source/HARVARD_Edited_EP_5s.zip" -d "$WORK/source"

outer_trim() {
  ffmpeg -hide_banner -loglevel error -y -i "$1" -vn \
    -af "silenceremove=start_periods=1:start_duration=0.02:start_threshold=-48dB,areverse,silenceremove=start_periods=1:start_duration=0.02:start_threshold=-48dB,areverse" \
    -ar 44100 -ac 1 -c:a pcm_s16le "$2"
}

finish_clip() {
  local source="$1" output="$2" start="$3" end="$4" duration
  duration="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.6f", b-a }')"
  ffmpeg -hide_banner -loglevel error -y -i "$source" \
    -af "atrim=start=$start:end=$end,asetpts=PTS-STARTPTS,afade=t=in:st=0:d=0.012,afade=t=out:st=$(awk -v d="$duration" 'BEGIN { printf "%.6f", d-0.012 }'):d=0.012,loudnorm=I=-19:TP=-3:LRA=5,apad=pad_dur=0.035" \
    -ar 44100 -ac 1 -c:a pcm_s16le "$output"
}

for entry in "${ncl_vowels[@]}"; do
  number="${entry%%:*}"; file="${entry#*:}"; trimmed="$WORK/$number.wav"
  outer_trim "$WORK/ncl/$file" "$trimmed"
  length="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$trimmed")"
  start="$(awk -v d="$length" 'BEGIN { printf "%.6f", (d>0.72 ? (d-0.72)/2 : 0) }')"
  end="$(awk -v d="$length" -v s="$start" 'BEGIN { printf "%.6f", (d>0.72 ? s+0.72 : d) }')"
  finish_clip "$trimmed" "$DESTINATION/UKPhoneme_$number.wav" "$start" "$end"
done

for entry in "${ncl_consonants[@]}"; do
  number="${entry%%:*}"; file="${entry#*:}"; trimmed="$WORK/$number.wav"
  outer_trim "$WORK/ncl/$file" "$trimmed"
  length="$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$trimmed")"
  start="$(awk -v d="$length" 'BEGIN { printf "%.6f", d*0.22 }')"
  end="$(awk -v d="$length" -v s="$start" 'BEGIN { e=d*0.62; if (e-s<0.18) e=s+0.18; if (e>d) e=d; printf "%.6f", e }')"
  finish_clip "$trimmed" "$DESTINATION/UKPhoneme_$number.wav" "$start" "$end"
done

CORPUS="$WORK/source/HARVARD_Edited_EP_5s"
# index:list:sentence:absolute start:absolute end:audited source word
salford_clips=(
  "13:16:03:2.690:3.040:day"
  "14:13:03:2.940:3.340:eye"
  "15:02:01:1.170:1.380:boy"
  "16:04:05:2.360:2.550:go"
  "17:38:07:1.360:1.600:now"
  "18:30:02:2.930:3.280:ear"
  "19:06:01:1.630:1.830:air"
  "20:63:03:1.980:2.200:cure"
  "36:17:01:2.900:3.040:chair"
  "37:68:07:2.440:2.580:job"
)
for entry in "${salford_clips[@]}"; do
  IFS=: read -r number list sentence start end word <<< "$entry"
  source="$CORPUS/HARVARD_L$list/Harvard_L${list}_S${sentence}_5.wav"
  finish_clip "$source" "$DESTINATION/UKPhoneme_$number.wav" "$start" "$end"
done

count="$(find "$DESTINATION" -type f -name 'UKPhoneme_*.wav' | wc -l | tr -d ' ')"
[[ "$count" == 44 ]] || { echo "Expected 44 clips; generated $count" >&2; exit 1; }
echo "Generated 44 fixed, human-recorded UK sound clips in $DESTINATION"
