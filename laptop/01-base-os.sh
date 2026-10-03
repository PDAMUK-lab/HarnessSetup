#!/usr/bin/env bash
# TITLE: Base OS: non-free sources, NVIDIA 550 driver, server behaviour
# RUN-AS: admin
# GUIDE: Steps 2-4
# NEEDS: -
# Options (asked when not given): --nvidia | --skip-nvidia   --reboot | --no-reboot
set -Eeuo pipefail
HS_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
source "$HS_ROOT/lib/common.sh"
INSTALL_NVIDIA='' REBOOT=''
for a in "$@"; do
  case $a in
    --nvidia) INSTALL_NVIDIA=1 ;;
    --skip-nvidia) INSTALL_NVIDIA=0 ;;
    --reboot) REBOOT=1 ;;
    --no-reboot) REBOOT=0 ;;
    *) common_flag "$a" || die "unknown option: $a" ;;
  esac
done
load_config
stage_begin
APT=(env DEBIAN_FRONTEND=noninteractive apt-get -y)

# NVIDIA's PCI vendor id is 0x10de; reading /sys works before pciutils (lspci) is installed
has_nvidia() {
  local pci vendors
  pci=$(lspci 2>/dev/null || true)
  vendors=$(cat /sys/bus/pci/devices/*/vendor 2>/dev/null || true)
  grep -qi 'nvidia' <<<"$pci" || grep -qx '0x10de' <<<"$vendors"
}
if has_nvidia; then gpu_default=y; else gpu_default=n; fi
ask_flag INSTALL_NVIDIA "Install the NVIDIA 550 driver for the GTX 1070? (Debian's own package; newer drivers drop Pascal. Say no on a machine without an NVIDIA card.)" "$gpu_default"

# shellcheck disable=SC1091
. /etc/os-release
[[ ${VERSION_ID:-} == 13 ]] || fail_or_warn "this guide targets Debian 13 (found ${PRETTY_NAME:-unknown})"

log "Step 2: enable contrib / non-free / non-free-firmware"
if [[ -f /etc/apt/sources.list.d/debian.sources ]]; then
  sudo_run sed -i 's/^Components: .*/Components: main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources
else
  sudo_run sed -i -E '/^deb /s/ main( .*)?$/ main contrib non-free non-free-firmware/' /etc/apt/sources.list
fi
sudo_run apt-get update
sudo_run "${APT[@]}" full-upgrade

if [[ $INSTALL_NVIDIA == 1 ]]; then
  log "Step 3: NVIDIA 550 driver for the GTX 1070 (Pascal)"
  sudo_run "${APT[@]}" install pciutils
  has_nvidia || fail_or_warn "no NVIDIA GPU found (use --skip-nvidia if that is intended)"

  # Guard rails from the guide: newer drivers drop Pascal and the GPU vanishes at the next reboot.
  if dpkg-query -W -f='${Status}' nvidia-open-kernel-dkms 2>/dev/null | grep -q 'install ok installed'; then
    die "nvidia-open-kernel-dkms is installed; it never supported Pascal. Remove it: sudo apt purge nvidia-open-kernel-dkms"
  fi
  if grep -rqsiE 'developer\.download\.nvidia|nvidia\.github\.io|/cuda' /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    die "NVIDIA's own apt repository is configured; its drivers dropped Pascal. Remove it and re-run."
  fi
  cand=$(apt-cache policy nvidia-driver 2>/dev/null | awk '/Candidate:/{print $2}' || true)
  case $cand in
    550.*) ok "nvidia-driver candidate is $cand" ;;
    *) fail_or_warn "nvidia-driver candidate is '${cand:-none}', expected 550.x. Is trixie-backports enabled? It must not supply NVIDIA packages." ;;
  esac

  sudo_run "${APT[@]}" install linux-headers-amd64 nvidia-kernel-dkms nvidia-driver nvidia-smi \
    nvidia-persistenced firmware-misc-nonfree
  sudo_run systemctl enable nvidia-persistenced

  sb=$(mokutil --sb-state 2>/dev/null || true)
  if grep -qi 'enabled' <<<"$sb"; then
    warn "Secure Boot is ON. Enrol the DKMS key: sudo mokutil --import /var/lib/dkms/mok.pub, reboot, accept it on the blue MOK screen."
  fi
fi

log "Step 4: make the laptop behave like a server"
printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n' |
  put_file /etc/systemd/logind.conf.d/lid.conf 644
sudo_run systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo_run systemctl restart systemd-logind

sudo_run "${APT[@]}" install systemd-zram-generator
printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' | put_file /etc/systemd/zram-generator.conf 644
sudo_run systemctl daemon-reload
sudo_run systemctl start systemd-zram-setup@zram0.service
sudo_run "${APT[@]}" install unattended-upgrades

if [[ $DRY_RUN != 1 ]]; then
  swaps=$(swapon --show || true)
  if grep -q zram0 <<<"$swaps"; then ok "zram swap active"; else warn "no /dev/zram0 in swapon --show yet (a reboot will bring it up)"; fi
  if [[ $INSTALL_NVIDIA == 1 ]] && ! nvidia-smi >/dev/null 2>&1; then
    warn "nvidia-smi does not work yet - this is normal before the first reboot."
    NEED_REBOOT=1
  fi
fi

stage_end
echo
echo "Next: $([[ ${NEED_REBOOT:-0} == 1 ]] && echo "reboot (sudo reboot), then check:  nvidia-smi  -> GeForce GTX 1070, 8192MiB, 550.x. If it fails: dkms status") "
echo "Then set up key-only SSH from the desktop (desktop/windows/Setup-LaptopAccess.ps1), then:  ./setup.sh run 02"
if [[ $DRY_RUN != 1 ]]; then
  ask_flag REBOOT "Reboot now? (the NVIDIA driver needs one reboot before nvidia-smi works)" n
  if [[ $REBOOT == 1 ]]; then sudo reboot; fi
fi
