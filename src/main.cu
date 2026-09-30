// gpu-psu-stress: milestone 2, 5 s di idle monitorati e salvati in CSV.

#include <chrono>
#include <cstdio>
#include <thread>

#include "check.hpp"
#include "monitor.hpp"
#include "report.hpp"

int main() {
    int device = 0;
    CK(cudaSetDevice(device));
    cudaDeviceProp prop{};
    CK(cudaGetDeviceProperties(&prop, device));
    std::printf("GPU %d: %s\n", device, prop.name);
    std::printf("  SM: %d, compute capability %d.%d, VRAM %.1f GB\n", prop.multiProcessorCount,
                prop.major, prop.minor, prop.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));

    Monitor mon(device);
    mon.start(10);
    mon.setPhase("Idle baseline");
    std::this_thread::sleep_for(std::chrono::seconds(5));
    mon.stop();
    auto samples = mon.samples();
    auto phases = mon.phaseNames();
    std::printf("Campioni raccolti: %zu\n", samples.size());
    return writeCsv("power_log.csv", samples, phases) ? 0 : 1;
}
