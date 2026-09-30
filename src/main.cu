// gpu-psu-stress: scheletro, stampa le informazioni della GPU.

#include <cstdio>

#include "check.hpp"

int main() {
    int device = 0;
    CK(cudaSetDevice(device));
    cudaDeviceProp prop{};
    CK(cudaGetDeviceProperties(&prop, device));
    std::printf("GPU %d: %s\n", device, prop.name);
    std::printf("  SM: %d, compute capability %d.%d, VRAM %.1f GB\n", prop.multiProcessorCount,
                prop.major, prop.minor, prop.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));
    return 0;
}
