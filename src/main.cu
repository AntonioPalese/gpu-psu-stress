// gpu-psu-stress: genera transienti di potenza sulla GPU per verificare la tenuta
// dell'alimentatore, monitorando potenza, clock e temperatura tramite NVML.

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
    bool cpu = false;     // carico CPU in parallelo
    int cpuThreads = 0;   // 0 = uno per processore logico
};

void printHelp(const char* prog) {
    std::printf(
        "Uso: %s [opzioni]\n"
        "\n"
        "Mette sotto stress la GPU con carichi sostenuti, onde quadre e burst da idle per\n"
        "verificare se l'alimentatore regge i picchi transitori di assorbimento.\n"
        "\n"
        "Opzioni:\n"
        "  --scale X        moltiplicatore di tutte le durate (default 1.0, circa 4 minuti;\n"
        "                   i burst da 300 ms non vengono scalati)\n"
        "  --sample-ms N    periodo di campionamento NVML in ms (default 10, minimo 1)\n"
        "  --device N       indice della GPU CUDA da usare (default 0)\n"
        "  --out FILE       file CSV di uscita (default power_log.csv)\n"
        "  --only GRUPPO    esegue solo un gruppo: sustained, square o burst\n"
        "                   (la fase di idle iniziale viene eseguita sempre)\n"
        "  --cpu            carica anche la CPU al massimo per tutto il test, in parallelo\n"
        "                   alla GPU (un thread per processore logico)\n"
        "  --cpu-threads N  come --cpu, ma con N thread (1-1024)\n"
        "  --list           stampa la sequenza delle fasi con le durate stimate ed esce\n"
        "  -h, --help       mostra questo aiuto\n"
        "\n"
        "Ctrl+C interrompe il test: riepilogo e CSV vengono scritti comunque.\n",
        prog);
}

[[noreturn]] void usageError(const char* prog, const std::string& msg) {
    std::fprintf(stderr, "Errore: %s\n\n", msg.c_str());
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
            if (i + 1 >= argc) usageError(prog, "manca il valore per " + a);
            return argv[++i];
        };
        if (a == "-h" || a == "--help") {
            printHelp(prog);
            std::exit(0);
        } else if (a == "--scale") {
            const char* v = value();
            if (!parseDouble(v, o.scale) || !(o.scale > 0.0) || o.scale > 100.0)
                usageError(prog, std::string("--scale deve essere un numero in (0, 100], ricevuto '") + v + "'");
        } else if (a == "--sample-ms") {
            const char* v = value();
            if (!parseInt(v, o.sampleMs) || o.sampleMs < 1 || o.sampleMs > 10000)
                usageError(prog, std::string("--sample-ms deve essere un intero tra 1 e 10000, ricevuto '") + v + "'");
        } else if (a == "--device") {
            const char* v = value();
            if (!parseInt(v, o.device) || o.device < 0)
                usageError(prog, std::string("--device deve essere un intero >= 0, ricevuto '") + v + "'");
        } else if (a == "--out") {
            o.out = value();
            if (o.out.empty()) usageError(prog, "--out richiede un nome di file");
        } else if (a == "--only") {
            o.only = value();
            if (o.only != "sustained" && o.only != "square" && o.only != "burst")
                usageError(prog, "--only accetta sustained, square o burst, ricevuto '" + o.only + "'");
        } else if (a == "--cpu") {
            o.cpu = true;
        } else if (a == "--cpu-threads") {
            const char* v = value();
            if (!parseInt(v, o.cpuThreads) || o.cpuThreads < 1 || o.cpuThreads > 1024)
                usageError(prog, std::string("--cpu-threads deve essere un intero tra 1 e 1024, ricevuto '") + v + "'");
            o.cpu = true;
        } else if (a == "--list") {
            o.list = true;
        } else {
            usageError(prog, "opzione sconosciuta '" + a + "'");
        }
    }
    return o;
}

