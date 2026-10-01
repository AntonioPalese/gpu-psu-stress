// gpu-psu-stress: generates power transients on the GPU to check whether the power supply
// holds up, monitoring power, clocks and temperature through NVML.

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <timeapi.h>
#endif

#include "check.hpp"
#include "cpu_load.hpp"
#include "kernels.cuh"
#include "loads.hpp"
#include "monitor.hpp"
#include "patterns.hpp"
#include "report.hpp"

namespace {

struct Options {
    double scale = 1.0;
    int sampleMs = 10;
    int device = 0;
    std::string out = "power_log.csv";
    std::string only;  // "", "sustained", "square", "burst"
    bool list = false;
    bool cpu = false;     // CPU load in parallel
    int cpuThreads = 0;   // 0 = one per logical processor
};

void printHelp(const char* prog) {
    std::printf(
        "Usage: %s [options]\n"
        "\n"
        "Stresses the GPU with sustained loads, square waves and bursts from idle to check\n"
        "whether the power supply can handle transient power spikes.\n"
        "\n"
        "Options:\n"
        "  --scale X        multiplier for all durations (default 1.0, about 4 minutes;\n"
        "                   the 300 ms bursts are not scaled)\n"
        "  --sample-ms N    NVML sampling period in ms (default 10, minimum 1)\n"
        "  --device N       index of the CUDA GPU to use (default 0)\n"
        "  --out FILE       output CSV file (default power_log.csv)\n"
        "  --only GROUP     runs only one group: sustained, square or burst\n"
        "                   (the initial idle phase always runs)\n"
        "  --cpu            also loads the CPU to the maximum for the whole test, in parallel\n"
        "                   with the GPU (one thread per logical processor)\n"
        "  --cpu-threads N  like --cpu, but with N threads (1-1024)\n"
        "  --list           prints the phase sequence with estimated durations and exits\n"
        "  -h, --help       shows this help\n"
        "\n"
        "Ctrl+C stops the test: the summary and the CSV are written anyway.\n",
        prog);
}

[[noreturn]] void usageError(const char* prog, const std::string& msg) {
    std::fprintf(stderr, "Error: %s\n\n", msg.c_str());
    printHelp(prog);
    std::exit(2);
}

bool parseDouble(const char* s, double& v) {
    char* end = nullptr;
    v = std::strtod(s, &end);
    return end != s && *end == '\0';
}

bool parseInt(const char* s, int& v) {
    char* end = nullptr;
    long l = std::strtol(s, &end, 10);
    if (end == s || *end != '\0' || l < -1000000 || l > 1000000) return false;
    v = static_cast<int>(l);
    return true;
}

Options parseArgs(int argc, char** argv) {
    Options o;
    const char* prog = argv[0];
    for (int i = 1; i < argc; ++i) {
        std::string a = argv[i];
        auto value = [&]() -> const char* {
            if (i + 1 >= argc) usageError(prog, "missing value for " + a);
            return argv[++i];
        };
        if (a == "-h" || a == "--help") {
            printHelp(prog);
            std::exit(0);
        } else if (a == "--scale") {
            const char* v = value();
            if (!parseDouble(v, o.scale) || !(o.scale > 0.0) || o.scale > 100.0)
                usageError(prog, std::string("--scale must be a number in (0, 100], got '") + v + "'");
        } else if (a == "--sample-ms") {
            const char* v = value();
            if (!parseInt(v, o.sampleMs) || o.sampleMs < 1 || o.sampleMs > 10000)
                usageError(prog, std::string("--sample-ms must be an integer between 1 and 10000, got '") + v + "'");
        } else if (a == "--device") {
            const char* v = value();
            if (!parseInt(v, o.device) || o.device < 0)
                usageError(prog, std::string("--device must be an integer >= 0, got '") + v + "'");
        } else if (a == "--out") {
            o.out = value();
            if (o.out.empty()) usageError(prog, "--out requires a file name");
        } else if (a == "--only") {
            o.only = value();
            if (o.only != "sustained" && o.only != "square" && o.only != "burst")
                usageError(prog, "--only accepts sustained, square or burst, got '" + o.only + "'");
        } else if (a == "--cpu") {
            o.cpu = true;
        } else if (a == "--cpu-threads") {
            const char* v = value();
            if (!parseInt(v, o.cpuThreads) || o.cpuThreads < 1 || o.cpuThreads > 1024)
                usageError(prog, std::string("--cpu-threads must be an integer between 1 and 1024, got '") + v + "'");
            o.cpu = true;
        } else if (a == "--list") {
            o.list = true;
        } else {
            usageError(prog, "unknown option '" + a + "'");
        }
    }
    return o;
}

// Context shared by the sequence steps; filled in after the optional --list.
struct Context {
    Monitor* mon = nullptr;
    LoadSet* loads = nullptr;
    cudaStream_t s1 = nullptr;
    cudaStream_t s2 = nullptr;
};

struct Step {
    std::string label;
    double sec;
    std::function<void()> run;
};

std::vector<Step> buildPlan(const Options& o, Context& c) {
    const double k = o.scale;
    std::vector<Step> plan;
    auto add = [&](const std::string& label, double sec, std::function<void()> fn) {
        plan.push_back({label, sec, std::move(fn)});
    };
    auto cooldown = [&](double base) {
        const double sec = base * k;
        add("_cooldown", sec, [&c, sec] { idle(*c.mon, "_cooldown", sec); });
    };
    auto sustainedStep = [&](const std::string& name, double base,
                             std::function<std::vector<StreamLoad>()> loads) {
        const double sec = base * k;
        add(name, sec, [&c, name, sec, loads] { sustained(*c.mon, name, loads(), sec); });
    };

    if (o.cpu) {
        // CPU power takes a few seconds to settle (temperature, boost).
        const double sec = 30 * k;
        add("_CPU warm-up", sec, [&c, sec] { idle(*c.mon, "_CPU warm-up", sec); });
    }
    add("Idle baseline", 5 * k, [&c, k] { idle(*c.mon, "Idle baseline", 5 * k); });
    if (o.only.empty() || o.only == "sustained") {
        sustainedStep("Sustained FP32 FMA", 20, [&c] {
            return std::vector<StreamLoad>{{c.loads->fma, c.s1}};
        });
        cooldown(5);
        sustainedStep("Sustained FP16 tensor", 20, [&c] {
            return std::vector<StreamLoad>{{c.loads->tensor, c.s1}};
        });
        cooldown(5);
        sustainedStep("Sustained VRAM memory", 15, [&c] {
            return std::vector<StreamLoad>{{c.loads->mem, c.s1}};
        });
        cooldown(5);
        sustainedStep("Tensor + memory (max)", 30, [&c] {
            return std::vector<StreamLoad>{{c.loads->tensor, c.s1}, {c.loads->mem, c.s2}};
        });
        cooldown(5);
    }
    if (o.only.empty() || o.only == "square") {
        for (double hz : {1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0}) {
            const double sec = 10 * k;
            add(squareWaveName(hz), sec, [&c, hz, sec] {
                // FMA load: the most power-hungry, so the swing goes from idle to the power limit.
                squareWave(*c.mon, hz, c.loads->fmaShort, c.s1, sec);
            });
            cooldown(3);
        }
    }
    if (o.only.empty() || o.only == "burst") {
        const int cycles = 10;
        const double idleSec = 3 * k;
        const double burstSec = 0.3;  // not scaled: it is the transient duration
        char label[96];
        std::snprintf(label, sizeof(label), "Burst from idle (%d x %.3g s idle + %.0f ms)", cycles,
                      idleSec, burstSec * 1000);
        add(label, cycles * (idleSec + burstSec),
            [&c, cycles, idleSec, burstSec] {
                // FMA + memory on two streams: all cores and the memory controller
                // start together from idle.
                burstFromIdle(*c.mon, cycles, idleSec, burstSec,
                              {{c.loads->fma, c.s1}, {c.loads->mem, c.s2}});
            });
    }
    return plan;
}

void printPlan(const std::vector<Step>& plan) {
    std::printf("Phase sequence (estimated durations, calibration excluded):\n");
    double t = 0.0;
    for (const Step& s : plan) {
        std::printf("  %8.1f s  %7.2f s  %s\n", t, s.sec, s.label.c_str());
        t += s.sec;
    }
    std::printf("Estimated total: %.1f s (%.1f minutes)\n", t, t / 60.0);
}

void onSignal(int) { g_stopRequested = true; }

double limitW(nvmlReturn_t r, unsigned int mw) { return (r == NVML_SUCCESS && mw > 0) ? mw / 1000.0 : -1.0; }

// Enforced power limit in W, or -1 if NVML does not report it; err receives the NVML result.
// The query must be a separate statement: in limitW(query(&mw), mw) the argument evaluation
// order is unspecified, and MSVC reads mw (still 0) before the query writes it.
double activeLimitW(nvmlDevice_t h, nvmlReturn_t* err = nullptr) {
    unsigned int mw = 0;
    nvmlReturn_t r = nvmlDeviceGetEnforcedPowerLimit(h, &mw);
    if (err) *err = r;
    return limitW(r, mw);
}

void printGpuInfo(int device, const cudaDeviceProp& prop, const Monitor& mon) {
    unsigned int def = 0;
    nvmlReturn_t enforcedErr = NVML_SUCCESS;
    double enforcedW = activeLimitW(mon.handle(), &enforcedErr);
    nvmlReturn_t defErr = nvmlDeviceGetPowerManagementDefaultLimit(mon.handle(), &def);
    double defW = limitW(defErr, def);
    // "n/a" plus the NVML reason, so an unreadable limit can be diagnosed from the log.
    auto fmt = [](double w, nvmlReturn_t err) {
        char b[96];
        if (w >= 0) std::snprintf(b, sizeof(b), "%.0f W", w);
        else if (err != NVML_SUCCESS) std::snprintf(b, sizeof(b), "n/a (NVML: %s)", nvmlErrorString(err));
        else std::snprintf(b, sizeof(b), "n/a");
        return std::string(b);
    };
    std::printf("GPU %d: %s\n", device, prop.name);
    std::printf("  SM: %d | compute capability %d.%d | VRAM %.1f GB\n", prop.multiProcessorCount,
                prop.major, prop.minor, prop.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));
    std::printf("  Enforced power limit: %s | default: %s\n", fmt(enforcedW, enforcedErr).c_str(),
                fmt(defW, defErr).c_str());
    std::printf("  NVML instantaneous power: %s\n\n",
                mon.instantPowerSupported() ? "available" : "not available (column = -1)");
}

}  // namespace

