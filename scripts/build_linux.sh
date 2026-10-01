#!/usr/bin/env bash
# Compila il binario Linux di gpu-psu-stress dentro un container CUDA 12.8 (podman o docker).
# Funziona sia da Linux sia da Windows (Git Bash), e non serve avere CUDA installato sull'host.
#
# Uso: scripts/build_linux.sh [architetture]
#   architetture: valore di CMAKE_CUDA_ARCHITECTURES, default "120" (RTX 50xx).
#                 Es.: scripts/build_linux.sh "75;120"
# Variabili: ENGINE=podman|docker   CUDA_IMAGE=<immagine>
#
# Risultato: build-linux/gpu-psu-stress (sul PC di destinazione basta il driver NVIDIA).

set -euo pipefail

ARCHS="${1:-120}"
IMAGE="${CUDA_IMAGE:-docker.io/nvidia/cuda:12.8.1-devel-ubuntu24.04}"
ENGINE="${ENGINE:-$(command -v podman || command -v docker || true)}"
if [ -z "$ENGINE" ]; then
    echo "ERRORE: serve podman o docker." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Su Git Bash (Windows) il motore dei container vuole un percorso Windows e niente
# conversione automatica dei percorsi in stile Unix.
if [ -n "${MSYSTEM:-}" ]; then
    ROOT="$(cd "$ROOT" && pwd -W)"
    export MSYS_NO_PATHCONV=1
fi

# Su Linux i file creati nel container appartengono a root: alla fine li si restituisce
# all'utente che ha lanciato lo script.
OWNER="$(id -u):$(id -g)"

echo "Motore: $ENGINE | immagine: $IMAGE | architetture: $ARCHS"
"$ENGINE" run --rm -v "$ROOT:/src" -w /src "$IMAGE" bash -euo pipefail -c "
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends cmake g++ make >/dev/null
    cmake -B build-linux -DCMAKE_CUDA_ARCHITECTURES='$ARCHS'
    cmake --build build-linux -j \$(nproc)
    chown -R '$OWNER' build-linux 2>/dev/null || true
"
echo "Binario Linux: build-linux/gpu-psu-stress"
