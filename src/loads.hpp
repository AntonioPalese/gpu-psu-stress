#pragma once
// Kernel calibration and the "Load" abstraction: a function that launches a load of known
// duration on a stream.

#include <functional>
#include <string>

#include <cuda_runtime.h>

using ParamLaunch = std::function<void(cudaStream_t, int iters)>;
using Launch = std::function<void(cudaStream_t)>;

// Warm-up, then 4 cudaEvent measurements that correct 'iters' proportionally until targetMs.
// Prints the result and returns the launch with 'iters' fixed.
Launch calibrate(const ParamLaunch& paramLaunch, cudaStream_t stream, double targetMs,
                 const std::string& name);

// Kernel buffers and calibrated loads. Not copyable: the launches capture 'this'.
class LoadSet {
public:
    LoadSet() = default;
    ~LoadSet();
    LoadSet(const LoadSet&) = delete;
    LoadSet& operator=(const LoadSet&) = delete;

    // Allocates the buffers (sized on the SM count) and calibrates all loads.
    void init(const cudaDeviceProp& prop, cudaStream_t stream);

    Launch fma;       // FP32, 2 ms
    Launch fmaShort;  // FP32, 0.5 ms (high-frequency square waves)
    Launch tensor;    // tensor core, 2 ms
    Launch mem;       // memory, 2 ms

private:
    float* fmaOut_ = nullptr;
    float* tensorOut_ = nullptr;
    float4* memBuf_[2] = {nullptr, nullptr};
    size_t memElems_ = 0;
    int memFlip_ = 0;        // swaps source and destination on every launch
    size_t memOffset_ = 0;   // starting point of the next memBurn launch
};
