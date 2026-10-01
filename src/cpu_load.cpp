#include "cpu_load.hpp"

#include <cmath>

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#define CPU_LOAD_X86 1
#include <immintrin.h>
#ifdef _MSC_VER
#include <intrin.h>
#endif
#endif

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#elif defined(__linux__)
#include <sys/resource.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

namespace {

constexpr uint64_t kChunk = uint64_t(1) << 20;  // iterazioni tra due controlli dello stop (~1 ms)
constexpr double kFlopsAvx2 = 8 * 8 * 2;         // 8 registri x 8 float x (mul + add)
constexpr double kFlopsScalar = 8 * 2;           // 8 catene x (mul + add)

// Il risultato finisce qui, così il compilatore non elimina il calcolo.
std::atomic<float> g_sink{0.0f};

// Supporto AVX2 + FMA, compreso il salvataggio dei registri ymm da parte del sistema operativo.
bool detectAvx2Fma() {
#if defined(CPU_LOAD_X86) && defined(_MSC_VER)
    int r[4];
    __cpuid(r, 0);
    if (r[0] < 7) return false;
    __cpuid(r, 1);
    const bool fma = (r[2] & (1 << 12)) != 0;
    const bool osxsave = (r[2] & (1 << 27)) != 0;
    const bool avx = (r[2] & (1 << 28)) != 0;
    if (!fma || !osxsave || !avx) return false;
    if ((_xgetbv(0) & 6) != 6) return false;  // stato XMM e YMM abilitato dal SO
    __cpuidex(r, 7, 0);
    return (r[1] & (1 << 5)) != 0;  // AVX2
#elif defined(CPU_LOAD_X86) && (defined(__GNUC__) || defined(__clang__))
    __builtin_cpu_init();
    return __builtin_cpu_supports("avx2") && __builtin_cpu_supports("fma");
#else
    return false;
#endif
}

// Stessa mappa caotica del kernel GPU: x = x*x - 1.9 resta in [-1.97, 1.97] (niente inf/NaN)
// ma fa commutare molti bit. 8 catene indipendenti tengono occupate entrambe le unità FMA.
#ifdef CPU_LOAD_X86
#if defined(__GNUC__) || defined(__clang__)
__attribute__((target("avx2,fma")))
#endif
float burnAvx2(uint64_t iters, float seed) {
    const __m256 c = _mm256_set1_ps(-1.9f);
    const __m256 lane = _mm256_setr_ps(0.0f, 0.01f, 0.02f, 0.03f, 0.04f, 0.05f, 0.06f, 0.07f);
    __m256 x0 = _mm256_add_ps(_mm256_set1_ps(-1.5f + seed), lane);
    __m256 x1 = _mm256_add_ps(_mm256_set1_ps(-1.1f + seed), lane);
    __m256 x2 = _mm256_add_ps(_mm256_set1_ps(-0.7f + seed), lane);
    __m256 x3 = _mm256_add_ps(_mm256_set1_ps(-0.3f + seed), lane);
    __m256 x4 = _mm256_add_ps(_mm256_set1_ps(0.1f + seed), lane);
    __m256 x5 = _mm256_add_ps(_mm256_set1_ps(0.5f + seed), lane);
    __m256 x6 = _mm256_add_ps(_mm256_set1_ps(0.9f + seed), lane);
    __m256 x7 = _mm256_add_ps(_mm256_set1_ps(1.3f + seed), lane);
    for (uint64_t i = 0; i < iters; ++i) {
        x0 = _mm256_fmadd_ps(x0, x0, c);
        x1 = _mm256_fmadd_ps(x1, x1, c);
        x2 = _mm256_fmadd_ps(x2, x2, c);
        x3 = _mm256_fmadd_ps(x3, x3, c);
        x4 = _mm256_fmadd_ps(x4, x4, c);
        x5 = _mm256_fmadd_ps(x5, x5, c);
        x6 = _mm256_fmadd_ps(x6, x6, c);
        x7 = _mm256_fmadd_ps(x7, x7, c);
    }
    __m256 s = _mm256_add_ps(_mm256_add_ps(_mm256_add_ps(x0, x1), _mm256_add_ps(x2, x3)),
                             _mm256_add_ps(_mm256_add_ps(x4, x5), _mm256_add_ps(x6, x7)));
    alignas(32) float out[8];
    _mm256_store_ps(out, s);
    _mm256_zeroupper();
    float sum = 0.0f;
    for (float v : out) sum += v;
    return sum;
}
#endif

float burnScalar(uint64_t iters, float seed) {
    float x[8];
    for (int k = 0; k < 8; ++k) x[k] = -1.5f + 0.4f * k + seed;
    for (uint64_t i = 0; i < iters; ++i) {
        for (int k = 0; k < 8; ++k) x[k] = std::fma(x[k], x[k], -1.9f);
    }
    float sum = 0.0f;
    for (float v : x) sum += v;
    return sum;
}

// Priorità bassa: la CPU resta al 100%, ma il thread che pilota la GPU e il monitor NVML
// vengono eseguiti per primi, così i tempi dei pattern restano precisi.
void lowerThreadPriority() {
#ifdef _WIN32
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#elif defined(__linux__)
    setpriority(PRIO_PROCESS, static_cast<id_t>(syscall(SYS_gettid)), 10);
#endif
}

}  // namespace

int CpuLoad::defaultThreads() {
    const unsigned n = std::thread::hardware_concurrency();
    return n > 0 ? static_cast<int>(n) : 1;
}

CpuLoad::~CpuLoad() { stop(); }

void CpuLoad::start(int threads) {
    if (run_.exchange(true)) return;
    if (threads <= 0) threads = defaultThreads();
    avx2_ = detectAvx2Fma();
    counters_ = std::make_unique<Counter[]>(threads);
    t0_ = std::chrono::steady_clock::now();
    for (int i = 0; i < threads; ++i) threads_.emplace_back(&CpuLoad::worker, this, i);
}

void CpuLoad::stop() {
    if (!run_.exchange(false)) return;
    for (std::thread& t : threads_) t.join();
    t1_ = std::chrono::steady_clock::now();
}

void CpuLoad::worker(int index) {
    lowerThreadPriority();
    const float seed = 1e-4f * static_cast<float>(index % 1000);
    float acc = 0.0f;
    while (run_.load(std::memory_order_relaxed)) {
#ifdef CPU_LOAD_X86
        acc += avx2_ ? burnAvx2(kChunk, seed) : burnScalar(kChunk / 8, seed);
#else
        acc += burnScalar(kChunk / 8, seed);
#endif
        counters_[index].iters.fetch_add(1, std::memory_order_relaxed);
    }
    g_sink.store(acc, std::memory_order_relaxed);
}

double CpuLoad::seconds() const {
    const auto end = run_ ? std::chrono::steady_clock::now() : t1_;
    return std::chrono::duration<double>(end - t0_).count();
}

double CpuLoad::gflops() const {
    if (!counters_) return 0.0;
    uint64_t chunks = 0;
    for (int i = 0; i < threads(); ++i) chunks += counters_[i].iters.load();
    const double flops = avx2_ ? double(chunks) * kChunk * kFlopsAvx2
                               : double(chunks) * (kChunk / 8) * kFlopsScalar;
    const double s = seconds();
    return s > 0 ? flops / s / 1e9 : 0.0;
}
