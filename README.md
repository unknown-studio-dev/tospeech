<p align="center">
  <img src="ToSpeech/Resources/Brand.xcassets/ToSpeechToucan.imageset/tospeech-toucan-headphones-transparent-v3.png" width="180" alt="ToSpeech">
</p>

<h1 align="center">ToSpeech</h1>

<p align="center">English shadowing practice with on-device ASR, forced alignment and phoneme-level feedback.</p>

<p align="center"><b>English</b> · <a href="README.vi.md">Tiếng Việt</a></p>

<p align="center"><sub>Source tree, app target and bundle id still use the codename <code>ToSpeech</code>.</sub></p>

---

Paste a YouTube link. ToSpeech downloads the audio, transcribes it, splits it into
sentences, aligns every word, looks up IPA and translates to Vietnamese. You listen,
shadow and record. The app compares what you said with the source, phoneme by phoneme,
and lays your pitch and rhythm next to the speaker's. No server, no API key, no audio
leaves the machine. macOS 26+, Apple Silicon.

## Architecture overview

```mermaid
flowchart LR
    subgraph APP["TOSPEECH · ONE NATIVE APP TARGET"]
        direction LR
        subgraph EXPERIENCE["EXPERIENCE"]
            direction TB
            F["Features<br/>Library · Shadowing · Review<br/>Dictation · Progress · Settings"]
            DS["Design system<br/>Shared controls · theme · gallery"]
            F --> DS
        end
        subgraph CORE["APPLICATION CORE"]
            direction TB
            S["Production services<br/>Import · Prepare · Align · Practice<br/>Match · Assess · Persist"]
            D["Domain<br/>Value models · pure rules"]
            S --> D
        end
        F --> S
        F --> D
    end
    subgraph LOCAL["LOCAL RUNTIMES · NOTHING LEAVES THE MAC"]
        direction TB
        subgraph MODELS[" "]
            direction LR
            CML["Core ML<br/>Parakeet · wav2vec2"]
            ORT["ONNX Runtime<br/>Buddy · Phone Scorer · UK Reference"]
        end
        subgraph SYSTEM[" "]
            direction LR
            AF["Apple frameworks<br/>Speech · Translation · Audio · WebKit"]
            SP["Sandboxed tools<br/>yt-dlp · FFmpeg · QuickJS<br/>deep-filter · rubberband-render · xeus-helper"]
        end
        DB[("SQLite + media<br/>App Sandbox container")]
    end
    S --> CML & ORT & AF & SP & DB

    classDef primary fill:#C2B6E8,stroke:#7567A7,color:#171A2B,stroke-width:2px;
    classDef surface fill:#F7F5FC,stroke:#B8AECE,color:#20253A,stroke-width:1.5px;
    classDef runtime fill:#E8EEF8,stroke:#8291AE,color:#192238,stroke-width:1.5px;
    classDef storage fill:#E8EFD9,stroke:#8A9D68,color:#202A18,stroke-width:1.5px;
    class F,S primary;
    class DS,D surface;
    class CML,ORT,AF,SP runtime;
    class DB storage;
    style APP fill:#F2F0F8,stroke:#9387B5,stroke-width:2px;
    style EXPERIENCE fill:#FCFBFE,stroke:#D7D1E5;
    style CORE fill:#FCFBFE,stroke:#D7D1E5;
    style LOCAL fill:#F7F9FC,stroke:#AAB4C6,stroke-width:2px;
    style MODELS fill:transparent,stroke:transparent;
    style SYSTEM fill:transparent,stroke:transparent;
```

One app target. `Domain` imports Foundation only. `Features` compose `DesignSystem`
controls and call `Services`; they never see SQL, file paths or SDK types. Every
model engine lives in its own actor, is pinned by checksum, and releases memory when
idle.

## Pipeline

