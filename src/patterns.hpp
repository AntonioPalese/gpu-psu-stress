#pragma once
// Pattern di carico: idle, carico sostenuto, onda quadra, burst da idle.
// Tutti i pattern terminano in anticipo se viene richiesto lo stop (Ctrl+C).

#include <atomic>
#include <string>
#include <vector>

#include <cuda_runtime.h>

#include "loads.hpp"
#include "monitor.hpp"

// Impostato dal gestore di Ctrl+C.
extern std::atomic<bool> g_stopRequested;

struct StreamLoad {
    Launch launch;
    cudaStream_t stream;
};

// Imposta la fase e attende senza carico.
void idle(Monitor& mon, const std::string& name, double sec);

// Lancia tutti i carichi (ognuno sul suo stream), sincronizza tutti gli stream e ripete
// fino alla scadenza.
void sustained(Monitor& mon, const std::string& name, const std::vector<StreamLoad>& loads,
               double sec);

// Per ogni periodo: pieno carico per metà periodo, poi spin-wait fino a fine periodo.
void squareWave(Monitor& mon, double hz, const Launch& shortLoad, cudaStream_t stream,
                double sec);

// 'cycles' volte: idle per idleSec (la GPU scende ai clock minimi), poi i carichi al massimo
// per burstSec.
void burstFromIdle(Monitor& mon, int cycles, double idleSec, double burstSec,
                   const std::vector<StreamLoad>& loads);

// Nome della fase di un'onda quadra, es. "Onda quadra 5 Hz".
std::string squareWaveName(double hz);
