# Plan: building for the RTX 5070 (sm_120) on a PC without the card

## Context

You do not need the RTX 5070 in the PC to build: `nvcc` generates code for any
architecture, regardless of the installed GPU. The GPU is only needed to *run* it.

On the development PC (GeForce MX550, compute capability 7.5, driver 573.76) the sm_120 build
used to stop only because the installed toolkit was CUDA 11.6: sm_120 requires CUDA ≥ 12.8.
The check is in `CMakeLists.txt`, before `project()`.

The key point: with `-DCMAKE_CUDA_ARCHITECTURES="75;120"` you get **a single executable**
that runs both on the MX550 (sm_75, testable on the development PC) and on the RTX 5070 (sm_120).
No code changes are needed: the check in `CMakeLists.txt` already handles a list of
architectures and applies the highest requirement (12.8).

## Steps

1. **Install CUDA 12.8 or 12.9** (not 13.x) for Windows from developer.nvidia.com.
   - Why not 13: CUDA 13 requires driver ≥ 580. With the current driver (573.76) an
     executable built with CUDA 13 would not start on the MX550. On the 5070 it would work,
     if its driver is recent enough.
   - Choose the **custom** installation: deselect the "Driver" component (keep the current
     one) and leave "Visual Studio Integration". 12.x installs next to 11.6, without
     removing it.
2. **Reopen the terminal**, so that `CUDA_PATH` and `PATH` point to 12.x. Delete the
   `build` folder, then:
   ```powershell
   cmake -B build -DCMAKE_CUDA_ARCHITECTURES="75;120"
   cmake --build build --config Release
   ```
   If CMake still used 11.6, give the toolkit explicitly:
   `-T "cuda=C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8"`.
3. **Copy `build\Release\gpu-psu-stress.exe` to the PC with the 5070.** CUDA does not need
   to be installed there: the CUDA runtime is embedded in the executable and `nvml.dll` is
   installed with the NVIDIA driver.

## What cannot be verified on the development PC

- The sm_120 part builds, but can only run on the 5070.
- With the CUDA 12.x headers the `NVML_FI_DEV_POWER_INSTANT` reading (`src/monitor.cpp`) is
  compiled for the first time. On the MX550 it will probably turn out "not available"; the
  real behavior must be checked on the 5070.

## Documentation

- Done: `README.md` contains the "Building on a PC without the target GPU" section with
  these points (`"75;120"` build, CUDA 12.8/12.9 and the driver requirement).

## Verification (after installing CUDA 12.x)

Performed on 2026-10-01 with CUDA 12.8.61, driver 573.76, on the MX550.

- [x] `cmake -B build -DCMAKE_CUDA_ARCHITECTURES="75;120"` and the build complete without
      errors or warnings (CMake finds CUDA 12.8 by itself).
- [x] `cuobjdump --list-elf build\Release\gpu-psu-stress.exe` shows both `sm_75` and `sm_120`.
      The sm_120 tensor kernel uses `HMMA.16816.F32` instructions (tensor cores).
- [x] `bash tests/smoke_test.sh` passes on the MX550 in 17 s.
- [x] `compute-sanitizer --tool memcheck build\Release\gpu-psu-stress.exe --scale 0.02`
      reports 0 errors.
- [x] `Potenza istantanea NVML` line on the MX550: `disponibile` (available), but the value
      matches the average (same maximum, 31.94 W). The laptop driver probably returns the
      same sensor.
- [x] On the 5070 (tests `test1`-`test4`, 2026-10-01): `Max ist. W` differs from `Max W`
      (e.g. 177 W vs 48 W in the bursts of `test2`), so the instantaneous reading really works.
- [x] On the 5070: full test run (`test2` at scale 1, `test3`/`test4` at scale 2), all
      completed.
