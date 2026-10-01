# gpu-psu-stress — Instructions for Claude Code

## Project goal

Build from scratch a command-line tool in CUDA C++ that stresses an NVIDIA GPU
(main target: **RTX 5070, Blackwell, compute capability 12.0 / sm_120, TGP 250 W**) to
check whether a **650 W** power supply can handle transient power spikes.

The tool must:

1. **Generate** load patterns that cause power transients in a repeatable way
   (sustained loads, square waves at several frequencies, bursts from idle).
2. **Monitor** power, clocks and temperature through NVML in a separate thread.
3. **Summarize** the results on screen per phase and **save** a complete CSV log.
4. **Visualize** the log with a separate Python script.

Known limitation, always to be documented: NVML updates every ~10–500 ms (~500 ms on the
RTX 5070 with driver 595.79, both average and instantaneous power) and **cannot measure**
sub-millisecond transients. The tool causes them; the real verdict is whether the system
shuts down or reboots (PSU OCP/OPP tripping).

## Technical constraints

- Language: CUDA C++17. Required toolkit: **CUDA ≥ 12.8** (needed for sm_120).
- Build: **CMake ≥ 3.24**, with `CMAKE_CUDA_ARCHITECTURES` defaulting to `120` and overridable
  (e.g. `89` for Ada, `86` for Ampere) so the tool can also be used on other GPUs.
- Dependencies: only the CUDA runtime and NVML (`CUDA::nvml` via `find_package(CUDAToolkit)`).
  No cuBLAS or external libraries: the load kernels are hand-written.
- Platforms: Linux and Windows. No OS-specific APIs in the main code; where needed
  (e.g. `timeBeginPeriod` on Windows), isolate them behind `#ifdef _WIN32`.
- Analysis script: Python 3.10+, dependencies limited to `pandas` and `matplotlib`.
- Everything **in English**: code comments, documentation, program output (messages, help,
  summary table, phase names) and identifiers.

## Repository layout

```
gpu-psu-stress/
├── CLAUDE.md
├── README.md                 # user guide (English)
├── CMakeLists.txt
├── pyproject.toml / uv.lock  # Python environment for the scripts (uv)
├── src/
│   ├── main.cu               # CLI parsing, phase orchestration, summary
│   ├── kernels.cuh / .cu     # load kernels
│   ├── loads.hpp / .cu       # calibration and the "Load" abstraction
│   ├── patterns.hpp / .cpp   # sustained, idle, square wave, burst
│   ├── monitor.hpp / .cpp    # NVML thread, samples, phase handling
│   ├── report.hpp / .cpp     # summary table and CSV writing
│   ├── cpu_load.hpp / .cpp   # parallel CPU load (--cpu)
│   └── check.hpp             # CK() macro for CUDA and NK() for NVML
├── scripts/
│   ├── plot_log.py           # power/clock/temperature chart from the CSV
│   ├── build_linux.sh        # Linux build inside a CUDA 12.8 container
│   └── run_all_tests.bat     # full Windows test session (output in gpu-psu-out/)
├── docs/
│   ├── test-procedure-5070.md  # step-by-step test procedure and external tools
│   └── build-plan-sm120.md     # building for sm_120 on a PC without the target GPU
└── tests/
    └── smoke_test.sh         # short run with --scale 0.05
```

## Component specifications

### Load kernels (`kernels.cu`)

All kernels take an `iters` parameter that controls their duration and **always write**
a result to global memory, so the compiler cannot eliminate the work.

- **`fmaBurn`**: pure FP32, 8 independent chains per thread. Use the map `x = fmaf(x, x, -1.9f)`,
  which is chaotic but bounded: bits toggle a lot (higher power) without diverging to inf/NaN.
- **`tensorBurn`**: tensor cores through WMMA (`nvcuda::wmma`), 16×16×16 fragments,
  `__half` inputs, `float` accumulation, 4 independent accumulators for ILP.
  Matrices loaded from shared memory once, then `mma_sync` in a loop. 4 warps per block.
- **`memBurn`**: streaming read+write on `float4` with a grid-stride loop over 2 buffers,
  swapping source and destination on every launch. The buffers take **all free VRAM**
  (`cudaMemGetInfo`) minus a margin of max(512 MB, 5% of `totalGlobalMem`), split in two;
  if the allocation fails, retry with 5% less. Each launch resumes from the index where the
  previous one stopped (`start` parameter), so successive launches sweep all allocated
  memory and not just the first GBs.

