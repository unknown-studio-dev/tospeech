// rubberband-render: offline R3 time-stretch helper for ToSpeech (ToSpeech).
//
// The app never links the Rubber Band Library. It writes the selected span as
// raw PCM, runs this program, and reads the stretched PCM back. Both files are
// 32-bit float, interleaved, native byte order.
//
//   rubberband-render <input.f32> <output.f32> <sampleRate> <channels> <timeRatio> <inputFrames>
//
// Exit status 0 and "frames=<n>" on stdout when the render is complete;
// otherwise a message on stderr, no output file, and a non-zero status.
//
// Copyright (c) 2026 Unknown Studio. Licensed under the GNU General Public
// License, version 2 or later, the same terms as the Rubber Band Library.

#include <rubberband/RubberBandStretcher.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

int fail(const char *message, int status) {
  std::fprintf(stderr, "%s\n", message);
  return status;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc != 7) {
    return fail("usage: rubberband-render <input.f32> <output.f32> <sampleRate> <channels> <timeRatio> <inputFrames>", 2);
  }
  const long rate = std::strtol(argv[3], nullptr, 10);
  const long channels = std::strtol(argv[4], nullptr, 10);
  const double ratio = std::strtod(argv[5], nullptr);
  const long long frames = std::strtoll(argv[6], nullptr, 10);
  if (rate < 8000 || rate > 192000 || channels < 1 || channels > 2 || !std::isfinite(ratio) ||
      ratio <= 1.0 || ratio > 4.0 || frames <= 0 || frames > 120LL * rate) {
    return fail("invalid arguments", 2);
  }
  const size_t ch = static_cast<size_t>(channels);

  std::FILE *in = std::fopen(argv[1], "rb");
  if (!in) return fail("cannot open input", 3);
  std::fseek(in, 0, SEEK_END);
  const long long bytes = std::ftell(in);
  std::rewind(in);
  if (bytes != frames * static_cast<long long>(ch) * static_cast<long long>(sizeof(float))) {
    std::fclose(in);
    return fail("input size mismatch", 3);
  }

  using RubberBand::RubberBandStretcher;
  RubberBandStretcher stretcher(
      static_cast<size_t>(rate), ch,
      RubberBandStretcher::OptionProcessOffline | RubberBandStretcher::OptionEngineFiner |
          RubberBandStretcher::OptionChannelsTogether,
      ratio, 1.0);
  if (stretcher.getEngineVersion() != 3) {
    std::fclose(in);
    return fail("R3 engine unavailable", 3);
  }
  stretcher.setExpectedInputDuration(static_cast<size_t>(frames));
  const size_t block = 1024;
  stretcher.setMaxProcessSize(block);

  std::FILE *out = std::fopen(argv[2], "wb");
  if (!out) {
    std::fclose(in);
    return fail("cannot open output", 3);
  }

  std::vector<float> interleaved(block * ch);
  std::vector<std::vector<float>> planar(ch, std::vector<float>(block));
  std::vector<float *> planarPointers(ch);
  for (size_t c = 0; c < ch; ++c) planarPointers[c] = planar[c].data();
  const size_t outBlock = 8192;
  std::vector<float> outInterleaved(outBlock * ch);
  std::vector<std::vector<float>> outPlanar(ch, std::vector<float>(outBlock));
  std::vector<float *> outPointers(ch);
  for (size_t c = 0; c < ch; ++c) outPointers[c] = outPlanar[c].data();

  long long written = 0;
  const long long expected = std::llround(static_cast<double>(frames) * ratio);
  const char *failure = nullptr;

  auto readBlock = [&](size_t n) {
    if (std::fread(interleaved.data(), sizeof(float), n * ch, in) != n * ch) { failure = "cannot read input"; return false; }
    for (size_t f = 0; f < n; ++f) {
      for (size_t c = 0; c < ch; ++c) {
        const float v = interleaved[f * ch + c];
        if (!std::isfinite(v)) { failure = "non-finite input"; return false; }
        planar[c][f] = v;
      }
    }
    return true;
  };

  auto drain = [&]() {
    int available = 0;
    while ((available = stretcher.available()) > 0) {
      const size_t want = std::min(outBlock, static_cast<size_t>(available));
      const size_t got = stretcher.retrieve(outPointers.data(), want);
      if (got == 0) { failure = "retrieve returned nothing"; return false; }
      if (written + static_cast<long long>(got) > expected + 1) { failure = "over-length output"; return false; }
      for (size_t f = 0; f < got; ++f) {
        for (size_t c = 0; c < ch; ++c) {
          const float v = outPlanar[c][f];
          if (!std::isfinite(v)) { failure = "non-finite output"; return false; }
          outInterleaved[f * ch + c] = v;
        }
      }
      if (std::fwrite(outInterleaved.data(), sizeof(float), got * ch, out) != got * ch) { failure = "cannot write output"; return false; }
      written += static_cast<long long>(got);
    }
    return true;
  };

  bool ok = true;
  for (int pass = 0; pass < 2 && ok; ++pass) {
    std::rewind(in);
    long long read = 0;
    while (read < frames && ok) {
      const size_t n = static_cast<size_t>(std::min<long long>(static_cast<long long>(block), frames - read));
      if (!readBlock(n)) { ok = false; break; }
      read += static_cast<long long>(n);
      const bool last = read == frames;
      if (pass == 0) {
        stretcher.study(planarPointers.data(), n, last);
      } else {
        stretcher.process(planarPointers.data(), n, last);
        if (!drain()) ok = false;
      }
    }
  }
  if (ok) ok = drain();
  if (ok && (stretcher.available() != -1 || std::llabs(written - expected) > 1)) {
    failure = "incomplete render";
    ok = false;
  }
  std::fclose(in);
  if (std::fclose(out) != 0 && ok) { failure = "cannot close output"; ok = false; }
  if (!ok) {
    std::remove(argv[2]);
    return fail(failure ? failure : "render failed", 4);
  }
  std::printf("frames=%lld\n", written);
  return 0;
}
