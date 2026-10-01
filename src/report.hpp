#pragma once
// On-screen per-phase summary and CSV log writing.

#include <string>
#include <vector>

#include "monitor.hpp"

// Prints the per-phase table (hidden phases excluded), the global peak and the transient
// warning. enforcedLimitW <= 0 means the power limit is unavailable.
void printSummary(const std::vector<Sample>& samples, const std::vector<std::string>& phases,
                  double enforcedLimitW);

// Writes all samples (hidden phases included). Returns false on error.
bool writeCsv(const std::string& path, const std::vector<Sample>& samples,
              const std::vector<std::string>& phases);
