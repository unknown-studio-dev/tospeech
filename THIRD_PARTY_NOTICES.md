# Third-party notices

ToSpeech stands on the work listed here. This file credits that work and records
the license each piece is used under. It does not relicense anything: ToSpeech's
own code is under the [PolyForm Noncommercial License 1.0.0](LICENSE), and that
license changes nothing below. Inventory checked against the source tree, the
pinned packages and the staged `vendor/` directory on 2026-09-14.

How each component reaches the user:

- **Linked** — compiled into `ToSpeech.app`.
- **Helper** — a separate executable inside the app bundle, launched as a
  sandboxed child process and talked to through files or pipes only.
- **Bundled** — data shipped inside the app.
- **Downloaded** — fetched on request from Settings or Onboarding into the app's
  Application Support container; never shipped in the binary.
- **Build only** — used by maintainers to prepare artifacts; not shipped.

## At a glance

| Component | Version | How | License |
| --- | --- | --- | --- |
| FluidAudio | 0.15.7 | Linked | Apache-2.0 |
| ONNX Runtime | 1.24.2 | Linked | MIT |
| Parakeet TDT 0.6B v3 (Core ML) | FluidInference conversion | Downloaded | CC BY 4.0 |
| wav2vec2-base-960h (Core ML FP16) | rev `22aad52` | Bundled | Apache-2.0 |
| Buddy English v1 (ONNX INT8) | rev `bbc3711` | Downloaded | Apache-2.0 |
| Phone Scorer E16 (ONNX) | rev `2211f19` | Bundled | **none found** |
| UK Reference: wav2vec2-xlsr-53-espeak-cv-ft (ONNX) | rev `2c73378` | Bundled | Apache-2.0 |
| UK Reference: four EUSTACE heads | trained by ToSpeech | Bundled | **non-commercial** |
| UK Reference: SwiftF0 pitch (ONNX) | 2025 | Bundled | MIT |
| UK Reference: Silero VAD (ONNX) | pinned graph | Bundled | MIT |
| UK Reference: eSpeak-ng + data | — | Helper | GPL-3.0-or-later |
| PhoneticXeus checkpoint | rev `8d83dee` | Downloaded | Apache-2.0 card, **CC BY-NC-SA 4.0** via XEUS |
| xeus-helper (PyInstaller bundle) | built by ToSpeech | Helper | see below |
| yt-dlp macOS onedir | 2026.08.19 | Helper | GPL-3.0-or-later (bundle) |
| FFmpeg / FFprobe | 9.0.1 | Helper | LGPL-2.1-or-later |
| QuickJS | 2026-06-04 | Helper | MIT |
| DeepFilterNet3 `deep-filter` | 0.5.6 | Helper | MIT or Apache-2.0 |
| Rubber Band Library + `rubberband-render` | 4.0.0 | Helper | GPL-2.0-or-later |
| Britfone (UK IPA) | 3.0.1 | Bundled | MIT |
| ipa-dict `en_US` (US IPA) | rev `43c3570` | Bundled | MIT |
| Wiktionary pronunciations via kaikki.org (UK + US IPA) | dump 2026-09-09 | Bundled | CC BY-SA 4.0 |
| Newcastle IPA Online audio | — | Bundled | **CC BY-NC 2.0 UK** |
| Salford Harvard corpus audio | — | Bundled | **CC BY-NC 4.0** |
| Inter, DM Sans, DM Mono | — | Bundled | SIL OFL 1.1 |
| Lucide icons | — | Bundled | ISC (+ Feather MIT) |
| Four Unsplash photos | — | Bundled | Unsplash License |
| Apple frameworks, SQLite | macOS 26 | System | Apple SLA; public domain |

## Runtime libraries linked into the app

Versions come from
[Package.resolved](ToSpeech.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved).

