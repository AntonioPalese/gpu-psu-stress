#pragma once
// NVML monitor: samples power, clocks and temperature in a separate thread
// and tags each sample with the current test phase.

#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <nvml.h>

struct Sample {
    double t_s;            // seconds since the monitor started
    int phase;             // index into phaseNames()
    double powerAvgW;      // nvmlDeviceGetPowerUsage (average); -1 if unavailable
    double powerInstantW;  // NVML_FI_DEV_POWER_INSTANT; -1 if unavailable
    int smClockMHz;        // -1 if unavailable
    int memClockMHz;       // -1 if unavailable
    int tempC;             // -1 if unavailable
};

class Monitor {
public:
    // Initializes NVML and gets the handle of the given CUDA GPU (through the PCI bus ID).
    explicit Monitor(int cudaDevice);
    ~Monitor();

    Monitor(const Monitor&) = delete;
    Monitor& operator=(const Monitor&) = delete;

    void start(int sampleMs);  // starts the sampling thread
    void stop();               // stops the thread (idempotent)

    // Sets the current phase; reuses the index if the name already exists.
    // Phases starting with '_' are hidden (neither printed nor summarized).
    void setPhase(const std::string& name);

    std::vector<Sample> samples() const;
    std::vector<std::string> phaseNames() const;

    nvmlDevice_t handle() const { return handle_; }
    bool instantPowerSupported() const { return instantSupported_; }

    static bool isHidden(const std::string& phase) { return !phase.empty() && phase[0] == '_'; }

private:
    void run(int sampleMs);
    Sample takeSample();

    nvmlDevice_t handle_{};
    std::chrono::steady_clock::time_point t0_;
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<int> phase_{0};
    bool instantSupported_ = false;

    mutable std::mutex mutex_;  // protects samples_ and phases_
    std::vector<Sample> samples_;
    std::vector<std::string> phases_;
};
