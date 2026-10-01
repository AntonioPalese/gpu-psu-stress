#pragma once
// CPU load: one thread per logical processor running floating-point FMA non-stop,
// in parallel with the GPU tests. Simulates the worst case for the power supply (CPU and GPU
// at full load together) without external software.

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

    // Starts 'threads' load threads (<= 0: one per logical processor).
    void start(int threads);
    // Stops and joins the threads (idempotent).
    void stop();

    int threads() const { return static_cast<int>(threads_.size()); }
    // "AVX2+FMA" if the CPU supports it, otherwise "scalar".
    const char* isaName() const { return avx2_ ? "AVX2+FMA" : "scalar"; }
    // Average GFLOPS between start() and stop() (or until now if still running).
    double gflops() const;
    double seconds() const;

    static int defaultThreads();

private:
    struct alignas(64) Counter {  // one counter per thread, on separate cache lines
        std::atomic<uint64_t> iters{0};
    };

    void worker(int index);

    std::vector<std::thread> threads_;
    std::unique_ptr<Counter[]> counters_;
    std::atomic<bool> run_{false};
    bool avx2_ = false;
    std::chrono::steady_clock::time_point t0_, t1_;
};
