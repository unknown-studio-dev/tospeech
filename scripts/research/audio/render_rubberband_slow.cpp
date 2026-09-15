#include <rubberband/RubberBandStretcher.h>
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <vector>

// Development comparison only: mono float32 PCM in/out, exact original sample rate.
int main(int argc, char **argv) {
    if (argc != 5) return 2;
    const int sampleRate = std::stoi(argv[3]);
    const double rate = std::stod(argv[4]);
    if (sampleRate < 8000 || sampleRate > 192000 || !std::isfinite(rate) || rate < .25 || rate > 1) return 2;
    std::ifstream in(argv[1], std::ios::binary | std::ios::ate);
    if (!in || in.tellg() <= 0 || in.tellg() > sampleRate * 30 * 4) return 3;
    const size_t bytes = size_t(in.tellg());
    if (bytes % sizeof(float)) return 3;
    std::vector<float> input(bytes / sizeof(float));
    in.seekg(0); in.read(reinterpret_cast<char *>(input.data()), bytes);
    if (!in || !std::all_of(input.begin(), input.end(), [](float x) { return std::isfinite(x); })) return 3;
    using R = RubberBand::RubberBandStretcher;
    R stretch(sampleRate, 1, R::OptionProcessOffline | R::OptionEngineFiner | R::OptionChannelsTogether, 1.0 / rate, 1.0);
    stretch.setExpectedInputDuration(input.size());
    stretch.setMaxProcessSize(1024);
    for (size_t i = 0; i < input.size(); i += 1024) {
        size_t n = std::min(size_t(1024), input.size() - i);
        const float *p = input.data() + i;
        stretch.study(&p, n, i + n == input.size());
    }
    std::vector<float> result, block(8192);
    auto drain = [&]() {
        while (stretch.available() > 0) {
            float *p = block.data();
            size_t n = stretch.retrieve(&p, std::min(stretch.available(), int(block.size())));
            if (!n) throw std::runtime_error("Rubber Band did not drain");
            result.insert(result.end(), block.begin(), block.begin() + n);
        }
    };
    for (size_t i = 0; i < input.size(); i += 1024) {
        size_t n = std::min(size_t(1024), input.size() - i);
        const float *p = input.data() + i;
        stretch.process(&p, n, i + n == input.size());
        drain();
    }
    drain();
    if (stretch.available() != -1) return 4;
    std::ofstream out(argv[2], std::ios::binary);
    out.write(reinterpret_cast<const char *>(result.data()), result.size() * sizeof(float));
    std::cout << "engine=" << stretch.getEngineVersion() << " frames=" << result.size() << '\n';
    return out ? 0 : 5;
}
