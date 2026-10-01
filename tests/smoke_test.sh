#!/usr/bin/env bash
# Smoke test: esecuzione breve (--scale 0.05) che deve finire in meno di 30 s e produrre
# un CSV con l'intestazione corretta e almeno una riga per ogni fase non nascosta.
#
# Uso: tests/smoke_test.sh [percorso/del/binario] [argomenti extra...]
# Senza argomenti cerca il binario in build/ (Linux) o build/Release/ (Windows).
# Esempio con il carico CPU: tests/smoke_test.sh "" --cpu

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-}"
[ $# -gt 0 ] && shift
EXTRA=("$@")
if [ -z "$BIN" ]; then
    for c in "$ROOT/build/gpu-psu-stress" "$ROOT/build/Release/gpu-psu-stress.exe" \
             "$ROOT/build/gpu-psu-stress.exe"; do
        if [ -x "$c" ]; then BIN="$c"; break; fi
    done
fi
if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
    echo "ERRORE: binario non trovato. Compila prima con: cmake -B build && cmake --build build"
    exit 1
fi

TMPDIR_SMOKE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SMOKE"' EXIT
CSV="$TMPDIR_SMOKE/smoke.csv"
LIMIT_S=30

fail() { echo "FALLITO: $*"; exit 1; }

echo "Binario: $BIN ${EXTRA[*]}"
start=$(date +%s)
if command -v timeout >/dev/null 2>&1; then
    timeout "$((LIMIT_S + 10))" "$BIN" --scale 0.05 "${EXTRA[@]}" --out "$CSV" > "$TMPDIR_SMOKE/out.txt" 2>&1
else
    "$BIN" --scale 0.05 "${EXTRA[@]}" --out "$CSV" > "$TMPDIR_SMOKE/out.txt" 2>&1
fi
rc=$?
elapsed=$(( $(date +%s) - start ))

if [ $rc -ne 0 ]; then
    cat "$TMPDIR_SMOKE/out.txt"
    fail "il programma è uscito con codice $rc"
fi
[ "$elapsed" -lt "$LIMIT_S" ] || fail "durata ${elapsed} s, limite ${LIMIT_S} s"
[ -f "$CSV" ] || fail "il CSV $CSV non esiste"

HEADER='t_s,phase,power_avg_W,power_instant_W,sm_clock_MHz,mem_clock_MHz,temp_C'
first="$(head -n 1 "$CSV" | tr -d '\r')"
[ "$first" = "$HEADER" ] || fail "intestazione errata: '$first'"

# Fasi non nascoste attese nella sequenza predefinita.
PHASES=(
    "Idle baseline"
    "FMA FP32 sostenuto"
    "Tensor FP16 sostenuto"
    "Memoria VRAM sostenuto"
    "Tensor + memoria (max)"
    "Onda quadra 1 Hz"
    "Onda quadra 2 Hz"
    "Onda quadra 5 Hz"
    "Onda quadra 10 Hz"
    "Onda quadra 20 Hz"
    "Onda quadra 50 Hz"
    "Onda quadra 100 Hz"
    "Onda quadra 200 Hz"
    "Burst da idle"
)
missing=0
for p in "${PHASES[@]}"; do
    n=$(tail -n +2 "$CSV" | tr -d '\r' | awk -F, -v p="$p" '$2 == p' | wc -l)
    if [ "$n" -lt 1 ]; then
        echo "  manca la fase: $p"
        missing=1
    else
        printf '  %-26s %6d righe\n' "$p" "$n"
    fi
done
[ $missing -eq 0 ] || fail "fasi mancanti nel CSV"

echo "OK: smoke test superato in ${elapsed} s ($(($(wc -l < "$CSV") - 1)) campioni)"
