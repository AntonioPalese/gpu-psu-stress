#include "loads.hpp"

#include <algorithm>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>

#include "check.hpp"
#include "kernels.cuh"

namespace {

// VRAM left free for the desktop and other programs: the larger of 512 MB and 5% of the
// total VRAM. On Windows the display is usually connected to the same GPU.
constexpr size_t kMemReserveMin = size_t(512) << 20;
constexpr double kMemReserveFraction = 0.05;

double measureMs(const ParamLaunch& pl, cudaStream_t stream, int iters, cudaEvent_t a,
                 cudaEvent_t b) {
    CK(cudaEventRecord(a, stream));
    pl(stream, iters);
    CK(cudaEventRecord(b, stream));
    CK(cudaEventSynchronize(b));
    float ms = 0.0f;
    CK(cudaEventElapsedTime(&ms, a, b));
    return ms;
}

int scaleIters(int iters, double factor) {
    double v = std::llround(double(iters) * factor);
    return int(std::clamp(v, 1.0, double(INT_MAX / 2)));
}

}  // namespace

Launch calibrate(const ParamLaunch& paramLaunch, cudaStream_t stream, double targetMs,
                 const std::string& name) {
    cudaEvent_t a, b;
    CK(cudaEventCreate(&a));
    CK(cudaEventCreate(&b));

    // Rough estimate: increase 'iters' until the kernel lasts at least 1/10 of the target.
    int iters = 1;
    double ms = measureMs(paramLaunch, stream, iters, a, b);
    while (ms < targetMs / 10.0 && iters < INT_MAX / 32) {
        iters = scaleIters(iters, std::clamp(targetMs / std::max(ms, 1e-3), 2.0, 16.0));
        ms = measureMs(paramLaunch, stream, iters, a, b);
    }

    // Warm-up: ~200 ms of load, so the clocks ramp up before the measurements.
    const auto warmEnd = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
    while (std::chrono::steady_clock::now() < warmEnd) {
        paramLaunch(stream, iters);
        CK(cudaStreamSynchronize(stream));
    }

    // 4 measurements with proportional correction.
    ms = measureMs(paramLaunch, stream, iters, a, b);
    for (int r = 0; r < 4; ++r) {
        iters = scaleIters(iters, targetMs / std::max(ms, 1e-3));
        ms = measureMs(paramLaunch, stream, iters, a, b);
    }

    std::printf("  Calibration %-16s %10d iterations -> %.3f ms (target %.1f ms)\n",
                (name + ":").c_str(), iters, ms, targetMs);
    std::fflush(stdout);

    CK(cudaEventDestroy(a));
    CK(cudaEventDestroy(b));
    return [paramLaunch, iters](cudaStream_t s) { paramLaunch(s, iters); };
}

void LoadSet::init(const cudaDeviceProp& prop, cudaStream_t stream) {
    const int sms = prop.multiProcessorCount;
    const int fmaBlocks = sms * 8;
    const int tensorBlocks = sms * 8;
    const int memBlocks = sms * 4;

    CK(cudaMalloc(&fmaOut_, sizeof(float) * fmaBlocks * kFmaThreads));
    CK(cudaMalloc(&tensorOut_, sizeof(float) * tensorBlocks * kTensorWarps * 256));

    // Memory buffers: all free VRAM minus a margin, split into 2 buffers that alternate as
    // source and destination. Total VRAM comes from the GPU properties, free VRAM from
    // cudaMemGetInfo (it excludes what the desktop and other programs already use).
    const size_t totalB = prop.totalGlobalMem;
    size_t freeB = 0, totalInfo = 0;
    CK(cudaMemGetInfo(&freeB, &totalInfo));
    const size_t reserve =
        std::max(kMemReserveMin, static_cast<size_t>(double(totalB) * kMemReserveFraction));
    const size_t align = kMemChunkElems * sizeof(float4);
    size_t bytes = freeB > reserve ? (freeB - reserve) / 2 : 0;
    bytes -= bytes % align;
    // cudaMemGetInfo is an estimate: if the allocation fails, retry with 5% less.
    while (bytes >= align) {
        const cudaError_t e0 = cudaMalloc(&memBuf_[0], bytes);
        const cudaError_t e1 = (e0 == cudaSuccess) ? cudaMalloc(&memBuf_[1], bytes) : e0;
        if (e1 == cudaSuccess) break;
        if (e0 == cudaSuccess) cudaFree(memBuf_[0]);
        memBuf_[0] = memBuf_[1] = nullptr;
        (void)cudaGetLastError();  // clears the (non-sticky) allocation error
        bytes = bytes / 20 * 19;
        bytes -= bytes % align;
    }
    if (bytes < align) {
        std::fprintf(stderr, "Not enough free GPU memory for the memory test.\n");
        std::exit(EXIT_FAILURE);
    }
    const double gb = 1024.0 * 1024.0 * 1024.0;
    std::printf("  Memory: 2 buffers of %.2f GB = %.2f GB of %.2f GB VRAM (%.0f%%), "
                "%.2f GB left free\n",
                bytes / gb, 2.0 * bytes / gb, totalB / gb, 100.0 * 2.0 * bytes / double(totalB),
                (freeB - 2 * bytes) / gb);
    memElems_ = bytes / sizeof(float4);
    for (int i = 0; i < 2; ++i) {
        fillBuffer<<<memBlocks, kMemThreads, 0, stream>>>(memBuf_[i], memElems_, 1234u + i);
        CK(cudaGetLastError());
    }
    CK(cudaStreamSynchronize(stream));

    ParamLaunch fmaP = [this, fmaBlocks](cudaStream_t s, int iters) {
        fmaBurn<<<fmaBlocks, kFmaThreads, 0, s>>>(fmaOut_, iters);
        CK(cudaGetLastError());
    };
    ParamLaunch tensorP = [this, tensorBlocks](cudaStream_t s, int iters) {
        tensorBurn<<<tensorBlocks, kTensorThreads, 0, s>>>(tensorOut_, iters);
        CK(cudaGetLastError());
    };
    ParamLaunch memP = [this, memBlocks](cudaStream_t s, int iters) {
        const float4* src = memBuf_[memFlip_];
        float4* dst = memBuf_[memFlip_ ^ 1];
        memFlip_ ^= 1;
        // Each launch resumes where the previous one stopped: within a few launches all the
        // allocated VRAM is swept, not just the first GBs.
        const size_t start = memOffset_;
        memOffset_ = (memOffset_ + size_t(iters) * kMemChunkElems) % memElems_;
        memBurn<<<memBlocks, kMemThreads, 0, s>>>(src, dst, memElems_, start, iters);
        CK(cudaGetLastError());
    };

    std::printf("Calibrating the loads...\n");
    fma = calibrate(fmaP, stream, 2.0, "FMA");
    // Square waves and bursts use FMA: on the RTX 5070 it is the most power-hungry load
    // (~245 W, at the power limit) versus ~100 W for the tensor kernel.
    fmaShort = calibrate(fmaP, stream, 0.5, "FMA short");
    tensor = calibrate(tensorP, stream, 2.0, "Tensor");
    mem = calibrate(memP, stream, 2.0, "Memory");
}

LoadSet::~LoadSet() {
    // No CK here: the destructor may run while the program is exiting.
    cudaFree(fmaOut_);
    cudaFree(tensorOut_);
    cudaFree(memBuf_[0]);
    cudaFree(memBuf_[1]);
}
