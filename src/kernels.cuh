#pragma once
// Load kernels. Each one takes 'iters', which controls its duration, and always writes a
// result to global memory, so the compiler cannot eliminate the work.

#include <cstddef>

#include <cuda_runtime.h>

constexpr int kFmaThreads = 256;     // threads per fmaBurn block
constexpr int kTensorWarps = 4;      // warps per tensorBurn block
constexpr int kTensorThreads = kTensorWarps * 32;
constexpr int kMemThreads = 256;     // threads per memBurn block
constexpr size_t kMemChunkElems = size_t(1) << 18;  // float4 elements per unit of 'iters' (4 MB)

// Pure FP32: 8 independent chains of x = fmaf(x, x, -1.9f). out: one float per thread.
__global__ void fmaBurn(float* out, int iters);

// Tensor cores (WMMA 16x16x16, __half -> float), 4 accumulators per warp.
// out: 256 floats per warp (gridDim.x * kTensorWarps * 256).
__global__ void tensorBurn(float* out, int iters);

// Streaming read+write on float4: iters * kMemChunkElems elements starting at index
// 'start', wrapping around to 0 past n. The caller advances 'start' on every launch, so
// successive launches sweep the whole buffer even if it is much larger than one launch.
__global__ void memBurn(const float4* __restrict__ src, float4* __restrict__ dst, size_t n,
                        size_t start, int iters);

// Fills a buffer with pseudo-random values in [-1, 1].
__global__ void fillBuffer(float4* buf, size_t n, unsigned int seed);
