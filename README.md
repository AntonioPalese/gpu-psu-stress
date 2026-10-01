# gpu-psu-stress

A small command-line program that stresses an NVIDIA graphics card to find out whether the
**power supply (PSU)** can handle its power spikes. It is designed for an
**RTX 5070 (250 W) with a 650 W power supply**, but it works on any recent NVIDIA GPU.

The program's messages, summary table and phase names are in Italian; this guide quotes them
as they appear and explains what they mean.

> ⚠️ **Warning.** The test pushes the GPU to the maximum for several minutes. Use it with a
> well-ventilated case, keep an eye on the temperature and stop it with **Ctrl+C** if it
> reaches abnormal levels (for a desktop card, steadily above 85-90 °C).

## What it does

1. **Generates loads** on the GPU in a repeatable way:
   - **sustained** loads (FP32 compute, tensor cores, memory, and tensor + memory together);
   - **square waves**: the GPU switches from full load to zero and back 1, 2, 5, 10, 20, 50,
     100 and 200 times per second;
   - **bursts from idle**: the GPU stays idle for 3 seconds (clocks drop to the minimum), then
     jumps to full load for 300 ms, 10 times.
2. **Measures** power, clocks and temperature through NVML (the NVIDIA driver's monitoring
   library) in a separate thread.
3. **Summarizes** the results on screen for each phase and **saves** all samples to a CSV file.
4. A separate Python script **plots** the CSV.

### Why square waves and bursts are the hardest tests

A constant load is easy for a power supply: the voltage settles and the capacitors have
nothing to do. Problems come with **sudden changes**: when the GPU goes from almost zero to
full load in a few microseconds, for an instant it draws much more than its rated power
(transients that on modern cards can reach 1.5-2 times the TGP). If the spike exceeds the
PSU protections (OCP, over-current, or OPP, over-power), the power supply shuts off for
safety and the PC suddenly turns off or reboots.

- **Square waves** repeat these edges hundreds of times per second, at different
  frequencies: some frequencies can resonate with the PSU's regulation circuit.
- **Bursts from idle** reproduce the real worst case: an idle GPU at minimum clocks that
  suddenly receives a heavy load (e.g. starting a game or loading a scene).

## The key limitation: NVML cannot see the real spikes

NVML samples every ~10-100 ms and reports averaged values. The transients that trip the
power supply last **less than a millisecond**: the tool **cannot measure them**.
The tool **causes** them; the numbers on screen only confirm that the loads are working.

**The real verdict is simple**: if the PC reaches the end of the test **without shutting
down, rebooting or going to a black screen**, the power supply holds up. **Coil whine**
(electrical whistling or buzzing) during the square waves is **normal** and is not a fault.

Measuring real sub-millisecond spikes requires hardware tools: an oscilloscope with a
current clamp, NVIDIA PCAT, ElmorLabs PMD2 or similar.

## Tips for a serious test

- **Stress the CPU at the same time.** The power supply feeds the whole system, and the
  worst case is CPU and GPU at full load together. Just add **`--cpu`**: the program loads
  all CPU cores for the whole duration of the test, with no external software.
  Alternatively you can use Prime95 (Small FFTs), OCCT or, on Linux, `stress-ng --cpu 0`.
  The program cannot read CPU temperature and power: keep an eye on them with the
  motherboard monitor or HWiNFO.
- **Check the card's 12V-2x6 connector** (or 12VHPWR): it must be **fully seated**, with no
  visible gap, and the cable must not have tight bends near the connector.
- Close games and other programs that use the GPU, so that the loads are repeatable.

For a complete step-by-step procedure (short trial, GPU only, GPU + CPU, repetitions,
how to interpret a shutdown) and a description of the tools mentioned, see
[docs/test-procedure-5070.md](docs/test-procedure-5070.md).

## Requirements

- NVIDIA GPU with a recent driver.
- **CUDA Toolkit ≥ 12.8** to build for the RTX 50xx (Blackwell, sm_120). For older GPUs
  any toolkit that supports their architecture is enough (see below).
- **CMake ≥ 3.24**.
- A C++17 compiler: GCC or Clang on Linux, **Visual Studio 2022** (with the
  "Desktop development with C++" workload) on Windows.
- For the chart: **Python 3.10+** with `pandas` and `matplotlib`.

## Building

By default the program is built for the **RTX 50xx** (compute capability 12.0).
For another GPU pass `-DCMAKE_CUDA_ARCHITECTURES` with its compute capability without the
dot: `89` for RTX 40xx (Ada), `86` for RTX 30xx (Ampere), `75` for Turing.
You can find it with `nvidia-smi --query-gpu=name,compute_cap --format=csv`.

### Linux

