cmake_minimum_required(VERSION 3.24)

# Architettura di default: Blackwell consumer (RTX 50xx, sm_120).
# Sovrascrivibile, es.: -DCMAKE_CUDA_ARCHITECTURES=89 (Ada) o 86 (Ampere).
if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
    set(CMAKE_CUDA_ARCHITECTURES 120 CACHE STRING "Architetture CUDA da compilare")
endif()

# Controlli prima di project(): se falliscono, il test del compilatore CUDA di CMake
# produrrebbe errori poco chiari.

# Individua nvcc: CMAKE_CUDA_COMPILER, CUDA_PATH, CUDAToolkit_ROOT o PATH.
if(CMAKE_CUDA_COMPILER)
    set(_nvcc "${CMAKE_CUDA_COMPILER}")
else()
    find_program(_nvcc nvcc HINTS "$ENV{CUDA_PATH}/bin" "$ENV{CUDAToolkit_ROOT}/bin" /usr/local/cuda/bin)
endif()

# Generatore Visual Studio: l'integrazione CUDA di MSBuild trova il toolkit solo tramite
# CUDA_PATH o il registro. Se mancano, gli si passa la cartella del nvcc trovato
# (equivale a -T "cuda=<cartella>").
if(CMAKE_GENERATOR MATCHES "^Visual Studio" AND _nvcc
   AND NOT CMAKE_GENERATOR_TOOLSET MATCHES "cuda=" AND "$ENV{CUDA_PATH}" STREQUAL "")
    get_filename_component(_cuda_root "${_nvcc}" DIRECTORY)
    get_filename_component(_cuda_root "${_cuda_root}" DIRECTORY)
    if(CMAKE_GENERATOR_TOOLSET)
        set(CMAKE_GENERATOR_TOOLSET "${CMAKE_GENERATOR_TOOLSET},cuda=${_cuda_root}")
    else()
        set(CMAKE_GENERATOR_TOOLSET "cuda=${_cuda_root}")
    endif()
    message(STATUS "CUDA_PATH non impostata: uso il toolkit in ${_cuda_root}")
endif()

# Versione minima di CUDA per ogni architettura richiesta.
set(_min_cuda 0)
foreach(_arch IN LISTS CMAKE_CUDA_ARCHITECTURES)
    string(REGEX MATCH "^[0-9]+" _arch_num "${_arch}")
    if(NOT _arch_num)
        continue()
    endif()
    if(_arch_num GREATER_EQUAL 100)
        set(_req 12.8)   # Blackwell (sm_100, sm_120)
    elseif(_arch_num GREATER_EQUAL 89)
        set(_req 11.8)   # Ada (sm_89), Hopper (sm_90)
    elseif(_arch_num GREATER_EQUAL 87)
        set(_req 11.4)
    elseif(_arch_num GREATER_EQUAL 86)
        set(_req 11.1)   # Ampere consumer (sm_86)
    else()
        set(_req 0)
    endif()
    if(_req VERSION_GREATER _min_cuda)
        set(_min_cuda ${_req})
        set(_min_arch ${_arch_num})
    endif()
endforeach()
if(_nvcc AND _min_cuda VERSION_GREATER 0)
    execute_process(COMMAND "${_nvcc}" --version OUTPUT_VARIABLE _nvcc_out ERROR_QUIET)
    string(REGEX MATCH "release ([0-9]+\\.[0-9]+)" _ "${_nvcc_out}")
    if(CMAKE_MATCH_1 AND CMAKE_MATCH_1 VERSION_LESS _min_cuda)
        message(FATAL_ERROR
            "L'architettura sm_${_min_arch} richiede CUDA >= ${_min_cuda}, ma ${_nvcc} è la "
            "versione ${CMAKE_MATCH_1}. Aggiorna il toolkit oppure compila per la tua GPU con "
            "-DCMAKE_CUDA_ARCHITECTURES=<compute capability senza punto> (per trovarla: "
            "nvidia-smi --query-gpu=name,compute_cap --format=csv).")
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
