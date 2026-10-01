#!/usr/bin/env bash
# Smoke test: short run (--scale 0.05) that must finish in under 30 s and produce
# a CSV with the correct header and at least one row for every non-hidden phase.
#
# Usage: tests/smoke_test.sh [path/to/binary] [extra arguments...]
# Without arguments it looks for the binary in build/ (Linux) or build/Release/ (Windows).
# Example with the CPU load: tests/smoke_test.sh "" --cpu

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
    echo "ERROR: binary not found. Build it first with: cmake -B build && cmake --build build"
    exit 1
fi

TMPDIR_SMOKE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SMOKE"' EXIT
CSV="$TMPDIR_SMOKE/smoke.csv"
LIMIT_S=30

fail() { echo "FAILED: $*"; exit 1; }

echo "Binary: $BIN ${EXTRA[*]}"
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
    fail "the program exited with code $rc"
fi
[ "$elapsed" -lt "$LIMIT_S" ] || fail "duration ${elapsed} s, limit ${LIMIT_S} s"
[ -f "$CSV" ] || fail "the CSV $CSV does not exist"

HEADER='t_s,phase,power_avg_W,power_instant_W,sm_clock_MHz,mem_clock_MHz,temp_C'
first="$(head -n 1 "$CSV" | tr -d '\r')"
[ "$first" = "$HEADER" ] || fail "wrong header: '$first'"

# Non-hidden phases expected in the default sequence.
PHASES=(
    "Idle baseline"
    "Sustained FP32 FMA"
    "Sustained FP16 tensor"
    "Sustained VRAM memory"
    "Tensor + memory (max)"
    "Square wave 1 Hz"
    "Square wave 2 Hz"
    "Square wave 5 Hz"
    "Square wave 10 Hz"
    "Square wave 20 Hz"
    "Square wave 50 Hz"
    "Square wave 100 Hz"
    "Square wave 200 Hz"
    "Burst from idle"
)
missing=0
for p in "${PHASES[@]}"; do
    n=$(tail -n +2 "$CSV" | tr -d '\r' | awk -F, -v p="$p" '$2 == p' | wc -l)
    if [ "$n" -lt 1 ]; then
        echo "  missing phase: $p"
        missing=1
    else
        printf '  %-26s %6d rows\n' "$p" "$n"
    fi
done
[ $missing -eq 0 ] || fail "phases missing from the CSV"

echo "OK: smoke test passed in ${elapsed} s ($(($(wc -l < "$CSV") - 1)) samples)"
