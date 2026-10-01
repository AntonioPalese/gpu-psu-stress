#include "monitor.hpp"

#include <cstdio>

#include "check.hpp"

Monitor::Monitor(int cudaDevice) {
    NK(nvmlInit_v2());

    // CUDA and NVML indices may not match: go through the PCI bus ID.
    char busId[64] = {};
    CK(cudaDeviceGetPCIBusId(busId, sizeof(busId), cudaDevice));
    NK(nvmlDeviceGetHandleByPciBusId_v2(busId, &handle_));

#ifdef NVML_FI_DEV_POWER_INSTANT
    nvmlFieldValue_t fv{};
    fv.fieldId = NVML_FI_DEV_POWER_INSTANT;
    instantSupported_ = nvmlDeviceGetFieldValues(handle_, 1, &fv) == NVML_SUCCESS &&
                        fv.nvmlReturn == NVML_SUCCESS;
#endif

    t0_ = std::chrono::steady_clock::now();
    phases_.push_back("_avvio");
}

Monitor::~Monitor() {
    stop();
    nvmlShutdown();
}

void Monitor::start(int sampleMs) {
    if (running_.exchange(true)) return;
    t0_ = std::chrono::steady_clock::now();
    thread_ = std::thread(&Monitor::run, this, sampleMs);
}

void Monitor::stop() {
    running_ = false;
    if (thread_.joinable()) thread_.join();
}

void Monitor::setPhase(const std::string& name) {
    int idx = -1;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        for (size_t i = 0; i < phases_.size(); ++i) {
            if (phases_[i] == name) {
                idx = static_cast<int>(i);
                break;
            }
        }
        if (idx < 0) {
            phases_.push_back(name);
            idx = static_cast<int>(phases_.size()) - 1;
        }
    }
    phase_ = idx;
    if (!isHidden(name)) {
        double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0_).count();
        std::printf("[%7.2f s] Fase: %s\n", t, name.c_str());
        std::fflush(stdout);
    }
}

std::vector<Sample> Monitor::samples() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return samples_;
}

std::vector<std::string> Monitor::phaseNames() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return phases_;
}

Sample Monitor::takeSample() {
    Sample s{};
    s.phase = phase_.load();
    s.t_s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0_).count();

    unsigned int mw = 0;
    s.powerAvgW = nvmlDeviceGetPowerUsage(handle_, &mw) == NVML_SUCCESS ? mw / 1000.0 : -1.0;

    s.powerInstantW = -1.0;
#ifdef NVML_FI_DEV_POWER_INSTANT
    if (instantSupported_) {
        nvmlFieldValue_t fv{};
        fv.fieldId = NVML_FI_DEV_POWER_INSTANT;
        if (nvmlDeviceGetFieldValues(handle_, 1, &fv) == NVML_SUCCESS &&
            fv.nvmlReturn == NVML_SUCCESS) {
            double v = -1000.0;  // value in mW
            switch (fv.valueType) {
                case NVML_VALUE_TYPE_DOUBLE: v = fv.value.dVal; break;
                case NVML_VALUE_TYPE_UNSIGNED_INT: v = fv.value.uiVal; break;
                case NVML_VALUE_TYPE_UNSIGNED_LONG: v = static_cast<double>(fv.value.ulVal); break;
                case NVML_VALUE_TYPE_UNSIGNED_LONG_LONG: v = static_cast<double>(fv.value.ullVal); break;
                case NVML_VALUE_TYPE_SIGNED_LONG_LONG: v = static_cast<double>(fv.value.sllVal); break;
                default: break;
            }
            s.powerInstantW = v / 1000.0;
        }
    }
#endif

    unsigned int v = 0;
    s.smClockMHz = nvmlDeviceGetClockInfo(handle_, NVML_CLOCK_SM, &v) == NVML_SUCCESS ? int(v) : -1;
    s.memClockMHz = nvmlDeviceGetClockInfo(handle_, NVML_CLOCK_MEM, &v) == NVML_SUCCESS ? int(v) : -1;
    s.tempC = nvmlDeviceGetTemperature(handle_, NVML_TEMPERATURE_GPU, &v) == NVML_SUCCESS ? int(v) : -1;
    return s;
}

void Monitor::run(int sampleMs) {
    using clock = std::chrono::steady_clock;
    const auto period = std::chrono::milliseconds(sampleMs);
    auto next = clock::now();
    while (running_) {
        Sample s = takeSample();
        {
            std::lock_guard<std::mutex> lock(mutex_);
            samples_.push_back(s);
        }
        // Absolute deadlines to avoid accumulating drift; if late, restart from now.
        next += period;
        auto now = clock::now();
        if (next < now) next = now;
        std::this_thread::sleep_until(next);
    }
}