// Contesto condiviso dai passi della sequenza; riempito dopo l'eventuale --list.
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
        // Il consumo della CPU impiega qualche secondo a stabilizzarsi (temperatura, boost).
        const double sec = 30 * k;
        add("_riscaldamento CPU", sec, [&c, sec] { idle(*c.mon, "_riscaldamento CPU", sec); });
    }
    add("Idle baseline", 5 * k, [&c, k] { idle(*c.mon, "Idle baseline", 5 * k); });
    if (o.only.empty() || o.only == "sustained") {
        sustainedStep("FMA FP32 sostenuto", 20, [&c] {
            return std::vector<StreamLoad>{{c.loads->fma, c.s1}};
        });
        cooldown(5);
        sustainedStep("Tensor FP16 sostenuto", 20, [&c] {
            return std::vector<StreamLoad>{{c.loads->tensor, c.s1}};
        });
        cooldown(5);
        sustainedStep("Memoria VRAM sostenuto", 15, [&c] {
            return std::vector<StreamLoad>{{c.loads->mem, c.s1}};
        });
        cooldown(5);
        sustainedStep("Tensor + memoria (max)", 30, [&c] {
            return std::vector<StreamLoad>{{c.loads->tensor, c.s1}, {c.loads->mem, c.s2}};
        });
        cooldown(5);
    }
    if (o.only.empty() || o.only == "square") {
        for (double hz : {1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0}) {
            const double sec = 10 * k;
            add(squareWaveName(hz), sec, [&c, hz, sec] {
                // Carico FMA: il più energivoro, così l'escursione va da idle al power limit.
                squareWave(*c.mon, hz, c.loads->fmaShort, c.s1, sec);
            });
            cooldown(3);
        }
    }
    if (o.only.empty() || o.only == "burst") {
        const int cycles = 10;
        const double idleSec = 3 * k;
        const double burstSec = 0.3;  // non scalato: è la durata del transitorio
        char label[96];
        std::snprintf(label, sizeof(label), "Burst da idle (%d x %.3g s idle + %.0f ms)", cycles,
                      idleSec, burstSec * 1000);
        add(label, cycles * (idleSec + burstSec),
            [&c, cycles, idleSec, burstSec] {
                // FMA + memoria su due stream: tutti i core e il controller di memoria
                // partono insieme dall'idle.
                burstFromIdle(*c.mon, cycles, idleSec, burstSec,
                              {{c.loads->fma, c.s1}, {c.loads->mem, c.s2}});
            });
    }
    return plan;
}

void printPlan(const std::vector<Step>& plan) {
    std::printf("Sequenza delle fasi (durate stimate, calibrazione esclusa):\n");
    double t = 0.0;
    for (const Step& s : plan) {
        std::printf("  %8.1f s  %7.2f s  %s\n", t, s.sec, s.label.c_str());
        t += s.sec;
    }
    std::printf("Totale stimato: %.1f s (%.1f minuti)\n", t, t / 60.0);
}

void onSignal(int) { g_stopRequested = true; }

double limitW(nvmlReturn_t r, unsigned int mw) { return (r == NVML_SUCCESS && mw > 0) ? mw / 1000.0 : -1.0; }

void printGpuInfo(int device, const cudaDeviceProp& prop, const Monitor& mon) {
    unsigned int enforced = 0, def = 0;
    double enforcedW = limitW(nvmlDeviceGetEnforcedPowerLimit(mon.handle(), &enforced), enforced);
    double defW = limitW(nvmlDeviceGetPowerManagementDefaultLimit(mon.handle(), &def), def);
    auto fmt = [](double w) {
        char b[32];
        if (w < 0) std::snprintf(b, sizeof(b), "n/d");
        else std::snprintf(b, sizeof(b), "%.0f W", w);
        return std::string(b);
    };
    std::printf("GPU %d: %s\n", device, prop.name);
    std::printf("  SM: %d | compute capability %d.%d | VRAM %.1f GB\n", prop.multiProcessorCount,
                prop.major, prop.minor, prop.totalGlobalMem / (1024.0 * 1024.0 * 1024.0));
    std::printf("  Power limit attivo: %s | di default: %s\n", fmt(enforcedW).c_str(),
                fmt(defW).c_str());
    std::printf("  Potenza istantanea NVML: %s\n\n",
                mon.instantPowerSupported() ? "disponibile" : "non disponibile (colonna = -1)");
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
        std::fprintf(stderr, "Errore: --device %d non valido, GPU CUDA disponibili: %d\n",
                     opt.device, deviceCount);
        return 2;
    }
    CK(cudaSetDevice(opt.device));
    cudaDeviceProp prop{};
    CK(cudaGetDeviceProperties(&prop, opt.device));

    // Il binario contiene codice per questa GPU?
    cudaFuncAttributes attr{};
    if (cudaFuncGetAttributes(&attr, fmaBurn) != cudaSuccess) {
        std::fprintf(stderr,
                     "Errore: il programma non è compilato per questa GPU (compute capability "
                     "%d.%d).\nRicompila con -DCMAKE_CUDA_ARCHITECTURES=%d%d\n",
                     prop.major, prop.minor, prop.major, prop.minor);
        return 1;
    }

    Monitor mon(opt.device);
    printGpuInfo(opt.device, prop, mon);
    if (prop.major < 7)
        std::printf("Nota: GPU senza tensor core, il carico tensor usa FMA come ripiego.\n\n");

