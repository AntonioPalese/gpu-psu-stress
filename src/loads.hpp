#pragma once
// Calibrazione dei kernel e astrazione "Load": una funzione che lancia un carico di durata
// nota su uno stream.

#include <functional>
#include <string>

#include <cuda_runtime.h>

using ParamLaunch = std::function<void(cudaStream_t, int iters)>;
using Launch = std::function<void(cudaStream_t)>;

// Warm-up, poi 4 misure con cudaEvent che correggono 'iters' in proporzione fino a targetMs.
// Stampa il risultato e restituisce il lancio con 'iters' fissato.
Launch calibrate(const ParamLaunch& paramLaunch, cudaStream_t stream, double targetMs,
                 const std::string& name);

// Buffer dei kernel e carichi calibrati. Non copiabile: i lanci catturano 'this'.
class LoadSet {
public:
    LoadSet() = default;
    ~LoadSet();
    LoadSet(const LoadSet&) = delete;
    LoadSet& operator=(const LoadSet&) = delete;

    // Alloca i buffer (dimensionati sul numero di SM) e calibra tutti i carichi.
    void init(const cudaDeviceProp& prop, cudaStream_t stream);

    Launch fma;       // FP32, 2 ms
    Launch fmaShort;  // FP32, 0.5 ms (onde quadre ad alta frequenza)
    Launch tensor;    // tensor core, 2 ms
    Launch mem;       // memoria, 2 ms

private:
    float* fmaOut_ = nullptr;
    float* tensorOut_ = nullptr;
    float4* memBuf_[2] = {nullptr, nullptr};
    size_t memElems_ = 0;
    int memFlip_ = 0;        // alterna sorgente e destinazione a ogni lancio
    size_t memOffset_ = 0;   // punto di partenza del prossimo lancio di memBurn
};
