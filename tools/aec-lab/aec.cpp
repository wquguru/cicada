// aec <rate> <ref.raw> <mic.raw> <out.raw>: WebRTC APM with only AEC3 on, s16 mono, 10 ms frames.
// Reverse (what the Mac played) first, then the mic, as Chrome and PipeWire feed it.
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
#include <array>
#include <string>
#include <algorithm>
#include "modules/audio_processing/include/audio_processing.h"
#include "modules/audio_processing/aec3/echo_canceller3.h"

// APM 2.1 asks for the linear output but never sets it in AEC3's own config (null framer, crash):
// make AEC3 here with it on.
struct Aec3Factory : webrtc::EchoControlFactory {
    webrtc::EchoCanceller3Config cfg;
    std::unique_ptr<webrtc::EchoControl> Create(int rate, int render, int capture) override {
        return std::make_unique<webrtc::EchoCanceller3>(cfg, std::nullopt, rate, render, capture);
    }
};

int main(int argc, char **argv) {
    if (argc != 5) { fprintf(stderr, "usage: aec <rate> <ref.raw> <mic.raw> <out.raw>\n"); return 64; }
    int rate = atoi(argv[1]);
    FILE *ref = fopen(argv[2], "rb"), *mic = fopen(argv[3], "rb"), *out = fopen(argv[4], "wb");
    if (!ref || !mic || !out) { perror("open"); return 1; }
    webrtc::AudioProcessing::Config c;
    c.echo_canceller.enabled = true;
    c.echo_canceller.mobile_mode = false;
    // LINEAR=1: also keep the linear filter's output (no suppressor), 16 kHz, to <out>.lin16.raw.
    const bool linear = getenv("LINEAR") != nullptr;
    c.echo_canceller.export_linear_aec_output = linear;
    std::string linPath = std::string(argv[4]) + ".lin16.raw";
    FILE *lin = linear ? fopen(linPath.c_str(), "wb") : nullptr;
    FILE *hyb = linear ? fopen((std::string(argv[4]) + ".hyb16.raw").c_str(), "wb") : nullptr;
    const double hybDb = getenv("HYB_DB") ? atof(getenv("HYB_DB")) : -50;  // full-output level that means a voice
    const int hybHold = getenv("HYB_HOLD") ? atoi(getenv("HYB_HOLD")) : 30;  // frames (10 ms) kept after it
    int hold = 0;
    const double hybErle = getenv("HYB_ERLE") ? atof(getenv("HYB_ERLE")) : 10;
    c.high_pass_filter.enabled = true;
    // The config at creation: the linear output's buffer is only made then (ApplyConfig later crashed).
    auto factory = std::make_unique<Aec3Factory>();
    factory->cfg.filter.export_linear_aec_output = linear;
    // TUNE=1..3: a gentler suppressor, so a voice over the echo is kept (default: tuned for calls).
    using T = webrtc::EchoCanceller3Config::Suppressor;
    auto &sup = factory->cfg.suppressor;
    int tune = getenv("TUNE") ? atoi(getenv("TUNE")) : 0;
    if (tune >= 1) {  // near end detected sooner and held longer
        sup.dominant_nearend_detection.enr_threshold = .1f;
        sup.dominant_nearend_detection.snr_threshold = 10.f;
        sup.dominant_nearend_detection.trigger_threshold = 4;
        sup.dominant_nearend_detection.hold_duration = 100;
        sup.nearend_tuning.mask_hf = T::MaskingThresholds(.3f, .5f, .3f);
    }
    if (tune >= 2)  // normal (echo-dominated) suppression gentler too
        sup.normal_tuning = T::Tuning(T::MaskingThresholds(.6f, .8f, .3f), T::MaskingThresholds(.2f, .3f, .3f), 2.f, .25f);
    if (tune >= 3)  // normal as gentle as the near-end default
        sup.normal_tuning = T::Tuning(T::MaskingThresholds(1.09f, 1.1f, .3f), T::MaskingThresholds(.1f, .3f, .3f), 2.f, .25f);
    auto apm = webrtc::AudioProcessingBuilder().SetConfig(c).SetEchoControlFactory(std::move(factory)).Create();
    webrtc::StreamConfig sc(rate, 1);
    const size_t n = rate / 100;
    std::vector<int16_t> r(n), m(n);
    double inE = 0, outE = 0;
    long frames = 0;
    while (fread(m.data(), 2, n, mic) == n) {
        if (fread(r.data(), 2, n, ref) != n) std::fill(r.begin(), r.end(), 0);
        double rE = 0;
        for (auto s : r) rE += double(s) * s;
        apm->ProcessReverseStream(r.data(), sc, sc, r.data());
        apm->set_stream_delay_ms(0);
        double mE = 0;
        for (auto s : m) mE += double(s) * s;
        apm->ProcessStream(m.data(), sc, sc, m.data());
        // ERLE over frames where the far end plays, after the first 2 s of convergence.
        if (rE / n > 1e4 && frames > 200) {
            inE += mE;
            for (auto s : m) outE += double(s) * s;
        }
        if (getenv("PER_SEC")) {  // ERLE per second of far-active audio, to see convergence
            static double si = 0, so = 0; static int sec = 0;
            if (rE / n > 1e4) { si += mE; for (auto s : m) so += double(s) * s; }
            if (frames % 100 == 99) { if (si > 0) printf("  %ds: ERLE %.1f dB\n", sec, so > 0 ? 10 * log10(si / so) : 99.0); si = so = 0; sec++; }
        }
        fwrite(m.data(), 2, n, out);
        if (lin) {
            std::array<float, 160> l{};
            if (apm->GetLinearAecOutput(rtc::ArrayView<std::array<float, 160>>(&l, 1))) {
                int16_t o[160];
                for (int i = 0; i < 160; i++) o[i] = (int16_t)std::max(-32768.f, std::min(32767.f, l[i] * 32768.f));  // GetLinearAecOutput is ±1
                fwrite(o, 2, 160, lin);
                // HYBRID (16 kHz only): the suppressed output, except around frames where it still
                // carries a voice (the near end): there the linear output, which keeps it whole.
                if (hyb && rate == 16000) {
                    double fe = 0;
                    for (auto v : m) fe += double(v) * v;
                    double db = 10 * log10(fe / n / (32768.0 * 32768.0) + 1e-12);
                    // Only once AEC3 says it has converged: before that its full output still
                    // carries the echo, which would open the gate onto the uncancelled meeting.
                    auto st = apm->GetStatistics();
                    bool converged = st.echo_return_loss_enhancement && *st.echo_return_loss_enhancement > hybErle;
                    if (db > hybDb && converged) hold = hybHold;
                    else if (hold > 0) hold--;
                    fwrite(hold > 0 ? o : m.data(), 2, 160, hyb);
                }
            }
        }
        frames++;
    }
    auto st = apm->GetStatistics();
    printf("aec: %ld frames, ERLE %.1f dB (far-active, after 2 s), delay %s ms\n", frames,
           outE > 0 ? 10 * log10(inE / outE) : 0.0, st.delay_ms ? std::to_string(*st.delay_ms).c_str() : "-");
    return 0;
}