Grid sizing: always derive it from the SM count (`multiProcessorCount`), never use
fixed values (about 8 blocks per SM for FMA and tensor, 4 for memory).

### Calibration and load abstraction (`loads.cu`)

- `ParamLaunch = std::function<void(cudaStream_t, int iters)>`
- `Launch = std::function<void(cudaStream_t)>`
- `calibrate(paramLaunch, stream, targetMs, name) -> Launch`: warm-up, then 4 measurement
  iterations with `cudaEvent` that correct `iters` proportionally until `targetMs` is reached.
  Print the result of each calibration.
- Loads to calibrate: FMA 2 ms, FMA "short" 0.5 ms (for high-frequency square waves),
  Tensor 2 ms, Memory 2 ms.
- Square waves and bursts use FMA, not tensor: on the RTX 5070 FMA reaches the power limit
  (~245 W) while the tensor kernel stops at ~100 W (measured in the 2026-10-01 tests).

### Patterns (`patterns.cpp`)

- `idle(name, sec)`: sets the phase and sleeps.
- `sustained(name, {(Launch, stream)...}, sec)`: launches all loads, each on its own
  stream, then synchronizes all streams; repeats until the deadline. Multiple streams are used
  to overlap tensor and memory work.
- `squareWave(hz, shortLoad, stream, sec)`: for each period, full load for half the period
  (repeated launches of the FMA "short" load with sync), then **spin-wait** until the end of
  the period. No `sleep` here: on Windows its granularity (~15 ms) would ruin the high frequencies.
- `burstFromIdle(cycles, idleSec, burstSec)`: long idle (the GPU drops to minimum clocks),
  then FMA + memory at full load for a short time.

### NVML monitor (`monitor.cpp`)

- Get the NVML handle **through the PCI bus ID** (`cudaDeviceGetPCIBusId` →
  `nvmlDeviceGetHandleByPciBusId_v2`), not by index: with several GPUs, CUDA and NVML indices
  may not match.
- For each sample record: timestamp, phase index, `nvmlDeviceGetPowerUsage` (average),
  instantaneous power through `NVML_FI_DEV_POWER_INSTANT` (inside `#ifdef`, because the field
  only exists in recent headers; convert according to `valueType`; -1 if unavailable),
  SM clock, memory clock, temperature.
- Access to samples and phase names protected by a mutex; current phase in `std::atomic<int>`.
- `setPhase(name)` reuses the index if the name already exists. Phases whose name starts with `_`
  (cooldown, idle between bursts) are neither printed nor shown in the summary.

### Report (`report.cpp`)

- Per-phase table: sample count, average W, max W, max instantaneous W (or "n/a"),
  max SM clock, max temperature.
- Global peak and percentage of the enforced power limit (`nvmlDeviceGetEnforcedPowerLimit`).
- Always print the warning that NVML cannot see sub-millisecond transients.
- CSV with header:
  `t_s,phase,power_avg_W,power_instant_W,sm_clock_MHz,mem_clock_MHz,temp_C`

### CLI (`main.cu`)

```
gpu-psu-stress [--scale X] [--sample-ms N] [--device N] [--out file.csv]
               [--only sustained|square|burst] [--cpu | --cpu-threads N] [--list]
```

- `--scale`: multiplier for all durations (default 1.0; about 3.5 minutes in total).
- `--sample-ms`: NVML sampling period (default 10, minimum 1).
- `--device`: CUDA GPU to use (default 0).
- `--only`: runs only one group of tests.
- `--list`: prints the phase sequence with estimated durations and exits.
- `--cpu` / `--cpu-threads N`: built-in CPU load (`cpu_load.cpp`), one thread per logical
  processor by default. Starts after calibration, hidden phase `_CPU warm-up` of
  30 s × `--scale`, then stays active for the whole sequence. Kernel `x = x*x - 1.9` with 8
  independent chains: AVX2+FMA with runtime detection (no global compiler flag), scalar
  otherwise. Low-priority threads (OS APIs behind `#ifdef`). At the end of the test print
  threads, ISA and average GFLOPS. The CSV does not change.
