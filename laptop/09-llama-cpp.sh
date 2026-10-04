#!/usr/bin/env bash
# TITLE: Build llama.cpp (CUDA 12.4 for the GTX 1070)
# RUN-AS: admin
# GUIDE: Step 17
# NEEDS: -
# Options (asked when not given): --cuda | --vulkan (Vulkan is the fallback if the CUDA build fails)
# Re-run this stage to update llama.cpp (git pull, rebuild, install); then restart the service.
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
CUDA=''
for a in "$@"; do
  case $a in
    --vulkan) CUDA=0 ;;
    --cuda) CUDA=1 ;;
    *) common_flag "$a" || die "unknown option: $a" ;;
  esac
done
load_config
stage_begin
APT=(env DEBIAN_FRONTEND=noninteractive apt-get -y)
src=$HOME/src/llama.cpp
ask_flag CUDA "Build with CUDA 12.4? (recommended for the GTX 1070; say no to use Vulkan, e.g. if the CUDA build fails)" y
VULKAN=$((1 - CUDA))

if [[ $VULKAN == 1 ]]; then
  sudo_run "${APT[@]}" install libvulkan-dev glslc spirv-headers nvidia-vulkan-icd
  gpuflags=(-DGGML_VULKAN=ON)
else
  # Debian 13's CUDA 12.4 pairs with the 550 driver and supports Pascal (6.1). CUDA 13 does not.
  sudo_run "${APT[@]}" install nvidia-cuda-toolkit g++-13
  if [[ $DRY_RUN != 1 ]]; then
    rel=$(nvcc --version | sed -n 's/.*release \([0-9.]*\).*/\1/p')
    log "nvcc release $rel"
    [[ ${rel%%.*} -lt 13 ]] || die "CUDA $rel does not support Pascal. Remove it and use Debian's 12.4 toolkit (or re-run with --vulkan)."
  fi
  gpuflags=(-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=61 -DCMAKE_CUDA_HOST_COMPILER=g++-13)
fi

if [[ -d $src/.git ]]; then
  run git -C "$src" pull --ff-only
else
  run mkdir -p "$HOME/src"
  run git clone https://github.com/ggml-org/llama.cpp "$src"
fi
run cmake -S "$src" -B "$src/build" "${gpuflags[@]}" -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release
run cmake --build "$src/build" -j"$(nproc)" --target llama-server llama-bench llama-cli
sudo_run install -d /opt/llama.cpp/bin
sudo_run install -m 755 "$src/build/bin/llama-server" "$src/build/bin/llama-bench" "$src/build/bin/llama-cli" /opt/llama.cpp/bin/

if [[ $DRY_RUN != 1 ]]; then
  # --version only prints the build number; the devices are listed by --list-devices
  devs=$(/opt/llama.cpp/bin/llama-server --list-devices 2>&1 || true)
  echo "$devs" | head -8
  if [[ $VULKAN == 0 ]] && ! grep -q 'compute capability 6.1' <<<"$devs"; then
    warn "llama-server --list-devices did not show 'GTX 1070, compute capability 6.1'. Check nvidia-smi and the build."
  fi
  if [[ $VULKAN == 1 ]] && ! grep -q 'Vulkan0' <<<"$devs"; then
    warn "llama-server --list-devices did not show a Vulkan0 device. Check vulkaninfo --summary and the build."
  fi
fi
stage_end
cat <<MSG
If CUDA would not build (errors about sinpi/cospi/rsqrt are a CUDA 12.x vs new glibc clash), re-run with --vulkan.
Next:  ./setup.sh run 10
MSG