```bash
cmake -B build                  # RTX 50xx
# or: cmake -B build -DCMAKE_CUDA_ARCHITECTURES=89
cmake --build build -j
./build/gpu-psu-stress
```

#### Linux without CUDA installed (container)

If you do not want to install the CUDA toolkit, the `scripts/build_linux.sh` script builds
inside an official NVIDIA container with CUDA 12.8. You only need **podman** or **docker**,
and it also works from Windows (Git Bash, with Podman Desktop or Docker Desktop):

```bash
scripts/build_linux.sh            # RTX 50xx
scripts/build_linux.sh "89;120"   # several architectures in a single binary
./build-linux/gpu-psu-stress      # on the Linux PC with the GPU
```

The first run downloads the CUDA image (a few GB). The resulting binary only needs the
NVIDIA driver on the Linux PC.

### Windows (Command Prompt or PowerShell)

```bat
cmake -B build
cmake --build build --config Release
build\Release\gpu-psu-stress.exe
```

If the `CUDA_PATH` environment variable is not set, CMake automatically uses the toolkit
of the `nvcc` it finds in the `PATH`. If you still get the error
*"The CUDA Toolkit directory '' does not exist"*, delete the `build` folder (it keeps the
failed configuration) and give the path explicitly:

```bat
cmake -B build -T "cuda=C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA/v12.8"
```

### Building on a PC without the target GPU

You do not need the card to build: the right CUDA toolkit is enough. You can also create
**a single executable for several GPUs**, for example to try it on the development PC (here a
Turing card, `75`) and then use it on the RTX 5070 (`120`):

```bat
cmake -B build -DCMAKE_CUDA_ARCHITECTURES="75;120"
cmake --build build --config Release
```

- You need **CUDA 12.8 or 12.9**, which can be installed next to an older version.
  In the custom installation you can deselect the driver and keep the current one.
- CUDA 13.x requires driver ≥ 580: an executable built with CUDA 13 does not start on PCs
  with older drivers.
- On the target PC you **do not need to install CUDA**: the NVIDIA driver is enough (the
  CUDA runtime is embedded in the executable, NVML comes with the driver). On Windows the
  C++ runtime is embedded too, so the Visual C++ Redistributable is not needed.

## Usage

```
gpu-psu-stress [--scale X] [--sample-ms N] [--device N] [--out file.csv]
               [--only sustained|square|burst] [--cpu | --cpu-threads N] [--list]
```

| Option | Meaning |
|---|---|
| `--scale X` | multiplies all durations (default 1.0, about 4 minutes including cooldowns). The 300 ms bursts are not scaled. |
| `--sample-ms N` | NVML sampling period in milliseconds (default 10, minimum 1) |
| `--device N` | which GPU to use, if you have more than one (default 0) |
| `--out FILE` | CSV file name (default `power_log.csv`) |
| `--only GROUP` | runs only `sustained`, `square` or `burst` (plus the initial idle) |
| `--cpu` | also loads the CPU to the maximum, in parallel with the GPU, with one thread per logical processor (see below) |
| `--cpu-threads N` | like `--cpu`, but with N threads (1-1024) |
| `--list` | shows the phase sequence with durations and exits, without touching the GPU |

Examples:

```bash
gpu-psu-stress                          # full test
gpu-psu-stress --list                   # what will run and how long it takes
gpu-psu-stress --only square            # square waves only
gpu-psu-stress --scale 2 --out long.csv # test twice as long
gpu-psu-stress --scale 0.05             # quick run (~20 s) to check that everything works
gpu-psu-stress --cpu --scale 2          # worst case: GPU and CPU at full load together
```

### The CPU load (`--cpu`)

- It starts **after the GPU calibration**, followed by a 30 s warm-up phase (multiplied by
  `--scale`) so that the CPU power draw can settle. From then on it stays at the maximum for
  **the whole test**, idle phases included: the CPU is always loaded while the GPU produces
  the transients, as with OCCT or Prime95 running in the background.
- Each thread runs floating-point computations non-stop, with **AVX2+FMA** instructions if
  the CPU supports them (almost every CPU since 2013), otherwise with regular instructions.
- The threads run at **low priority**: the CPU stays at 100%, but the thread driving the GPU
  and the NVML monitor are served first, so the square-wave timing stays accurate.