- Validate arguments and print a clear help message when they are invalid.
- At startup print GPU name, SM count, compute capability, VRAM, enforced and default power limit.
- Handle Ctrl+C: stop the loads, close the monitor and **still write** the summary and the CSV
  with the data collected so far.

### Default test sequence (base durations, multiplied by `--scale`)

| Phase (name in the output) | Duration |
|---|---|
| idle baseline (`Idle baseline`) | 5 s |
| sustained FP32 FMA (`Sustained FP32 FMA`) | 20 s |
| sustained FP16 tensor (`Sustained FP16 tensor`) | 20 s |
| sustained memory (`Sustained VRAM memory`) | 15 s |
| tensor + memory, max (`Tensor + memory (max)`) | 30 s |
| square waves 1, 2, 5, 10, 20, 50, 100, 200 Hz (`Square wave N Hz`) | 10 s each |
| bursts from idle: 10 cycles, 3 s idle + 300 ms load (`Burst from idle`) | ~33 s |

Between load phases: `_cooldown` of 5 s (3 s after each square wave).
The burst duration (300 ms) is **not** scaled.

### Analysis script (`scripts/plot_log.py`)

- Usage: `python scripts/plot_log.py power_log.csv [--out chart.png]`
- Three panels with a shared X axis: power (average and instantaneous, plus an optional
  horizontal `--limit W` line), SM clock, temperature.
- Alternating colored background per phase, with labels for phases without `_`.
- Also prints a per-phase summary table (like the C++ report).

## Work plan (milestones)

Proceed in this order, with one commit per milestone and a verified build at each step.

1. **Skeleton**: CMakeLists, `check.hpp`, `main.cu` printing the GPU info. Build ok.
2. **NVML monitor**: sampling thread, phase handling, CSV. Test: 5 s of idle produce a valid CSV.
3. **Kernels and calibration**: the three kernels + `calibrate`. Test: calibrated iterations printed.
4. **Patterns**: sustained, square wave, burst. Test with `--scale 0.05`.
5. **Report and full CLI**: table, arguments, `--list`, `--only`, Ctrl+C handling.
6. **Python plotting script**.
7. **README.md** and `tests/smoke_test.sh`.

## Verification

- If there is no NVIDIA GPU in the environment, at least verify that the project **builds**
  (`cmake -B build && cmake --build build`) and state explicitly that execution was not
  tested. Never invent output or execution results.
- If `nvcc` is not available, say so clearly instead of working around it.
- Check that `compute-sanitizer --tool memcheck ./gpu-psu-stress --scale 0.02` reports no errors (if a GPU is present).
- The smoke test must complete in under 30 seconds and check that the CSV exists,
  has the correct header and at least one row for every non-hidden phase.
- Test `plot_log.py` with a synthetically generated sample CSV (even without a GPU).

## README.md contents

Write in English, for a user who is not a CUDA expert:

- What the tool does and why square waves and bursts are the hardest tests for a power supply.
- Requirements, building on Linux and Windows, usage examples.
- How to read the table and the chart.
- **The real verdict**: if the PC reaches the end without shutting down, rebooting or going to a black screen,
  the PSU holds up. Coil whine during the square waves is normal.
- Advice: for the worst case, stress **the CPU as well** in parallel with `--cpu`
  (alternatively Prime95 Small FFTs, `stress-ng --cpu 0`, or OCCT), because the PSU powers
  the whole system.
- Check that the 12V-2x6 connector is fully seated and without tight bends.
- Measuring real sub-millisecond spikes requires hardware tools
  (oscilloscope with current clamp, NVIDIA PCAT, ElmorLabs PMD2).
- Warning: the test pushes the GPU to the maximum for minutes; use it in a well-ventilated case
  and stop it (Ctrl+C) if the temperature reaches abnormal levels.

## Things NOT to do

- Do not add features to exceed the power limit or change voltages and clocks:
  the tool must only generate load and observe, without changing GPU settings.
- Do not use `cudaDeviceReset` or APIs that require administrator privileges.
- Do not introduce dependencies beyond CUDA, NVML and (for the script) pandas/matplotlib.
- Do not flood the launch queue without synchronizing: the patterns must stay accurate in time.