int main(int argc, char** argv) {
#ifdef _WIN32
    SetConsoleOutputCP(CP_UTF8);
#endif
    Options opt = parseArgs(argc, argv);

    Context ctx;
    std::vector<Step> plan = buildPlan(opt, ctx);
    if (opt.list) {
        printPlan(plan);
        return 0;
    }

    int deviceCount = 0;
    CK(cudaGetDeviceCount(&deviceCount));
    if (opt.device >= deviceCount) {
        std::fprintf(stderr, "Error: invalid --device %d, available CUDA GPUs: %d\n",
                     opt.device, deviceCount);
        return 2;
    }
    CK(cudaSetDevice(opt.device));
    cudaDeviceProp prop{};
    CK(cudaGetDeviceProperties(&prop, opt.device));

    // Does the binary contain code for this GPU?
    cudaFuncAttributes attr{};
    if (cudaFuncGetAttributes(&attr, fmaBurn) != cudaSuccess) {
        std::fprintf(stderr,
                     "Error: the program is not compiled for this GPU (compute capability "
                     "%d.%d).\nRebuild with -DCMAKE_CUDA_ARCHITECTURES=%d%d\n",
                     prop.major, prop.minor, prop.major, prop.minor);
        return 1;
    }

    Monitor mon(opt.device);
    printGpuInfo(opt.device, prop, mon);
    if (prop.major < 7)
        std::printf("Note: GPU without tensor cores, the tensor load falls back to FMA.\n\n");

#ifdef _WIN32
    timeBeginPeriod(1);  // 1 ms sleep granularity for the monitor and idle
#endif
    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
#ifdef SIGBREAK
    std::signal(SIGBREAK, onSignal);  // Ctrl+Break on Windows
#endif

    cudaStream_t s1, s2;
    CK(cudaStreamCreateWithFlags(&s1, cudaStreamNonBlocking));
    CK(cudaStreamCreateWithFlags(&s2, cudaStreamNonBlocking));
    LoadSet loads;
    loads.init(prop, s1);
    ctx = Context{&mon, &loads, s1, s2};

    // The CPU load starts after calibration, so it does not disturb it.
    CpuLoad cpu;
    if (opt.cpu) {
        cpu.start(opt.cpuThreads);
        std::printf("CPU load: %d threads, %s instructions, low priority (the GPU comes first)\n",
                    cpu.threads(), cpu.isaName());
        std::printf("  Note: CPU temperature and power cannot be measured from here;\n"
                    "  keep an eye on them with the motherboard monitor or HWiNFO.\n\n");
    }

    printPlan(plan);
    std::printf("\nStarting the test. Press Ctrl+C to stop.\n");
    mon.start(opt.sampleMs);
    for (const Step& s : plan) {
        if (g_stopRequested) break;
        s.run();
    }
    CK(cudaDeviceSynchronize());
    cpu.stop();
    // A few final idle samples to close the log.
    if (!g_stopRequested) idle(mon, "_end", 0.2);
    mon.stop();

    const bool interrupted = g_stopRequested;
    if (interrupted) std::printf("\nInterrupted by the user: saving the data collected so far.\n");

    double enforcedW = activeLimitW(mon.handle());
    const auto samples = mon.samples();
    const auto phases = mon.phaseNames();
    printSummary(samples, phases, enforcedW);
    if (opt.cpu) {
        std::printf("\nCPU load: %d threads (%s), %.1f GFLOPS average over %.0f s\n", cpu.threads(),
                    cpu.isaName(), cpu.gflops(), cpu.seconds());
        std::fflush(stdout);
    }

    int rc = interrupted ? 130 : 0;
    if (writeCsv(opt.out, samples, phases)) {
        std::printf("\nLog saved to %s (%zu samples).\n", opt.out.c_str(), samples.size());
        std::fflush(stdout);
    } else {
        std::fprintf(stderr, "\nError: cannot write %s\n", opt.out.c_str());
        rc = 1;
    }

    CK(cudaStreamDestroy(s1));
    CK(cudaStreamDestroy(s2));
#ifdef _WIN32
    timeEndPeriod(1);
#endif
    return rc;
}
