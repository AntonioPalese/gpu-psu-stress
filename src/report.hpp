#pragma once
// Riepilogo a schermo per fase e scrittura del log CSV.

#include <string>
#include <vector>

#include "monitor.hpp"

// Stampa la tabella per fase (escluse le fasi nascoste), il picco globale e l'avviso sui
// transienti. enforcedLimitW <= 0 significa power limit non disponibile.
void printSummary(const std::vector<Sample>& samples, const std::vector<std::string>& phases,
                  double enforcedLimitW);

// Scrive tutti i campioni (fasi nascoste comprese). Restituisce false in caso di errore.
bool writeCsv(const std::string& path, const std::vector<Sample>& samples,
              const std::vector<std::string>& phases);
