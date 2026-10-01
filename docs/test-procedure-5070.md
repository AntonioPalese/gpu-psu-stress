# Test procedure on the RTX 5070

How to use `gpu-psu-stress` to find out whether the 650 W power supply can handle the RTX 5070.
Proceed step by step: first a short trial to check that everything works, then the GPU
alone, then GPU and CPU together, repeating the hardest tests several times.

To build the executable on another PC see [build-plan-sm120.md](build-plan-sm120.md).

The program's output is in Italian: messages and file names are quoted here as they appear.

## Software needed

The minimum:

- `gpu-psu-stress.exe`, which with `--cpu` also loads the CPU: OCCT and Prime95 are no longer needed;
- **HWiNFO**, optional but recommended: it is the only way to see the CPU temperature;
- **Event Viewer**, already included in Windows.

Always download from the official websites: copies on third-party download sites often
contain adware.

| Program | What it is | What it is used for here |
|---|---|---|
| **HWiNFO** (HWiNFO64) | Free monitor for Windows that reads all motherboard, CPU and GPU sensors. At startup choose "Sensors-only". | Shows what NVML cannot see: CPU power, GPU hotspot and memory temperature and, on many RTX 50 cards, the voltage on the 16-pin connector. It can save a CSV log to compare with the tool's. |
| **OCCT** | Stress and stability testing program for Windows, free for personal use, with a graphical interface. | Optional, instead of `--cpu`: pushes the CPU to the maximum while the tool runs. It also has a "Power" test that loads CPU and GPU together, useful as a cross-check. |
| **Prime95** | Program of the GIMPS project (search for Mersenne primes), used for years as a CPU stress test. At first start choose "Just Stress Testing". | The **Small FFTs** mode drives the CPU to maximum power and heat. Alternative to OCCT: one of the two is enough. |
| **stress-ng** | Command-line program for **Linux**. | Equivalent of Prime95/OCCT if the test is done on Linux: `stress-ng --cpu 0` loads all cores. |
| **Event Viewer** | Included in Windows (`eventvwr.msc`). | After a shutdown it tells you whether it was the power supply (Kernel-Power 41) or the display driver (Display 4101). |
| **Python + pandas + matplotlib** | Language and libraries for data analysis. | Only needed by `scripts/plot_log.py` to plot the CSV. |

### Hardware tools (not needed)

They are used to **measure** sub-millisecond spikes, which no software can do.
They are not needed for this test: the practical verdict is whether the PC reaches the end
without shutting down.

- **Oscilloscope with a current clamp**: the classic electronics lab instrument.
- **NVIDIA PCAT** (Power Capture Analysis Tool): a board inserted between the power supply
  and the GPU that measures power many times per second. Mostly used by reviewers.
- **ElmorLabs PMD2**: a small USB device that measures power on PCIe and 12V-2x6 with fast
  sampling.

## Automatic run: `scripts\run_all_tests.bat`

The script runs all the tests of steps 1-3 below in sequence. Copy `gpu-psu-stress.exe` and
`run_all_tests.bat` into the same folder, then double-click the `.bat` (or start it from a
command prompt).

| # | Test (file name) | Parameters | Duration |
|---|---|---|---|
| 01 | `prova_breve_gpu_sola` (short trial, GPU only) | `--scale 0.05` | ~20 s |
| 02 | `completo_gpu_sola_scala1` (full, GPU only, scale 1) | `--scale 1` | ~4 min |
| 03 | `completo_gpu_sola_scala2` (full, GPU only, scale 2) | `--scale 2` | ~8 min |
| 04-05 | `completo_gpu_cpu_scala2_run1..2` (full, GPU + CPU) | `--cpu --scale 2` | ~9 min each |
| 06-08 | `onde_quadre_gpu_cpu_scala2_run1..3` (square waves, GPU + CPU) | `--cpu --only square --scale 2` | ~5 min each |
| 09-11 | `burst_gpu_cpu_scala2_run1..3` (bursts, GPU + CPU) | `--cpu --only burst --scale 2` | ~2 min each |

In tests 04-11 the program also loads all CPU cores (`--cpu`), with a 60 s warm-up at the
start of each test. There is a 30 s pause between tests. About 55 minutes in total, with no
questions: you can leave it running on its own.