```mermaid
flowchart LR
    subgraph INGEST["1 · INGEST & ALIGN"]
        direction TB
        A["YouTube URL<br/>or local audio"] --> B["Acquire<br/>yt-dlp · FFmpeg · QuickJS"]
        B --> C["Audio + thumbnail"]
        C --> D["Primary ASR<br/>Parakeet TDT 0.6B v3"]
        C --> E["Cross-check<br/>Apple Speech + captions"]
        D & E --> R["Reconcile<br/>> 0.35 s → review flag"]
        R --> G["Split sentences<br/>Punctuation + pauses"]
        G --> H["Align words<br/>wav2vec2 · Core ML"]
        H --> I[("Immutable<br/>SQLite revisions")]
    end

    subgraph PRACTICE["2 · ENRICH & PRACTICE"]
        direction TB
        J["Enrich lesson<br/>IPA UK/US · VI translation<br/>Apple reference voice"]
        K["Shadowing<br/>Listen or Record now<br/>→ countdown → capture → trim"]
        L["Listening copy<br/>DeepFilterNet3 · Rubber Band R3"]
        J --> K --> L
    end

    subgraph FEEDBACK["3 · ANALYZE & REVIEW"]
        direction TB
        subgraph SIGNALS[" "]
            direction LR
            W["Words<br/>ASR normalized diff"]
            P["Phonemes<br/>4 local engines"]
            V["Delivery<br/>Pitch · rhythm · pauses"]
        end
        X["Review drawer<br/>Sentence → priority fixes → detail"]
        W & P & V --> X
    end

    I --> J
    K --> W & P & V

    classDef source fill:#E8EEF8,stroke:#8291AE,color:#192238,stroke-width:1.5px;
    classDef process fill:#F7F5FC,stroke:#B8AECE,color:#20253A,stroke-width:1.5px;
    classDef primary fill:#C2B6E8,stroke:#7567A7,color:#171A2B,stroke-width:2px;
    classDef storage fill:#E8EFD9,stroke:#8A9D68,color:#202A18,stroke-width:1.5px;
    classDef output fill:#DDE6F3,stroke:#6E819F,color:#172237,stroke-width:2px;
    class A,C source;
    class B,D,E,R,G,H,J,L,W,P,V process;
    class K primary;
    class I storage;
    class X output;
    style INGEST fill:#F7F9FC,stroke:#AAB4C6,stroke-width:2px;
    style PRACTICE fill:#F2F0F8,stroke:#9387B5,stroke-width:2px;
    style FEEDBACK fill:#F7F9FC,stroke:#AAB4C6,stroke-width:2px;
    style SIGNALS fill:transparent,stroke:transparent;
```

## How each step works

**1. Getting the audio.** yt-dlp's onedir build, statically built FFmpeg and FFprobe,
and QuickJS for yt-dlp's JavaScript challenges run as subprocesses inside the App
Sandbox. Checksums are pinned in a lock file and verified at build time. Every import
job checkpoints into SQLite: quit mid-way and it resumes on relaunch; cancel and the
child processes die with it. Only audio and a thumbnail are kept.

**2. Transcription.** Parakeet TDT 0.6B v3 through FluidAudio (Core ML, INT8 encoder,
SentencePiece token timings merged at real word boundaries). YouTube caption timing is not trusted: rolling
auto-caption VTT was measured and found wrong. Apple SpeechAnalyzer (macOS 26,
on-device) and captions are used only as cross-checks: interior words may be corrected
within a narrow time window, and a disagreement above 0.35 s raises a review flag
instead of inventing a timestamp. All three sources are stored with the lesson for
auditing.

**3. Sentence segmentation.** Punctuation and pauses, with short fragments merged. A
sentence is never cut just for being long: a slow 20-second sentence without
punctuation stays one sentence.

**4. Per-word timing.** wav2vec2-base-960h converted to FP16 Core ML. Viterbi CTC with
explicit blank and repeated-character states; word boundaries are taken at space
emissions so final consonants are not clipped. Sequential windows under 30 s at 16 kHz
with overlapping context at the edges. Words with weak acoustic support, too far from
the ASR anchor, or with unknown written forms keep their ASR timing and are marked for
review. Every timing edit creates a new revision; nothing is overwritten.

**5. IPA, translation, reference voice.** An offline SQLite dictionary built from
Britfone 3.0.1 (British) and ipa-dict (American); a missing UK entry falls back to US
with a visible marker. Sentences are translated with the offline Apple Translation
framework. Reference voices are AVSpeechSynthesizer in the matching UK or US accent,
labelled as synthetic. Linking suggestions are derived from transcriptions, not
detected in the signal.

**6. Recording and playback.** An AVAudioEngine tap writes CAF; source audio stops
completely before the microphone opens. Takes are edge-trimmed by energy, internal
pauses intact, with a manifest so an interrupted save can be recovered. For listening,
DeepFilterNet3 v0.5.6 (Rust helper, tract runtime) denoises a disposable copy followed
by constant gain; the original used for scoring is untouched. Slow playback is Rubber Band 4.0.0's R3 engine, running as a separate
`rubberband-render` helper process that only exchanges raw PCM files with the app;
without the helper, playback falls back to AVAudioUnitTimePitch.

**7. Feedback.** Four layers, each labelled for what it is:

