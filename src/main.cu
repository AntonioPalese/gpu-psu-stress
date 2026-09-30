// gpu-psu-stress: milestone 4, sequenza completa dei pattern (solo --scale).

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "check.hpp"
#include "loads.hpp"
#include "monitor.hpp"
#include "patterns.hpp"
#include "report.hpp"

int main(int argc, char** argv) {
    double scale = 1.0;
    if (argc == 3 && std::strcmp(argv[1], "--scale") == 0) scale = std::atof(argv[2]);

    int device = 0;
    CK(cudaSetDevice(device));
    cudaDeviceProp prop{};
    CK(cudaGetDeviceProperties(&prop, device));
    std::printf("GPU %d: %s\n", device, prop.name);

    cudaStream_t s1, s2;
    CK(cudaStreamCreateWithFlags(&s1, cudaStreamNonBlocking));
    CK(cudaStreamCreateWithFlags(&s2, cudaStreamNonBlocking));
    LoadSet L;
    L.init(prop, s1);

    Monitor mon(device);
    mon.start(10);
    idle(mon, "Idle baseline", 5 * scale);
    sustained(mon, "FMA FP32", {{L.fma, s1}}, 20 * scale);
    idle(mon, "_cooldown", 5 * scale);
    sustained(mon, "Tensor + memoria", {{L.tensor, s1}, {L.mem, s2}}, 30 * scale);
    idle(mon, "_cooldown", 5 * scale);
    for (double hz : {1.0, 10.0, 200.0}) {
        squareWave(mon, hz, L.tensorShort, s1, 10 * scale);
        idle(mon, "_cooldown", 3 * scale);
    }
    burstFromIdle(mon, 3, 3 * scale, 0.3, {{L.tensor, s1}, {L.mem, s2}});
    mon.stop();
    writeCsv("power_log.csv", mon.samples(), mon.phaseNames());
    return 0;
}