- At the end of the test a line like
  `Carico CPU: 20 thread (AVX2+FMA), 614.0 GFLOPS medi per 58 s` ("CPU load: 20 threads,
  614.0 average GFLOPS over 58 s") confirms that the load ran. If the value drops a lot from
  one test to the next, the CPU is overheating.
- CPU temperature and power are **not** measured (that would require administrator
  privileges) and are not in the CSV.

**Ctrl+C** stops the test at any time: the loads stop and the summary and the CSV are still
written with the data collected up to that point (exit code 130).

### Default sequence

| Phase | Name in the output | Duration |
|---|---|---|
| Idle baseline | `Idle baseline` | 5 s |
| Sustained FP32 FMA | `FMA FP32 sostenuto` | 20 s |
| Sustained FP16 tensor | `Tensor FP16 sostenuto` | 20 s |
| Sustained VRAM | `Memoria VRAM sostenuto` | 15 s |
| Tensor + memory (max) | `Tensor + memoria (max)` | 30 s |
| Square waves 1, 2, 5, 10, 20, 50, 100, 200 Hz | `Onda quadra N Hz` | 10 s each |
| Bursts from idle: 10 cycles (3 s idle + 300 ms load) | `Burst da idle` | ~33 s |

Between phases there is a 5 s cooldown (3 s after each square wave). Before starting, the
program **calibrates** the loads for a few seconds so that each launch lasts a precise time
(2 ms, or 0.5 ms for the square waves): this is why the behavior is similar across GPUs.

## Reading the results

### At startup

The program prints the GPU name, SM count, compute capability, VRAM, enforced and default
power limit, and whether the GPU provides instantaneous power. Then it shows how much VRAM
the memory test uses and the calibration result of each load.

The memory test takes **all free VRAM**, leaving a margin for the desktop and other
programs (512 MB or 5% of the VRAM, whichever is larger), for example:

```
  Memoria: 2 buffer da 5.20 GB = 10.40 GB su 11.94 GB di VRAM (87%), 0.62 GB lasciati liberi
```

("Memory: 2 buffers of 5.20 GB = 10.40 GB out of 11.94 GB of VRAM (87%), 0.62 GB left free";
indicative values: they depend on how much VRAM the display and other programs already use).
During the test the whole memory is swept, one chunk per launch.

### The final table

| Column | Meaning |
|---|---|
| `Fase` | phase |
| `Campioni` | how many NVML samples were taken in the phase |
| `Media W` | average power of the phase |
| `Max W` | maximum of the average power reported by NVML |
| `Max ist. W` | maximum of the NVML "instantaneous" power (`n/d` = not available, if the GPU/driver does not provide it) |
| `Max SM MHz` | maximum core clock |
| `Max temp` | maximum temperature in °C |

Below the table there is the **global peak** (`Picco globale`) and its percentage of the
enforced power limit. Values around 100% of the power limit in the sustained loads are
normal: the card is working at the maximum allowed. Remember, though, that the real
transients, invisible to NVML, are higher.

Things to note:
- in the **high-frequency square waves** the average is about half of the full load: NVML
  averages the on/off cycles. This is expected;
- if the **SM clocks** drop a lot while the temperature rises, the GPU is
  *thermal throttling*: improve the ventilation.

### The chart

The easiest way is with [uv](https://docs.astral.sh/uv/): the `pyproject.toml` file in the
project folder lists the dependencies, and uv creates the environment in `.venv` by itself.

Installing uv (once):

```bash
# Windows (PowerShell)
winget install astral-sh.uv
# Linux
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Then, from the project folder (the commands are the same on Windows and Linux):

```bash
uv sync                                       # first time only
uv run scripts/plot_log.py power_log.csv --out chart.png --limit 250
```

On a Linux server without a graphical interface always use `--out`: without it, the script
tries to open a window.

Alternatively, with pip:

```bash
pip install pandas matplotlib
python scripts/plot_log.py power_log.csv --out chart.png --limit 250
```

Without `--out` the chart opens in a window. `--limit W` draws a dashed line
(for example at the card's TGP). The script also prints the same summary table.

The chart has three panels sharing the same time axis:
1. **Power**: average (blue) and, if available, instantaneous (orange);
2. **SM clock**;
3. **Temperature**.

The alternating gray bands separate the phases, with the name written at the top; cooldowns
have no label. In the square waves you should see the power oscillate (at low frequencies)
or settle at an intermediate value (at high ones); in the bursts, ten sharp peaks.

## CSV format

```
t_s,phase,power_avg_W,power_instant_W,sm_clock_MHz,mem_clock_MHz,temp_C
```

One row per sample: time in seconds since the start of the test, phase name, average and
instantaneous power in watts, SM and memory clocks in MHz, temperature in °C. The value
**-1** means the measurement is not available. Phases whose name starts with `_` (cooldown,
idle between bursts) are in the CSV but not in the summary.

## Tests

```bash
tests/smoke_test.sh            # short run with --scale 0.05, must take < 30 s
tests/smoke_test.sh "" --cpu   # same, with the CPU load
```

On Windows run it from Git Bash. It checks that the CSV exists, has the correct header
and contains at least one row for every phase.

## What the tool does NOT do

The program **only generates load and observes**: it does not change the power limit,
clocks, voltages or any other GPU setting, and it does not require administrator privileges.
