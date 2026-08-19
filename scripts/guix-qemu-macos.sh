#!/usr/bin/env bash
set -euo pipefail

GUIX_VERSION="${GUIX_VERSION:-1.4.0}"
VM_CORES="${VM_CORES:-4}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
QEMU_BIN="${QEMU_BIN:-}"

die() {
  echo "Error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required"
}

brew_formula_available() {
  brew info --formula "$1" >/dev/null 2>&1
}

usage() {
  cat <<EOF
Usage: guix-qemu-macos.sh [OPTIONS]

Boot a Guix VM image on macOS using QEMU.

Options:
  -h, --help              Show this help and exit
  --guix-version VERSION  Guix VM image version (default: $GUIX_VERSION)
  --cores N               VM CPU cores (default: $VM_CORES)
  --memory-mb MB          VM memory in MiB (default: $VM_MEMORY_MB)
  --qemu-bin PATH         QEMU binary to exec (default: auto-detect by arch)

Environment variables:
  GUIX_VERSION, VM_CORES, VM_MEMORY_MB, QEMU_BIN
EOF
}

while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --guix-version)
      shift
      GUIX_VERSION="${1:?missing value for --guix-version}"
      ;;
    --cores)
      shift
      VM_CORES="${1:?missing value for --cores}"
      ;;
    --memory-mb)
      shift
      VM_MEMORY_MB="${1:?missing value for --memory-mb}"
      ;;
    --qemu-bin)
      shift
      QEMU_BIN="${1:?missing value for --qemu-bin}"
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

arch="$(uname -m)"
case "$arch" in
  x86_64)
    qemu_bin="${QEMU_BIN:-qemu-system-x86_64}"
    vm_image="guix-system-vm-image-${GUIX_VERSION}.x86_64-linux.qcow2"
    ;;
  arm64)
    qemu_bin="${QEMU_BIN:-qemu-system-x86_64}"
    vm_image="guix-system-vm-image-${GUIX_VERSION}.x86_64-linux.qcow2"
    ;;
  *)
    echo "Unsupported macOS architecture: $arch" >&2
    exit 1
    ;;
esac

require_command brew
require_command curl

brew_prefix="$(brew --prefix)"
case "${arch}:${brew_prefix}" in
  arm64:/opt/homebrew|x86_64:/usr/local)
    ;;
  *)
    echo "Warning: Homebrew prefix '$brew_prefix' does not match '$arch'; use the matching Homebrew for this shell" >&2
    ;;
esac

if ! command -v "$qemu_bin" >/dev/null 2>&1; then
  if ! brew_formula_available ninja; then
    die "Homebrew formula 'ninja' is unavailable; run 'brew update' and retry"
  fi

  if ! brew_formula_available qemu; then
    die "Homebrew formula 'qemu' is unavailable; run 'brew update' and retry"
  fi

  echo "Installing ninja and qemu with Homebrew..." >&2
  brew install ninja qemu
fi

if ! command -v "$qemu_bin" >/dev/null 2>&1; then
  die "QEMU binary '$qemu_bin' is still unavailable; check Homebrew PATH and retry"
fi

if [[ ! -f "$vm_image" ]]; then
  echo "Downloading ${vm_image}..." >&2
  curl -LO "https://ftp.gnu.org/gnu/guix/${vm_image}"
fi

qemu_args=(
  -smp "cores=${VM_CORES}"
  -m "$VM_MEMORY_MB"
  -net user
  -net nic,model=virtio
  -drive "file=${vm_image},format=qcow2"
)

if [[ "$arch" == "arm64" ]]; then
  qemu_args=(-accel tcg "${qemu_args[@]}")
fi

exec "$qemu_bin" "${qemu_args[@]}"
