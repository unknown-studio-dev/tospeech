# Changelog

## 0.1.0 — 2026-09-15

First tagged release of ToSpeech for macOS 26 on Apple Silicon.

### What you get
- Import lessons from YouTube or local audio; media tools (yt-dlp, ffmpeg) ship inside the app.
- On-device transcription with Parakeet (downloaded at onboarding) and Apple Speech, plus CoreML word alignment.
- Shadowing practice with take recording, Rubber Band tempo control, DeepFilterNet cleanup, and a live pitch/energy trace in the transport bar.
- Pronunciation assessment: UK Reference (XLSR encoder + UK heads, eSpeak NG IPA, SwiftF0 pitch, Silero VAD) for British English, Phone Scorer for American English, Buddy as an optional engine.
- Progress screen backed by real scoring history.
- Native-language translation of lesson text, three-step onboarding, About panel with update check.

### Distribution
- The app bundle no longer carries model weights (2.0 GB → 507 MB). The UK Reference encoder is a 442 KB ONNX graph that reads the unmodified upstream checkpoint; the app downloads `pytorch_model.bin` from Hugging Face (`facebook/wav2vec2-xlsr-53-espeak-cv-ft`, pinned revision) at onboarding and verifies it by SHA-256 before use.
- Settings → Assessment models now shows the UK Reference card with its install/active state; the "Compact pronunciation engine" placeholder card is gone.
- PhoneticXeus (experimental, Python runtime) is not included in Release builds and is hidden in Settings when absent.
- Release builds are Developer ID signed with the hardened runtime and App Sandbox. `make dmg` produces the notarized drag-to-Applications disk image; `make install` copies the Release build into `/Applications` for local testing.

### Known limitations
- Onboarding with the UK accent downloads about 1.26 GB; the US accent path needs no large download.
- Word alignment (CoreML, 180 MB) and the Phone Scorer (36 MB) still ship inside the bundle.
