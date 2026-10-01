#include "loads.hpp"

#include <algorithm>
#include <chrono>
#include <climits>
#include <cmath>
#include <cstdio>

#include "check.hpp"
#include "kernels.cuh"

namespace {

constexpr size_t kMemBufferBytes = size_t(512) << 20;  // 512 MB per buffer

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

    // Stima grossolana: aumenta 'iters' finché il kernel dura almeno 1/10 dell'obiettivo.
    int iters = 1;
    double ms = measureMs(paramLaunch, stream, iters, a, b);
    while (ms < targetMs / 10.0 && iters < INT_MAX / 32) {
        iters = scaleIters(iters, std::clamp(targetMs / std::max(ms, 1e-3), 2.0, 16.0));
        ms = measureMs(paramLaunch, stream, iters, a, b);
    }

    // Warm-up: ~200 ms di carico, così i clock salgono prima delle misure.
    const auto warmEnd = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
    while (std::chrono::steady_clock::now() < warmEnd) {
        paramLaunch(stream, iters);
        CK(cudaStreamSynchronize(stream));
    }

    // 4 misure con correzione proporzionale.
    ms = measureMs(paramLaunch, stream, iters, a, b);
    for (int r = 0; r < 4; ++r) {
        iters = scaleIters(iters, targetMs / std::max(ms, 1e-3));
        ms = measureMs(paramLaunch, stream, iters, a, b);
    }

    std::printf("  Calibrazione %-14s %10d iterazioni -> %.3f ms (obiettivo %.1f ms)\n",
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

    // 2 buffer da 512 MB; su GPU con poca VRAM si riduce a 1/4 della memoria libera ciascuno.
    size_t freeB = 0, totalB = 0;
    CK(cudaMemGetInfo(&freeB, &totalB));
    size_t bytes = std::min(kMemBufferBytes, freeB / 4);
    bytes -= bytes % (kMemChunkElems * sizeof(float4));
    if (bytes < kMemChunkElems * sizeof(float4)) {
        std::fprintf(stderr, "Memoria GPU libera insufficiente per il test di memoria.\n");
        std::exit(EXIT_FAILURE);
    }
    if (bytes < kMemBufferBytes)
        std::printf("  Nota: VRAM libera limitata, buffer di memoria da %zu MB invece di 512 MB\n",
                    bytes >> 20);
    memElems_ = bytes / sizeof(float4);
    for (int i = 0; i < 2; ++i) {
        CK(cudaMalloc(&memBuf_[i], bytes));
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
        memBurn<<<memBlocks, kMemThreads, 0, s>>>(src, dst, memElems_, iters);
        CK(cudaGetLastError());
    };

    std::printf("Calibrazione dei carichi...\n");
    fma = calibrate(fmaP, stream, 2.0, "FMA");
    // Onde quadre e burst usano l'FMA: sulla RTX 5070 è il carico che assorbe di più
    // (~245 W, al power limit) contro i ~100 W del kernel tensor.
    fmaShort = calibrate(fmaP, stream, 0.5, "FMA short");
    tensor = calibrate(tensorP, stream, 2.0, "Tensor");
    mem = calibrate(memP, stream, 2.0, "Memoria");
}

LoadSet::~LoadSet() {
    // Nessun CK qui: il distruttore può girare durante l'uscita del programma.
    cudaFree(fmaOut_);
    cudaFree(tensorOut_);
    cudaFree(memBuf_[0]);
    cudaFree(memBuf_[1]);
}