#ifdef _WIN32
    timeBeginPeriod(1);  // sleep con granularità di 1 ms per monitor e idle
#endif
    std::signal(SIGINT, onSignal);
    std::signal(SIGTERM, onSignal);
#ifdef SIGBREAK
    std::signal(SIGBREAK, onSignal);  // Ctrl+Break su Windows
#endif

    cudaStream_t s1, s2;
    CK(cudaStreamCreateWithFlags(&s1, cudaStreamNonBlocking));
    CK(cudaStreamCreateWithFlags(&s2, cudaStreamNonBlocking));
    LoadSet loads;
    loads.init(prop, s1);
    ctx = Context{&mon, &loads, s1, s2};

    // Il carico CPU parte dopo la calibrazione, per non disturbarla.
    CpuLoad cpu;
    if (opt.cpu) {
        cpu.start(opt.cpuThreads);
        std::printf("Carico CPU: %d thread, istruzioni %s, priorità bassa (la GPU ha la precedenza)\n",
                    cpu.threads(), cpu.isaName());
        std::printf("  Nota: temperatura e potenza della CPU non sono misurabili da qui;\n"
                    "  tienile d'occhio con il monitor della scheda madre o con HWiNFO.\n\n");
    }

    printPlan(plan);
    std::printf("\nAvvio del test. Premi Ctrl+C per interrompere.\n");
    mon.start(opt.sampleMs);
    for (const Step& s : plan) {
        if (g_stopRequested) break;
        s.run();
    }
    CK(cudaDeviceSynchronize());
    cpu.stop();
    // Qualche campione finale a riposo per chiudere il log.
    if (!g_stopRequested) idle(mon, "_fine", 0.2);
    mon.stop();

    const bool interrupted = g_stopRequested;
    if (interrupted) std::printf("\nInterrotto dall'utente: salvo i dati raccolti finora.\n");

    unsigned int enforced = 0;
    double enforcedW = limitW(nvmlDeviceGetEnforcedPowerLimit(mon.handle(), &enforced), enforced);
    const auto samples = mon.samples();
    const auto phases = mon.phaseNames();
    printSummary(samples, phases, enforcedW);
    if (opt.cpu) {
        std::printf("\nCarico CPU: %d thread (%s), %.1f GFLOPS medi per %.0f s\n", cpu.threads(),
                    cpu.isaName(), cpu.gflops(), cpu.seconds());
        std::fflush(stdout);
    }

    int rc = interrupted ? 130 : 0;
    if (writeCsv(opt.out, samples, phases)) {
        std::printf("\nLog salvato in %s (%zu campioni).\n", opt.out.c_str(), samples.size());
        std::fflush(stdout);
    } else {
        std::fprintf(stderr, "\nErrore: impossibile scrivere %s\n", opt.out.c_str());
        rc = 1;
    }

    CK(cudaStreamDestroy(s1));
    CK(cudaStreamDestroy(s2));
#ifdef _WIN32
    timeEndPeriod(1);
#endif
    return rc;
}
