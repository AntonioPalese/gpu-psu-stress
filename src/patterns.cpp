#include "patterns.hpp"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <thread>

#include "check.hpp"

std::atomic<bool> g_stopRequested{false};

namespace {

using Clock = std::chrono::steady_clock;

Clock::time_point after(Clock::time_point t, double sec) {
    return t + std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(sec));
}

// Sleep a piccoli passi, per reagire subito a Ctrl+C.
void sleepUntil(Clock::time_point end) {
    while (!g_stopRequested) {
        auto now = Clock::now();
        if (now >= end) break;
        std::this_thread::sleep_for(std::min<Clock::duration>(end - now, std::chrono::milliseconds(50)));
    }
}

// Un giro di carico: lancia tutto, poi aspetta tutti gli stream (niente code di lanci).
void runOnce(const std::vector<StreamLoad>& loads) {
    for (const StreamLoad& l : loads) l.launch(l.stream);
    for (const StreamLoad& l : loads) CK(cudaStreamSynchronize(l.stream));
}

void runUntil(const std::vector<StreamLoad>& loads, Clock::time_point end) {
    while (!g_stopRequested && Clock::now() < end) runOnce(loads);
}

}  // namespace

std::string squareWaveName(double hz) {
    char buf[64];
    std::snprintf(buf, sizeof(buf), "Onda quadra %g Hz", hz);
    return buf;
}

void idle(Monitor& mon, const std::string& name, double sec) {
    mon.setPhase(name);
    sleepUntil(after(Clock::now(), sec));
}

void sustained(Monitor& mon, const std::string& name, const std::vector<StreamLoad>& loads,
               double sec) {
    mon.setPhase(name);
    runUntil(loads, after(Clock::now(), sec));
}

void squareWave(Monitor& mon, double hz, const Launch& shortLoad, cudaStream_t stream,
                double sec) {
    mon.setPhase(squareWaveName(hz));
    const double period = 1.0 / hz;
    const auto start = Clock::now();
    const auto end = after(start, sec);

    // Scadenze calcolate dall'inizio della fase: nessuna deriva tra un periodo e l'altro.
    for (long k = 0; !g_stopRequested; ++k) {
        const auto t0 = after(start, k * period);
        if (t0 >= end) break;
        const auto onEnd = std::min(after(start, (k + 0.5) * period), end);
        const auto offEnd = std::min(after(start, (k + 1) * period), end);

        // Metà periodo a pieno carico: lanci brevi sincronizzati, così il fronte di discesa
        // arriva al massimo ~0.5 ms dopo la scadenza.
        while (!g_stopRequested && Clock::now() < onEnd) {
            shortLoad(stream);
            CK(cudaStreamSynchronize(stream));
        }
        // Spin-wait: sleep avrebbe una granularità troppo grossa (~15 ms su Windows).
        while (!g_stopRequested && Clock::now() < offEnd) {
        }
    }
}

void burstFromIdle(Monitor& mon, int cycles, double idleSec, double burstSec,
                   const std::vector<StreamLoad>& loads) {
    for (int c = 0; c < cycles && !g_stopRequested; ++c) {
        idle(mon, "_idle burst", idleSec);
        if (g_stopRequested) break;
        sustained(mon, "Burst da idle", loads, burstSec);
    }
}
