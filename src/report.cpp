#include "report.hpp"

#include <algorithm>
#include <cstdio>

namespace {

struct PhaseStats {
    int count = 0;
    int powerCount = 0;
    double powerSum = 0.0;
    double powerMax = -1.0;
    double instantMax = -1.0;
    int smClockMax = -1;
    int tempMax = -1;
};

void formatW(char* buf, size_t n, double w) {
    if (w < 0) std::snprintf(buf, n, "n/a");
    else std::snprintf(buf, n, "%.1f", w);
}

void formatInt(char* buf, size_t n, int v) {
    if (v < 0) std::snprintf(buf, n, "n/a");
    else std::snprintf(buf, n, "%d", v);
}

}  // namespace

void printSummary(const std::vector<Sample>& samples, const std::vector<std::string>& phases,
                  double enforcedLimitW) {
    std::vector<PhaseStats> stats(phases.size());
    std::vector<int> order;  // phases in order of first appearance
    double peakW = -1.0;
    std::string peakPhase;

    for (const Sample& s : samples) {
        if (s.phase < 0 || s.phase >= static_cast<int>(phases.size())) continue;
        PhaseStats& ps = stats[s.phase];
        if (ps.count == 0) order.push_back(s.phase);
        ps.count++;
        if (s.powerAvgW >= 0) {
            ps.powerCount++;
            ps.powerSum += s.powerAvgW;
            ps.powerMax = std::max(ps.powerMax, s.powerAvgW);
        }
        ps.instantMax = std::max(ps.instantMax, s.powerInstantW);
        ps.smClockMax = std::max(ps.smClockMax, s.smClockMHz);
        ps.tempMax = std::max(ps.tempMax, s.tempC);

        double p = std::max(s.powerAvgW, s.powerInstantW);
        if (p > peakW) {
            peakW = p;
            peakPhase = phases[s.phase];
        }
    }

    std::printf("\n===================================== SUMMARY =====================================\n");
    std::printf("%-28s %8s %9s %9s %12s %10s %8s\n", "Phase", "Samples", "Avg W", "Max W",
                "Max inst. W", "Max SM MHz", "Max temp");
    std::printf("-----------------------------------------------------------------------------------\n");
    for (int idx : order) {
        if (Monitor::isHidden(phases[idx])) continue;
        const PhaseStats& ps = stats[idx];
        char avg[16], mx[16], inst[16], clk[16], temp[16];
        formatW(avg, sizeof(avg), ps.powerCount > 0 ? ps.powerSum / ps.powerCount : -1.0);
        formatW(mx, sizeof(mx), ps.powerMax);
        formatW(inst, sizeof(inst), ps.instantMax);
        formatInt(clk, sizeof(clk), ps.smClockMax);
        formatInt(temp, sizeof(temp), ps.tempMax);
        std::printf("%-28s %8d %9s %9s %12s %10s %8s\n", phases[idx].c_str(), ps.count, avg, mx,
                    inst, clk, temp);
    }
    std::printf("-----------------------------------------------------------------------------------\n");

    if (peakW >= 0) {
        std::printf("Global peak: %.1f W (phase \"%s\")", peakW, peakPhase.c_str());
        if (enforcedLimitW > 0)
            std::printf(", %.0f%% of the enforced power limit (%.0f W)", 100.0 * peakW / enforcedLimitW,
                        enforcedLimitW);
        std::printf("\n");
    } else {
        std::printf("Global peak: n/a (this GPU does not report power through NVML)\n");
    }

    std::printf(
        "\nWARNING: NVML samples every ~10-100 ms and does NOT see sub-millisecond transients,\n"
        "which can be much higher than the values above. This tool causes them: the real\n"
        "verdict is whether the PC reaches the end without shutting down or rebooting.\n");
    std::fflush(stdout);
}

bool writeCsv(const std::string& path, const std::vector<Sample>& samples,
              const std::vector<std::string>& phases) {
    FILE* f = std::fopen(path.c_str(), "w");
    if (!f) return false;
    std::fprintf(f, "t_s,phase,power_avg_W,power_instant_W,sm_clock_MHz,mem_clock_MHz,temp_C\n");
    for (const Sample& s : samples) {
        const std::string& name =
            (s.phase >= 0 && s.phase < static_cast<int>(phases.size())) ? phases[s.phase] : "";
        std::fprintf(f, "%.4f,%s,%.3f,%.3f,%d,%d,%d\n", s.t_s, name.c_str(), s.powerAvgW,
                     s.powerInstantW, s.smClockMHz, s.memClockMHz, s.tempC);
    }
    bool ok = std::ferror(f) == 0;
    ok = (std::fclose(f) == 0) && ok;
    return ok;
}
