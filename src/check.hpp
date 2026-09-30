#pragma once
// Macro di controllo errori per CUDA runtime (CK) e NVML (NK).
// In caso di errore stampano chiamata, file e riga, poi terminano il programma.

#include <cstdio>
#include <cstdlib>

#include <cuda_runtime.h>
#include <nvml.h>

#define CK(call)                                                              \
    do {                                                                      \
        cudaError_t ck_err_ = (call);                                         \
        if (ck_err_ != cudaSuccess) {                                         \
            std::fprintf(stderr, "Errore CUDA in %s (%s:%d): %s\n", #call,    \
                         __FILE__, __LINE__, cudaGetErrorString(ck_err_));    \
            std::exit(EXIT_FAILURE);                                          \
        }                                                                     \
    } while (0)

#define NK(call)                                                              \
    do {                                                                      \
        nvmlReturn_t nk_err_ = (call);                                        \
        if (nk_err_ != NVML_SUCCESS) {                                        \
            std::fprintf(stderr, "Errore NVML in %s (%s:%d): %s\n", #call,    \
                         __FILE__, __LINE__, nvmlErrorString(nk_err_));       \
            std::exit(EXIT_FAILURE);                                          \
        }                                                                     \
    } while (0)
