#pragma once
// Carico CPU: un thread per processore logico che esegue FMA in virgola mobile senza sosta,
// in parallelo ai test GPU. Simula lo scenario peggiore per l'alimentatore (CPU e GPU al
// massimo insieme) senza software esterni.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <thread>
#include <vector>

class CpuLoad {
public:
    CpuLoad() = default;
    ~CpuLoad();
    CpuLoad(const CpuLoad&) = delete;
    CpuLoad& operator=(const CpuLoad&) = delete;

    // Avvia 'threads' thread di carico (<= 0: uno per processore logico).
    void start(int threads);
    // Ferma e attende i thread (idempotente).
    void stop();

    int threads() const { return static_cast<int>(threads_.size()); }
    // "AVX2+FMA" se la CPU lo supporta, altrimenti "scalari".
    const char* isaName() const { return avx2_ ? "AVX2+FMA" : "scalari"; }
    // GFLOPS medi tra start() e stop() (o fino ad ora se ancora attivo).
    double gflops() const;
    double seconds() const;

    static int defaultThreads();

private:
    struct alignas(64) Counter {  // un contatore per thread, su linee di cache separate
        std::atomic<uint64_t> iters{0};
    };

    void worker(int index);

    std::vector<std::thread> threads_;
    std::unique_ptr<Counter[]> counters_;
    std::atomic<bool> run_{false};
    bool avx2_ = false;
    std::chrono::steady_clock::time_point t0_, t1_;
};
