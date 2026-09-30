cmake_minimum_required(VERSION 3.24)

# Architettura di default: Blackwell consumer (RTX 50xx, sm_120).
# Sovrascrivibile, es.: -DCMAKE_CUDA_ARCHITECTURES=89 (Ada) o 86 (Ampere).
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES 120 CACHE STRING "Architetture CUDA da compilare")
endif()

# sm_120 richiede CUDA >= 12.8. Il controllo va fatto prima di project(), altrimenti
# il test del compilatore fallisce con un messaggio poco chiaro.
set(_needs_cuda_12_8 OFF)
foreach(_arch IN LISTS CMAKE_CUDA_ARCHITECTURES)
    string(REGEX MATCH "^[0-9]+" _arch_num "${_arch}")
    if(_arch_num AND _arch_num GREATER_EQUAL 120)
        set(_needs_cuda_12_8 ON)
    endif()
endforeach()
if(_needs_cuda_12_8)
    if(CMAKE_CUDA_COMPILER)
        set(_nvcc "${CMAKE_CUDA_COMPILER}")
    else()
        find_program(_nvcc nvcc HINTS "$ENV{CUDA_PATH}/bin" "$ENV{CUDAToolkit_ROOT}/bin" /usr/local/cuda/bin)
    endif()
    if(_nvcc)
        execute_process(COMMAND "${_nvcc}" --version OUTPUT_VARIABLE _nvcc_out ERROR_QUIET)
        string(REGEX MATCH "release ([0-9]+\\.[0-9]+)" _ "${_nvcc_out}")
        if(CMAKE_MATCH_1 AND CMAKE_MATCH_1 VERSION_LESS 12.8)
            message(FATAL_ERROR
                "CMAKE_CUDA_ARCHITECTURES=${CMAKE_CUDA_ARCHITECTURES} richiede CUDA >= 12.8, "
                "ma ${_nvcc} è la versione ${CMAKE_MATCH_1}. Aggiorna il toolkit oppure "
                "compila per la tua GPU, es. -DCMAKE_CUDA_ARCHITECTURES=89 (Ada) o 86 (Ampere).")
        endif()
    endif()
endif()

project(gpu-psu-stress LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CUDA_STANDARD 17)
set(CMAKE_CUDA_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Tipo di build" FORCE)
endif()

find_package(CUDAToolkit REQUIRED)
find_package(Threads REQUIRED)

add_executable(gpu-psu-stress
    src/main.cu
    src/kernels.cu
    src/loads.cu
    src/monitor.cpp
    src/patterns.cpp
    src/report.cpp
)

target_link_libraries(gpu-psu-stress PRIVATE CUDA::cudart CUDA::nvml Threads::Threads)

if(MSVC)
    # Sorgenti e output in UTF-8 (accenti italiani).
    target_compile_options(gpu-psu-stress PRIVATE
        $<$<COMPILE_LANGUAGE:CXX>:/utf-8>
        $<$<COMPILE_LANGUAGE:CUDA>:-Xcompiler=/utf-8>)
endif()
if(WIN32)
    # timeBeginPeriod per una granularità di sleep di 1 ms.
    target_link_libraries(gpu-psu-stress PRIVATE winmm)
endif()
