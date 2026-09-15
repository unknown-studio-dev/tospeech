# Rubber Band 4.0.0

Unmodified `src`, `single`, `rubberband` and `COPYING` from the official v4.0.0
tarball: https://github.com/breakfastquay/rubberband/releases/tag/v4.0.0
Archive SHA256: 24300f48a8014b7c863b573a9647e61b1b19b37875e2cdd92005e64c6424d266.

`helper/rubberband-render.cpp` is ToSpeech's own command-line wrapper, licensed
GPLv2-or-later like the library. The `RubberBandRender` tool target in
`project.yml` compiles it together with `single/RubberBandSingle.cpp` (built-in
resampler, Apple Accelerate/vDSP FFT) into a standalone executable that
`scripts/xcode/stage-rubberband.sh` copies to
`ToSpeech.app/Contents/Resources/RubberBand/rubberband-render` next to `COPYING`.

The app never links Rubber Band. `RubberBandRenderer` writes the selected span
as raw interleaved float PCM, runs the helper as a separate sandboxed process
(offline R3 Finer, ChannelsTogether, ratio 1/speed, pitch scale 1) and reads the
stretched PCM back. When the helper is missing, playback falls back to
`AVAudioUnitTimePitch`. Preserve this source tree and `COPYING` when
distributing the helper; the library's commercial licence is available upstream
and is not granted by this vendoring.
