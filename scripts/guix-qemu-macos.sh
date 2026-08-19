#!/usr/bin/env bash
set -euo pipefail

GUIX_VERSION="${GUIX_VERSION:-1.4.0}"
VM_CORES="${VM_CORES:-4}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"

arch="$(uname -m)"
case "$arch" in
  x86_64)
    qemu_bin="${QEMU_BIN:-qemu-system-x86_64}"
    vm_image="guix-system-vm-image-${GUIX_VERSION}.x86_64-linux.qcow2"
    ;;
  arm64)
    qemu_bin="${QEMU_BIN:-qemu-system-aarch64}"
    vm_image="guix-system-vm-image-${GUIX_VERSION}.aarch64-linux.qcow2"
    ;;
  *)
    echo "Unsupported macOS architecture: $arch" >&2
    exit 1
    ;;
esac

if ! command -v brew >/dev/null 2>&1; then
  echo "brew is required to install qemu on macOS" >&2
  exit 1
fi

if ! command -v "$qemu_bin" >/dev/null 2>&1; then
  echo "Installing qemu with Homebrew..." >&2
  brew install qemu
fi

if [[ ! -f "$vm_image" ]]; then
  echo "Downloading ${vm_image}..." >&2
  curl -LO "https://ftp.gnu.org/gnu/guix/${vm_image}"
fi

if [[ "$arch" == "arm64" ]]; then
  exec "$qemu_bin" \
    -machine virt,accel=hvf \
    -cpu host \
    -smp "cores=${VM_CORES}" \
    -m "$VM_MEMORY_MB" \
    -net user -net nic,model=virtio \
    "$vm_image"
else
  exec "$qemu_bin" \
    -smp "cores=${VM_CORES}" \
    -m "$VM_MEMORY_MB" \
    -net user -net nic,model=virtio \
    "$vm_image"
fi
