#pragma once
// Monitor NVML: campiona potenza, clock e temperatura in un thread separato
// e associa ogni campione alla fase di test corrente.

#include <atomic>
#include <chrono>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <nvml.h>

struct Sample {
    double t_s;            // secondi dall'avvio del monitor
    int phase;             // indice in phaseNames()
    double powerAvgW;      // nvmlDeviceGetPowerUsage (media); -1 se non disponibile
    double powerInstantW;  // NVML_FI_DEV_POWER_INSTANT; -1 se non disponibile
    int smClockMHz;        // -1 se non disponibile
    int memClockMHz;       // -1 se non disponibile
    int tempC;             // -1 se non disponibile
};

class Monitor {
public:
    // Inizializza NVML e ottiene l'handle della GPU CUDA indicata (tramite PCI bus ID).
    explicit Monitor(int cudaDevice);
    ~Monitor();

    Monitor(const Monitor&) = delete;
    Monitor& operator=(const Monitor&) = delete;

    void start(int sampleMs);  // avvia il thread di campionamento
    void stop();               // ferma il thread (idempotente)

    // Imposta la fase corrente; riusa l'indice se il nome esiste già.
    // Le fasi che iniziano con '_' sono nascoste (non stampate né riassunte).
    void setPhase(const std::string& name);

    std::vector<Sample> samples() const;
    std::vector<std::string> phaseNames() const;

    nvmlDevice_t handle() const { return handle_; }
    bool instantPowerSupported() const { return instantSupported_; }

    static bool isHidden(const std::string& phase) { return !phase.empty() && phase[0] == '_'; }

private:
    void run(int sampleMs);
    Sample takeSample();

    nvmlDevice_t handle_{};
    std::chrono::steady_clock::time_point t0_;
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<int> phase_{0};
    bool instantSupported_ = false;

    mutable std::mutex mutex_;  // protegge samples_ e phases_
    std::vector<Sample> samples_;
    std::vector<std::string> phases_;
};
