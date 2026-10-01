#include "kernels.cuh"

#include <cuda_fp16.h>
#include <mma.h>

__global__ void __launch_bounds__(kFmaThreads) fmaBurn(float* out, int iters) {
    const int tid = blockIdx.x * blockDim.x + threadIdx.x;
    // Initial values inside [-1.9, 1.9]: the map x^2 - 1.9 stays bounded (no inf/NaN)
    // but is chaotic, so bits toggle a lot.
    float x[8];
#pragma unroll
    for (int k = 0; k < 8; ++k) x[k] = -1.5f + 0.37f * k + 1e-7f * (tid & 1023);

    for (int i = 0; i < iters; ++i) {
#pragma unroll
        for (int j = 0; j < 16; ++j) {
#pragma unroll
            for (int k = 0; k < 8; ++k) x[k] = fmaf(x[k], x[k], -1.9f);
        }
    }

    float sum = 0.0f;
#pragma unroll
    for (int k = 0; k < 8; ++k) sum += x[k];
    out[tid] = sum;
}

__global__ void __launch_bounds__(kTensorThreads) tensorBurn(float* out, int iters) {
    const int warp = threadIdx.x / 32;
    float* dst = out + (size_t(blockIdx.x) * kTensorWarps + warp) * 256;
#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ >= 700
    using namespace nvcuda;
    __shared__ __half sA[256];
    __shared__ __half sB[256];
    // Small non-zero values: the accumulators grow slowly without overflowing.
    for (int i = threadIdx.x; i < 256; i += blockDim.x) {
        sA[i] = __float2half(0.01f * float((i * 7 + blockIdx.x) % 17 - 8));
        sB[i] = __float2half(0.01f * float((i * 5 + 3) % 13 - 6));
    }
    __syncthreads();

    wmma::fragment<wmma::matrix_a, 16, 16, 16, __half, wmma::row_major> a;
    wmma::fragment<wmma::matrix_b, 16, 16, 16, __half, wmma::col_major> b;
    wmma::fragment<wmma::accumulator, 16, 16, 16, float> c0, c1, c2, c3;
    wmma::load_matrix_sync(a, sA, 16);
    wmma::load_matrix_sync(b, sB, 16);
    wmma::fill_fragment(c0, 0.0f);
    wmma::fill_fragment(c1, 0.0f);
    wmma::fill_fragment(c2, 0.0f);
    wmma::fill_fragment(c3, 0.0f);

    // 4 independent accumulators: the mma_sync calls do not depend on each other (ILP).
    for (int i = 0; i < iters; ++i) {
        wmma::mma_sync(c0, a, b, c0);
        wmma::mma_sync(c1, a, b, c1);
        wmma::mma_sync(c2, a, b, c2);
        wmma::mma_sync(c3, a, b, c3);
    }

    for (int k = 0; k < c0.num_elements; ++k) c0.x[k] += c1.x[k] + c2.x[k] + c3.x[k];
    wmma::store_matrix_sync(dst, c0, 16, wmma::mem_row_major);
#else
    // Architectures without tensor cores (< sm_70): fall back to FMA, to avoid an empty kernel.
    float x = -1.5f + 1e-7f * threadIdx.x;
    for (int i = 0; i < iters; ++i) {
#pragma unroll
        for (int j = 0; j < 64; ++j) x = fmaf(x, x, -1.9f);
    }
    for (int k = threadIdx.x % 32; k < 256; k += 32) dst[k] = x;
#endif
}

__global__ void __launch_bounds__(kMemThreads)
    memBurn(const float4* __restrict__ src, float4* __restrict__ dst, size_t n, size_t start,
            int iters) {
    const size_t tid = size_t(blockIdx.x) * blockDim.x + threadIdx.x;
    const size_t stride = size_t(gridDim.x) * blockDim.x;
    size_t remaining = size_t(iters) * kMemChunkElems;
    size_t pos = start % n;

    // Contiguous segments [pos, pos + seg): from the starting point to the end of the buffer,
    // then again from 0. The loop conditions are the same for all threads.
    while (remaining > 0) {
        const size_t seg = (remaining < n - pos) ? remaining : n - pos;
        const size_t lim = pos + seg;
        remaining -= seg;
        for (size_t i = pos + tid; i < lim; i += stride) {
            float4 v = src[i];
            // Contractive transform: values stay bounded launch after launch.
            v.x = fmaf(v.x, -0.999f, 0.001f);
            v.y = fmaf(v.y, -0.999f, 0.002f);
            v.z = fmaf(v.z, -0.999f, 0.003f);
            v.w = fmaf(v.w, -0.999f, 0.004f);
            dst[i] = v;
        }
        pos = 0;
    }
}

__global__ void fillBuffer(float4* buf, size_t n, unsigned int seed) {
    const size_t stride = size_t(gridDim.x) * blockDim.x;
    for (size_t i = size_t(blockIdx.x) * blockDim.x + threadIdx.x; i < n; i += stride) {
        unsigned int h = static_cast<unsigned int>(i) * 2654435761u ^ seed;
        float r[4];
        for (int k = 0; k < 4; ++k) {
            h ^= h >> 15;
            h *= 2246822519u;
            h ^= h >> 13;
            r[k] = (h & 0xFFFFFF) / float(0x7FFFFF) - 1.0f;
        }
        buf[i] = make_float4(r[0], r[1], r[2], r[3]);
    }
}
