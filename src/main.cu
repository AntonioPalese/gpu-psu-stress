// gpu-psu-stress: milestone 3, calibrazione dei carichi.

#include <cstdio>

#include "check.hpp"
#include "loads.hpp"

int main() {
    int device = 0;
    CK(cudaSetDevice(device));
    cudaDeviceProp prop{};
    CK(cudaGetDeviceProperties(&prop, device));
    std::printf("GPU %d: %s\n", device, prop.name);
    std::printf("  SM: %d, compute capability %d.%d, VRAM %.1f GB\n", prop.multiProcessorCount,
                prop.major, prop.minor, prop.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));

    cudaStream_t stream;
    CK(cudaStreamCreateWithFlags(&stream, cudaStreamNonBlocking));
    {
        LoadSet loads;
        loads.init(prop, stream);
    }
    CK(cudaStreamDestroy(stream));
    return 0;
}