- *Words*: the same ASR engine runs on the take and normalized word sequences are
  compared. Text evidence, not a pronunciation score.
- *Phonemes*: four local engines, selected by the job's provenance and never swapped
  silently.
  - **Buddy English v1**: wav2vec2 mispronunciation detection (speechocean762), INT8
    ONNX; recognizes phonemes and compares them with each word's IPA inventory. 30 s
    per audio.
  - **Phone Scorer E16**: Whisper encoder plus an ordinal scorer in ONNX
    (Accentedness-Scoring-Challenge), US English only.
  - **UK Reference**: a frozen wav2vec2-xlsr-53-espeak-cv-ft encoder (ONNX) with four
    heads trained on the EUSTACE corpus (9 vowel categories, stress, focus, boundary),
    SwiftF0 pitch, Silero VAD and eSpeak-ng en-gb as dictionary-first G2P. It keeps the
    British vowel contrasts that Buddy collapses.
  - **PhoneticXeus** (experimental): the XEUS multilingual phoneme recognizer running
    in its own helper process (PyInstaller, JSON lines, about 4.6 GB when warm). Full
    CTC posteriors are stored, mapped through a versioned UK inventory, with a tiny RP
    contrast head (logistic regression on a mid layer, trained on macOS `say` UK vs US
    voices) for the BATH/LOT pairs the CTC head merges, and compared against the
    teacher's audio for the same sentence.
- *Delivery*: pitch, intensity, duration and pauses of the take beside the speaker's.
- *Sound coaching*: a 44-sound RP library with reference audio (Newcastle IPA Online,
  Salford).

Everything is labelled evidence, not a calibrated grade. Sounds a model does not cover
stay neutral, and uncertain sounds are never painted red.

**8. Dictation.** Listen to the whole sentence before typing, optional time limit,
normalized word comparison, history kept per revision.

## Models and technology

| Task | Model / library | Runtime |
| --- | --- | --- |
| Download | yt-dlp 2026.08.19, FFmpeg 9.0.1, QuickJS | sandboxed subprocesses |
| ASR | Parakeet TDT 0.6B v3 (FluidAudio 0.15.7) | Core ML |
| Cross-check ASR | Apple SpeechAnalyzer / SpeechTranscriber | macOS 26 on-device |
| Word alignment | facebook/wav2vec2-base-960h, FP16 | Core ML |
| IPA | Britfone 3.0.1, ipa-dict en_US | offline SQLite |
| Translation, voice | Apple Translation, AVSpeechSynthesizer | Apple frameworks |
| Denoise | DeepFilterNet3 v0.5.6 | Rust helper |
| Slow playback | Rubber Band 4.0.0 R3 | separate GPL helper process (`rubberband-render`) |
| Phonemes | Buddy English v1; Phone Scorer E16; XLSR-53 eSpeak + EUSTACE heads, SwiftF0, Silero VAD, eSpeak-ng | ONNX Runtime 1.24.2 |
| Phonemes (experimental) | changelinglab/PhoneticXeus + RP contrast head | helper process |
| App | SwiftUI, Swift 6 strict concurrency, AVAudioEngine, WebKit, SQLite | macOS 26, arm64 |

Every model is pinned by revision and checksum and verified before use, whether
downloaded in-app or staged at build time.

## Try it

```sh
scripts/toolchain/fetch-toolchain.sh      # yt-dlp, FFmpeg, QuickJS
bash scripts/alignment/prepare.sh          # wav2vec2 -> Core ML (needs uv)
bash scripts/audio/fetch-deepfilternet.sh  # DeepFilterNet3
make build && make run
```

Xcode 26+, Apple Silicon Mac. Phone Scorer, UK Reference and PhoneticXeus have their own
preparation scripts under `scripts/assessment/`. ASR and Buddy models are downloaded
in-app from Settings → Recording & models. `make test` runs the tests and
`make gen` regenerates the project from `project.yml`.

## Status and license

Work in progress. Automatic transcripts and timing can be wrong on connected speech,
names and hard audio; the offline IPA dictionary does not cover every word. Phoneme
feedback is experimental evidence; there is no calibrated overall, stress or intonation
score.

Built for education, self-study and research. ToSpeech's own source is licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE): free to use, study, modify and share
for non-commercial purposes; commercial use is not permitted. Dependencies, models
and the bundled yt-dlp distribution (GPLv3+) keep their own licenses, see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Lesson content belongs to its owners;
import only what you have the right to use. ToSpeech is not affiliated with YouTube,
Apple, NVIDIA, Meta or the authors of its dependencies.