- **ONNX Runtime 1.24.2**, Microsoft —
  [package](https://github.com/microsoft/onnxruntime-swift-package-manager/tree/1.24.2).
  [MIT](ToSpeech/Resources/ThirdParty/ONNXRuntime-MIT.txt) and its
  [third-party notices](ToSpeech/Resources/ThirdParty/ONNXRuntime-ThirdPartyNotices.txt)
  ship in the app. CPU inference only.
- **FluidAudio 0.15.7**, FluidInference —
  [commit 41540ea](https://github.com/FluidInference/FluidAudio/tree/41540ea237350afe5117a082b5c28eda642d0612).
  [Apache-2.0](ToSpeech/Resources/ThirdParty/FluidAudio-LICENSE.txt). It carries
  code and binaries with their own terms, kept in `licenses/`:
  fastcluster ([BSD-2-Clause](licenses/FluidAudio-fastcluster-BSD.txt)),
  VBx-derived diarization code ([Apache-2.0](licenses/FluidAudio-vbx-Apache-2.0.txt);
  ToSpeech does not offer diarization), and the NemoTextProcessing binary 0.3.0 from
  [text-processing-rs](https://github.com/FluidInference/text-processing-rs)
  ([Apache-2.0, component inventory](licenses/FluidAudio-NemoTextProcessing-NOTICE.md)),
  which embeds NVIDIA NeMo grammars (Apache-2.0, commit `1f12635`) and Rust crates
  such as rustfst and flate2 (MIT OR Apache-2.0). Keep that binary's
  [own notices](https://github.com/FluidInference/text-processing-rs/blob/main/THIRD-PARTY-LICENSES.md)
  when redistributing.

## Helper programs

Every helper runs as its own process with the
[sandbox-inherit entitlements](scripts/audio/SandboxedHelper.entitlements) and
exchanges files or pipes with the app. None is linked into `ToSpeech.app`.

**Import tools** — pinned in [Toolchain.lock.json](scripts/toolchain/Toolchain.lock.json),
fetched and verified by [fetch-toolchain.sh](scripts/toolchain/fetch-toolchain.sh).

- **yt-dlp 2026.08.19**, macOS onedir distribution —
  [release](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.08.19). The
  bundled executable is **GPL-3.0-or-later** as upstream
  [explains](https://github.com/yt-dlp/yt-dlp/tree/2026.08.19#licensing); yt-dlp's
  own source is the [Unlicense](licenses/yt-dlp-Unlicense.txt). The archive
  embeds Python and many modules; keep the full
  [upstream license collection](licenses/yt-dlp-THIRD_PARTY_LICENSES.txt).
- **FFmpeg and FFprobe 9.0.1** — built from
  [upstream source](https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz) with the
  flags in the lock file, without `--enable-gpl` or `--enable-nonfree`, so
  [LGPL-2.1-or-later](licenses/FFmpeg-LGPL-2.1.txt) applies
  ([upstream guidance](licenses/FFmpeg-LICENSE.md)).
- **QuickJS 2026-06-04**, Fabrice Bellard and Charlie Gordon —
  [source](https://bellard.org/quickjs/quickjs-2026-06-04.tar.xz),
  [MIT](licenses/QuickJS-MIT.txt). Used by yt-dlp for JavaScript challenges. The
  local build adds `--version`, drops debug info and pins the Mach-O UUID.

**Audio helpers**

- **DeepFilterNet v0.5.6** `deep-filter`, Hendrik Schröter and contributors —
  [commit 978576a](https://github.com/Rikorose/DeepFilterNet/tree/978576aa8400552a4ce9730838c635aa30db5e61),
  unmodified upstream arm64 release embedding DeepFilterNet3 and the tract runtime.
  Upstream offers MIT or Apache-2.0; the [MIT text](ToSpeech/Resources/ThirdParty/DeepFilterNet-MIT.txt)
  ships in the app. ToSpeech only re-signs the binary for its sandbox.
- **Rubber Band Library 4.0.0**, Particular Programs Ltd. — vendored unmodified in
  [ThirdParty/RubberBand](ThirdParty/RubberBand/README.md) and compiled with
  ToSpeech's own [`rubberband-render.cpp`](ThirdParty/RubberBand/helper/rubberband-render.cpp)
  into the `rubberband-render` helper. Both are
  [GPL-2.0-or-later](ToSpeech/Resources/ThirdParty/RubberBand-GPL.txt); `COPYING`
  is staged beside the helper. The library's commercial license exists upstream
  and is not held by this project.
- **eSpeak-ng** binary and `espeak-ng-data`, part of the UK Reference package —
  GPL-3.0-or-later ([text in package](vendor/uk-reference/ESPEAK-LICENSE.txt)).
  Used as a spelling-to-IPA fallback after the dictionary, never for grading.
- **xeus-helper** — a PyInstaller 6.19.0 bundle of the PhoneticXeus runtime
  built by [package.py](scripts/assessment/phoneticxeus/package.py) from the
  environment in [requirements.txt](scripts/assessment/phoneticxeus/requirements.txt).
  It ships CPython 3.11 (PSF), PyTorch and torchaudio 2.10.0 (BSD-3-Clause),
  NumPy 2.4.2 (BSD-3-Clause), safetensors 0.7.0 (Apache-2.0), PyYAML 6.0.3 (MIT),
  huggingface-hub 0.36.2 (Apache-2.0), tqdm 4.70.1 (MIT and MPL-2.0),
  MarkupSafe 3.0.3 (BSD-3-Clause), typeguard 2.13.3 (MIT), certifi (MPL-2.0),
  charset-normalizer (MIT), hf-xet (Apache-2.0), setuptools (MIT), and LLVM
  `libomp`/`libc++` (Apache-2.0 with LLVM exceptions). PyInstaller's bootloader
  exception leaves the produced bundle under the terms of its contents. The
  bundle also carries `uk-contrast-head.json`, described under models.

## Speech and pronunciation models

Model licenses are separate from the libraries that run them.

- **Parakeet TDT 0.6B v3** — [NVIDIA original](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3),
  [FluidInference Core ML conversion](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
  with the INT8 encoder. [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/);
  attribution ships in [Parakeet-NOTICE.txt](ToSpeech/Resources/ThirdParty/Parakeet-NOTICE.txt).
  Downloaded on request; weights unmodified.
- **wav2vec2-base-960h** (word alignment) — Meta,
  [revision 22aad52](https://huggingface.co/facebook/wav2vec2-base-960h/tree/22aad52d435eb6dbaf354bdad9b0da84ce7d6156),
  authors Baevski, Zhou, Mohamed and Auli. Converted by ToSpeech to FP16 Core ML
  ([conversion script](scripts/alignment/convert_wav2vec2.py), a precision change,
  not new training). [Apache-2.0](scripts/alignment/LICENSE); license, vocabulary
  and `provenance.json` are staged together by
  [stage-alignment.sh](scripts/xcode/stage-alignment.sh).
- **Buddy English v1** — [asingingbird ONNX conversion](https://huggingface.co/asingingbird/buddy-pronunciation-onnx/tree/bbc37113ff91fdda6b2b1a79f44fbb78bdc4c588)
  of [nrshoudi/speech_ocean_wav2vec_mdd](https://huggingface.co/nrshoudi/speech_ocean_wav2vec_mdd),
  itself fine-tuned from `facebook/wav2vec2-xlsr-53-espeak-cv-ft` on speechocean762.
  [Apache-2.0](licenses/Buddy-LICENSE.txt) with the
  [conversion NOTICE](licenses/Buddy-NOTICE.txt); both are installed beside the
  weights. English INT8 phoneme recognition only; no retraining by ToSpeech.
- **Phone Scorer E16** — [aviadarn/Accentedness-Scoring-Challenge](https://github.com/aviadarn/Accentedness-Scoring-Challenge)
  at `2211f19be4abc6cdfb7908eb9bbb34f9dcccb550`, checkpoint
  `ead3144c…e80338`, converted to two ONNX graphs by
  [export_phone.py](scripts/assessment/export_phone.py). The scorer wraps an
  OpenAI Whisper-tiny encoder (MIT) with the author's ordinal head. **Neither the
  repository nor the Hugging Face model declares a license**, so no redistribution
  right exists. The maintainer chose to keep it for private evaluation;
  see [PHONE-NOTICE.txt](scripts/assessment/PHONE-NOTICE.txt).
- **UK Reference** — one package, five parts, staged by
  [stage-uk-reference.sh](scripts/xcode/stage-uk-reference.sh) with a pinned manifest:
  - `encoder.onnx` + `pytorch_model.bin`: [facebook/wav2vec2-xlsr-53-espeak-cv-ft](https://huggingface.co/facebook/wav2vec2-xlsr-53-espeak-cv-ft)
    (revision `2c733782da5604684829819a5eb744c193fe9398`). The graph is exported by
    [export_uk_reference.py](scripts/assessment/export_uk_reference.py) and rewritten by
    [externalize_uk_encoder.py](scripts/assessment/externalize_uk_encoder.py) to read its
    weights from the unmodified upstream checkpoint, which the app downloads from Hugging Face
    at onboarding and verifies by hash.
    [Apache-2.0](vendor/uk-reference/XLSR-APACHE-2.0.txt).
  - `uk-vowels.json`, `uk-stress.json`, `uk-focus.json`, `uk-boundary.json`:
    small heads trained by ToSpeech ([train_uk_heads.py](scripts/assessment/train_uk_heads.py))
    on the [EUSTACE speech corpus](http://www.cstr.ed.ac.uk/projects/eustace),
    White and King 2003, CSTR, University of Edinburgh. The corpus licence
    ([copy](vendor/uk-reference/EUSTACE-LICENSE.html)) allows **non-commercial use
    only**; the heads inherit that limit.
  - `pitch.onnx`: [SwiftF0](https://github.com/lars76/swift-f0) by Lars Nieradzik,
    [MIT](vendor/uk-reference/SWIFTF0-LICENSE.txt).
  - `vad.onnx`: [Silero VAD](https://github.com/snakers4/silero-vad), 16 kHz graph,
    [MIT](vendor/uk-reference/SILERO-LICENSE.txt).
  - `espeak-ng` and `espeak-ng-data`: see helpers above.
- **PhoneticXeus** — [changelinglab/PhoneticXeus](https://huggingface.co/changelinglab/PhoneticXeus)
  at `8d83dee94817a07dc150f87d08f7e0ee01bdb66d`; cite
  "An Empirical Recipe for Universal Phone Recognition" (arXiv 2603.29042).
  The model card says Apache-2.0, but it is a fine-tune of
  [espnet/xeus](https://huggingface.co/espnet/xeus), which is
  **CC BY-NC-SA 4.0**. ToSpeech treats the checkpoint, and everything derived
  from it, as CC BY-NC-SA 4.0. The checkpoint is downloaded on request and never
  modified. `uk-contrast-head.json`, a logistic head that ToSpeech trained on XEUS
  features from macOS `say` voices
  ([train_uk_contrast_head.py](scripts/assessment/phoneticxeus/train_uk_contrast_head.py)),
  is a derivative and carries the same terms.

## Dictionaries and reference audio

- **ipa-dict `en_US`** — [open-dict-data/ipa-dict, revision 43c3570](https://github.com/open-dict-data/ipa-dict/tree/43c3570eb3553bdd19fccd2bd0091534889af023),
  [MIT, dohliam](ToSpeech/Resources/IPA/ipa-dict-MIT.txt); upstream credits
  [cmudict-ipa](https://github.com/lingz/cmudict-ipa) and
  [syllabify](https://github.com/kylebgorman/syllabify). The ipa-dict UK file has
  different terms and is not used.
- **Britfone 3.0.1** — [Jose Llarena, revision 1062be1](https://github.com/JoseLlarena/Britfone/tree/1062be14adc96c358f2087ac5449d72130c7a6f4),
  [MIT](ToSpeech/Resources/IPA/britfone-MIT.txt).
  Both dictionaries are normalized into one SQLite file by
  [build-ipa-dictionary.sh](scripts/resources/build-ipa-dictionary.sh), source
  revisions retained.
- **Wiktionary pronunciations** — word/IPA rows extracted from the English
  [Wiktionary](https://en.wiktionary.org/) through the
  [kaikki.org](https://kaikki.org/dictionary/English/) wiktextract dump of
  2026-09-09 (Tatu Ylonen, *Wiktextract: Wiktionary as Machine-Readable
  Structured Data*, LREC 2022). Wiktionary text is
  [CC BY-SA 4.0](ToSpeech/Resources/IPA/wiktionary-CC-BY-SA-4.0.txt); the
  extracted table [wiktionary-ipa.tsv](scripts/resources/wiktionary-ipa.tsv) and
  the `wiktionary*` rows of `ipa.sqlite` are derivatives under the same licence.
  The layer only fills words Britfone or ipa-dict lack. Rows labelled UK/RP or
  US/GA on Wiktionary are stored as `wiktionary`; unlabelled transcriptions are
  assigned by phonetic markers and stored as `wiktionary-untagged`. Two further
  UK layers are derived from Wiktionary's form tables
  ([wiktionary-forms.tsv](scripts/resources/wiktionary-forms.tsv)):
  `wiktionary-altspelling` copies a pronunciation to a British spelling of the
  same word, and `wiktionary-inflected` builds regular plurals and verb forms by
  suffix phonology ([merge-wiktionary-ipa.py](scripts/resources/merge-wiktionary-ipa.py)).
- **44 RP sound recordings** — adapted from
  [Newcastle University IPA Online](https://teaching.ncl.ac.uk/ipa/) (Ghada Khattab
  and Gerry Docherty; **CC BY-NC 2.0 UK**) and the
  [University of Salford Harvard corpus](https://salford.figshare.com/articles/dataset/Speech_corpus_-_Harvard_-_edited_end-pointed_zero-padded_audio/7862186)
  (Philippa Demonte; **CC BY-NC 4.0**). Edits and attribution are recorded in
  [UKPhonemes-NOTICE.txt](ToSpeech/Resources/ThirdParty/UKPhonemes-NOTICE.txt).
  Non-commercial distribution only.

## Fonts, icons and images

- [Inter](https://github.com/rsms/inter), [DM Sans](https://github.com/googlefonts/dm-fonts)
  and [DM Mono](https://github.com/googlefonts/dm-mono): SIL OFL 1.1
  ([Inter](ToSpeech/Resources/Fonts/Inter-OFL.txt),
  [DM Sans](ToSpeech/Resources/Fonts/DMSans-OFL.txt),
  [DM Mono](ToSpeech/Resources/Fonts/DMMono-OFL.txt)).
- [Lucide](https://lucide.dev/license) icons: ISC, with the retained MIT text for
  Feather-derived glyphs by Cole Bemis ([bundled](ToSpeech/Resources/Lucide-LICENSE)).
- Four demo photographs under the [Unsplash License](https://unsplash.com/license):
  `microphone.jpg` (`1671062878421-70c4877933ed`),
  `conversation.jpg` (`1758525226597-6263703aca5f`),
  `rhythm.jpg` (`1647866427464-3762122c752b`),
  `story.jpg` (`1725582201587-e88d3e1cf15d`). Photographer names were not
  recorded in the original handoff; none are invented here.
- The toucan brand artwork is ToSpeech's own asset.

## Apple platform components

SwiftUI, AppKit, AVFoundation, Core ML, Accelerate, Speech, Translation, WebKit
and the other macOS frameworks are supplied by Apple under the
[Apple software license terms](https://www.apple.com/legal/sla/). On-device speech
assets and UK/US voices belong to the operating system; ToSpeech does not
distribute them. SQLite is [public domain](https://www.sqlite.org/copyright.html)
and used from the system library. SF Symbols and system fonts are Apple assets,
not covered by the font licenses above.

## Build-only tools

Used by maintainers to prepare artifacts; nothing here is shipped.

- Word alignment ([prepare.sh](scripts/alignment/prepare.sh)): PyTorch 2.5.0
  (BSD-style), Transformers 4.46.3 (Apache-2.0), coremltools 8.3.0
  (BSD-3-Clause), NumPy 1.26.4 (BSD-3-Clause), managed with uv.
- Phone Scorer and UK Reference exports
  ([conversion-requirements.txt](scripts/assessment/conversion-requirements.txt)):
  PyTorch 2.12.1, Transformers 5.14.1, onnx 1.20.1, onnxruntime 1.24.2 and their
  dependencies under BSD, MIT and Apache-2.0 terms.
- PhoneticXeus packaging: PyInstaller 6.19.0 (GPL-2.0 with bootloader exception).
- XcodeGen for `project.yml`; Xcode 26 for everything else.

## What shipping a build requires

1. **GPL helpers** (yt-dlp bundle, `rubberband-render`, eSpeak-ng): keep them
   separate processes, ship their `COPYING`/notice files, and provide the
   corresponding source for the exact versions shipped. The Rubber Band and
   helper sources are in this repository; yt-dlp and eSpeak-ng sources are the
   pinned upstream releases.
2. **LGPL FFmpeg**: provide the source and build flags for the exact 9.0.1 build
   (both recorded in `Toolchain.lock.json`). Running it as a separate executable
   satisfies the relinking requirement.
3. **CC BY 4.0 Parakeet**: keep the bundled attribution notice.
   **CC BY-SA 4.0 Wiktionary**: credit Wiktionary with a link, and keep the
   pronunciation data (the TSV and the `wiktionary*` rows of `ipa.sqlite`) under
   CC BY-SA 4.0 when redistributing; the app's own code is unaffected.
4. **Non-commercial only**: the EUSTACE heads, the Newcastle and Salford audio,
   the XEUS-derived checkpoint and the RP contrast head may not be distributed for
   commercial purposes. This matches the PolyForm Noncommercial terms of the app
   and rules out any commercial redistribution of the whole.
5. **Phone Scorer E16**: no license, so no redistribution right. A public build
   must drop `vendor/phone-scorer` and its Settings card, or obtain permission
   from the author.
6. Keep every file under `licenses/` and `ToSpeech/Resources/ThirdParty/` with
   binary and source releases, and keep model notices next to downloaded weights.

Re-check this file whenever a package pin, model source, helper or asset changes.
It documents intent and provenance; it is not a certification of a release.
