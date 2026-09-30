#pragma once
// Kernel di carico. Ognuno riceve 'iters', che ne controlla la durata, e scrive sempre un
// risultato in memoria globale, così il compilatore non può eliminare il lavoro.

#include <cstddef>

#include <cuda_runtime.h>

constexpr int kFmaThreads = 256;     // thread per blocco di fmaBurn
constexpr int kTensorWarps = 4;      // warp per blocco di tensorBurn
constexpr int kTensorThreads = kTensorWarps * 32;
constexpr int kMemThreads = 256;     // thread per blocco di memBurn
constexpr size_t kMemChunkElems = size_t(1) << 18;  // float4 per unità di 'iters' (4 MB)

// FP32 puro: 8 catene indipendenti di x = fmaf(x, x, -1.9f). out: un float per thread.
__global__ void fmaBurn(float* out, int iters);

// Tensor core (WMMA 16x16x16, __half -> float), 4 accumulatori per warp.
// out: 256 float per warp (gridDim.x * kTensorWarps * 256).
__global__ void tensorBurn(float* out, int iters);

// Streaming read+write su float4: iters * kMemChunkElems elementi, ripartendo da capo su src
// quando si supera n.
__global__ void memBurn(const float4* __restrict__ src, float4* __restrict__ dst, size_t n,
                        int iters);

// Riempie un buffer con valori pseudo-casuali in [-1, 1].
__global__ void fillBuffer(float4* buf, size_t n, unsigned int seed);
