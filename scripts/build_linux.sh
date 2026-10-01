#!/usr/bin/env bash
# Builds the gpu-psu-stress Linux binary inside a CUDA 12.8 container (podman or docker).
# Works both from Linux and from Windows (Git Bash), and CUDA does not need to be installed
# on the host.
#
# Usage: scripts/build_linux.sh [architectures]
#   architectures: value of CMAKE_CUDA_ARCHITECTURES, default "120" (RTX 50xx).
#                  E.g.: scripts/build_linux.sh "75;120"
# Variables: ENGINE=podman|docker   CUDA_IMAGE=<image>
#
# Result: build-linux/gpu-psu-stress (the target PC only needs the NVIDIA driver).

set -euo pipefail

ARCHS="${1:-120}"
IMAGE="${CUDA_IMAGE:-docker.io/nvidia/cuda:12.8.1-devel-ubuntu24.04}"
ENGINE="${ENGINE:-$(command -v podman || command -v docker || true)}"
if [ -z "$ENGINE" ]; then
    echo "ERROR: podman or docker is required." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# On Git Bash (Windows) the container engine wants a Windows path and no automatic
# conversion of Unix-style paths.
if [ -n "${MSYSTEM:-}" ]; then
    ROOT="$(cd "$ROOT" && pwd -W)"
    export MSYS_NO_PATHCONV=1
fi

# On Linux the files created in the container belong to root: at the end they are handed
# back to the user who ran the script.
OWNER="$(id -u):$(id -g)"

echo "Engine: $ENGINE | image: $IMAGE | architectures: $ARCHS"
"$ENGINE" run --rm -v "$ROOT:/src" -w /src "$IMAGE" bash -euo pipefail -c "
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends cmake g++ make >/dev/null
    cmake -B build-linux -DCMAKE_CUDA_ARCHITECTURES='$ARCHS'
    cmake --build build-linux -j \$(nproc)
    chown -R '$OWNER' build-linux 2>/dev/null || true
"
echo "Linux binary: build-linux/gpu-psu-stress"