Everything ends up in `gpu-psu-out\sessione_YYYYMMDD_HHMMSS\`, next to the `.bat`:

- `NN_<test>.csv`: the samples, from which `plot_log.py` draws the charts;
- `NN_<test>.log`: the complete program output (calibration, phases, summary), with the
  command at the top and the exit code at the bottom;
- `sessione.log`: GPU, driver and power limit (from `nvidia-smi`), time and outcome of each test.

Ctrl+C stops the running test, and the CSV is still saved. When asked
*"Terminare il processo batch (S/N)?"* ("Terminate batch job (Y/N)?") answer **N** to move on
to the next test, **S** to stop everything. After a Ctrl+C the end of that test's `.log` may
be missing: the CSV is still complete up to the moment of the interruption.

To check that the script works before the real session:
`run_all_tests.bat rapido` runs all 11 tests with minimal durations (~2-3 minutes), with no
questions or pauses, and writes to `gpu-psu-out\rapido_...`.

## 0. Preparation (once)

- Copy `gpu-psu-stress.exe` to the PC with the 5070. If you want the charts directly there,
  also copy `scripts/plot_log.py` and install Python with `pandas` and `matplotlib`;
  otherwise bring the CSVs back to the development PC.
- **Up-to-date driver, no overclock or undervolt**, factory power limit: the test must
  represent normal use.
- Check the **12V-2x6 connector**: fully seated and without tight bends near the card.
  Case closed, fans as you normally use them.
- Close games, browsers with hardware acceleration and other programs that use the GPU.
- Optional: start **HWiNFO** with logging enabled.

## 1. Short trial (about 1 minute)

```powershell
.\gpu-psu-stress.exe --list
.\gpu-psu-stress.exe --scale 0.05 --out prova.csv
```

Check that:

- the **enforced power limit** (`Power limit attivo`) is about 250 W;
- the **calibrations** reach about 2.0 ms and 0.5 ms;
- the **`Potenza istantanea NVML`** (NVML instantaneous power) line says `disponibile` (available).

If something does not add up, stop and analyze the output before going on.

## 2. GPU only (about 4 minutes)

```powershell
.\gpu-psu-stress.exe --out gpu_sola.csv
python plot_log.py gpu_sola.csv --out gpu_sola.png --limit 250
```

What to expect:

- in the sustained loads the power is close to 250 W;
- if the clocks drop while the temperature rises, the card is throttling because of heat;
- in the table, **`Max ist. W` must differ from `Max W`**: this shows that the instantaneous
  power reading really works (on the development MX550 they were identical).

## 3. Worst case: GPU and CPU together

1. Add `--cpu`: the program loads all CPU cores for the whole test, after a warm-up of
   30 s × `--scale`. No other program is needed.
   ```powershell
   .\gpu-psu-stress.exe --cpu --scale 2 --out gpu_cpu.csv
   ```
   At the end of the test check the `Carico CPU: ... GFLOPS medi` (CPU load, average GFLOPS)
   line: it confirms that the load ran. As an alternative to `--cpu` you can still use OCCT
   or Prime95 Small FFTs.
2. Repeat the tests that cause transients several times, because a PSU protection trip is a
   random event and a single run says little:
   ```powershell
   .\gpu-psu-stress.exe --cpu --only square --scale 2 --out square_cpu.csv
   .\gpu-psu-stress.exe --cpu --only burst  --scale 2 --out burst_cpu.csv
   ```
   Do at least 3 rounds of each. With `--scale 2` the square waves last 20 s per frequency;
   the bursts stay at 300 ms, but the idle time between bursts doubles.

## 4. Checks after each run

- Open the Windows Event Viewer, Windows Logs → System, and look for:
  - **Kernel-Power 41**: sudden shutdown, i.e. the power supply cut the power;
  - **Display 4101**: the display driver hung and recovered by itself. This is a GPU or
    driver problem, not a power supply one.
- Compare the `gpu_sola` and `gpu_cpu` charts.

## 5. How to read the outcome

| What happens | Likely meaning |
|---|---|
| Reaches the end of everything, also with the CPU loaded and in the repetitions | **The PSU holds up** |
| Shuts down or reboots during square waves or bursts | OCP/OPP tripping on the transients: power supply at its limit |
| Shuts down only with the CPU loaded | Total system power at its limit |
| Shuts down during the sustained loads | Insufficient continuous power, or a thermal or connector problem |
| Black screen but the PC stays on, with event 4101 | Driver or GPU instability, not the PSU |
| Whistling (coil whine) during the square waves | Normal |

**When to stop (Ctrl+C):**

- the GPU temperature steadily exceeds 85-90 °C, or the hotspot or memory temperature rises
  much more than usual;
- you smell burning or hear noises other than coil whine.

The CSV is still saved.

A note on the numbers: 250 W of GPU plus a stressed CPU usually stay well within 650 W.
The real risk is the transients lasting a few microseconds. If the power supply is
**ATX 3.0/3.1** certified, it is designed to withstand short spikes up to about twice its
rated power.
