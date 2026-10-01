#pragma once
// Load patterns: idle, sustained load, square wave, burst from idle.
// All patterns end early if a stop is requested (Ctrl+C).

#include <atomic>
#include <string>
#include <vector>

#include <cuda_runtime.h>

#include "loads.hpp"
#include "monitor.hpp"

// Set by the Ctrl+C handler.
extern std::atomic<bool> g_stopRequested;

struct StreamLoad {
    Launch launch;
    cudaStream_t stream;
};

// Sets the phase and waits without load.
void idle(Monitor& mon, const std::string& name, double sec);

// Launches all loads (each on its own stream), synchronizes all streams and repeats
// until the deadline.
void sustained(Monitor& mon, const std::string& name, const std::vector<StreamLoad>& loads,
               double sec);

// For each period: full load for half the period, then spin-wait until the end of the period.
void squareWave(Monitor& mon, double hz, const Launch& shortLoad, cudaStream_t stream,
                double sec);

// 'cycles' times: idle for idleSec (the GPU drops to minimum clocks), then the loads at full
// power for burstSec.
void burstFromIdle(Monitor& mon, int cycles, double idleSec, double burstSec,
                   const std::vector<StreamLoad>& loads);

// Phase name of a square wave, e.g. "Square wave 5 Hz".
std::string squareWaveName(double hz);
