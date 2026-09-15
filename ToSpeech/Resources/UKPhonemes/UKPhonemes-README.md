# UK sound clips (`UKPhoneme_01.wav` … `UKPhoneme_44.wav`)

Order follows `UKSoundLibrary.all` in `ToSpeech/Domain/Rules/UKSoundLibrary.swift`
(01–12 vowels, 13–20 diphthongs, 21–44 consonants). Every tap plays exactly one
bundled WAV; runtime playback does not synthesize or concatenate IPA symbols.

## Current contents: PLACEHOLDER, local test only (2026-09-14)

The 44 files now in this folder are voice-converted test clips built from the
male recordings in `ToSpeech/Resources/PhonemeAudio/uk/` (see
`UKPhonemes-placeholder-provenance.json` for the per-file source):

- consonants 21–44: Praat "Change gender" (formant ×1.18, F0 median 205 Hz)
- vowels and diphthongs: ElevenLabs speech-to-speech (Lily, `eleven_english_sts_v2`)
  with tail trim and adaptive high-shelf EQ
- ɪ (02) and ʊ (08): ElevenLabs `eleven_multilingual_sts_v2`

The source recordings are not licensed for distribution. **Do not commit or ship
this folder as it is.** Replace with the hired recording before any build leaves
this machine. `UKPhonemes-NOTICE.txt` still describes the previous
Newcastle/Salford pack and does not apply to these files.

## How to replace the clips (quick path)

1. Put the new recordings in one folder, one file per sound, named by symbol
   (`iː.wav`, `p.wav`, …, Cambridge spelling `g` and `r` are accepted for `ɡ`/`ɹ`).
   Any format ffmpeg reads is fine.
2. Normalise and number them in one go:

   ```bash
   cd native
   python3 - <<'EOF'
   import re, subprocess, pathlib
   src = pathlib.Path("ToSpeech/Resources/PhonemeAudio/uk")            # folder with <symbol>.wav|mp3
   dest = pathlib.Path("ToSpeech/Resources/UKPhonemes")
   alias = {"ɡ": "g", "ɹ": "r"}
   symbols = re.findall(r'symbol:\s*"([^"]+)",\s*group:', open("ToSpeech/Domain/Rules/UKSoundLibrary.swift", encoding="utf-8").read())
   af = ("silenceremove=start_periods=1:start_duration=0.02:start_threshold=-48dB,areverse,"
         "silenceremove=start_periods=1:start_duration=0.02:start_threshold=-48dB,areverse,"
         "afade=t=in:d=0.012,loudnorm=I=-19:TP=-3:LRA=5,apad=pad_dur=0.035")
   for i, s in enumerate(symbols, 1):
       f = next(p for p in src.iterdir() if p.stem in (s, alias.get(s, s)))
       subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(f), "-af", af, "-ar", "44100", "-ac", "1",
                       "-c:a", "pcm_s16le", str(dest / f"UKPhoneme_{i:02d}.wav")], check=True)
       print(f"UKPhoneme_{i:02d}.wav <- {f.name}")
   EOF
   ```

   Output: mono 44.1 kHz 16-bit, silence trimmed at −48 dB, 12 ms fade-in,
   −19 LUFS, 35 ms tail. No code change is needed; Xcode picks the files up on
   the next build.
3. Update `UKPhonemes-NOTICE.txt` and `THIRD_PARTY_NOTICES.md` with the new
   recording's licence, and delete `UKPhonemes-placeholder-provenance.json`.

## How to restore the previous Newcastle/Salford pack

The folder is not tracked by git, so restore it with the generator:

```bash
scripts/resources/generate-uk-phoneme-audio.sh
```

A regenerated copy is also kept at `docs/sts-test/original-newcastle/` (local
only); copying those 44 files back here is equivalent.

## Tuning notes from the 2026-09-14 comparison

Measured on the 54-sound Cambridge set (`docs/sts-test/`, local only):
ElevenLabs STS loses high-frequency energy on voiceless fricatives (f 10 % → 2 %)
and barely converts /r/; Praat keeps fricatives intact and converts /r/ but leaves
creaky short vowels creaky. Hence the split above. Scripts used:
`scripts/resources/elevenlabs-phonemes.py` (IPA-to-audio candidates) and the
comparison scripts in the session scratchpad.
