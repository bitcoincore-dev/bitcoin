#!/usr/bin/env bash
set -euo pipefail

GUIX_VERSION="${GUIX_VERSION:-1.4.0}"
VM_CORES="${VM_CORES:-4}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
QEMU_BIN="${QEMU_BIN:-}"
QEMU_DISPLAY="${QEMU_DISPLAY:-cocoa}"
QEMU_FULLSCREEN="${QEMU_FULLSCREEN:-0}"
QEMU_VGA="${QEMU_VGA:-virtio}"
QEMU_WINDOW_SIZE="${QEMU_WINDOW_SIZE:-}"
QEMU_OSASCRIPT_FULLSCREEN="${QEMU_OSASCRIPT_FULLSCREEN:-0}"
QEMU_OSASCRIPT_PROCESS="${QEMU_OSASCRIPT_PROCESS:-}"
QEMU_OSASCRIPT_ZOOM_TO_FIT="${QEMU_OSASCRIPT_ZOOM_TO_FIT:-0}"
QEMU_SHARE_REPO="${QEMU_SHARE_REPO:-0}"
QEMU_SHARE_PATH="${QEMU_SHARE_PATH:-}"
QEMU_SHARE_MOUNT_TAG="${QEMU_SHARE_MOUNT_TAG:-repo}"
QEMU_SHARE_READONLY="${QEMU_SHARE_READONLY:-1}"
QEMU_SSH_FORWARD="${QEMU_SSH_FORWARD:-0}"
QEMU_SSH_PORT="${QEMU_SSH_PORT:-2222}"

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
  --display NAME          QEMU display backend (default: $QEMU_DISPLAY)
  --fullscreen            Start QEMU fullscreen
  --vga TYPE              QEMU VGA device (default: $QEMU_VGA)
  --window-size WxH       Resize the QEMU window after launch using osascript
  --osascript-fullscreen  Toggle macOS fullscreen after launch using osascript
  --osascript-process P   Process/window name for osascript (default: auto-detect)
  --zoom-to-fit           Click View -> Zoom to Fit after launch
  --share-repo            Share the current directory into the guest over 9p
  --share-path PATH       Share a specific host directory instead of $PWD
  --share-mount-tag TAG   9p mount tag to use in the guest (default: $QEMU_SHARE_MOUNT_TAG)
  --share-rw              Share the repo read-write instead of read-only
  --ssh-forward           Forward host port to guest SSH port 22
  --ssh-port PORT         Host port to forward to guest SSH (default: $QEMU_SSH_PORT)

Environment variables:
  GUIX_VERSION, VM_CORES, VM_MEMORY_MB, QEMU_BIN, QEMU_DISPLAY, QEMU_FULLSCREEN, QEMU_VGA,
  QEMU_WINDOW_SIZE, QEMU_OSASCRIPT_FULLSCREEN, QEMU_OSASCRIPT_PROCESS, QEMU_OSASCRIPT_ZOOM_TO_FIT,
  QEMU_SHARE_REPO, QEMU_SHARE_PATH, QEMU_SHARE_MOUNT_TAG, QEMU_SHARE_READONLY,
  QEMU_SSH_FORWARD, QEMU_SSH_PORT
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
    --display)
      shift
      QEMU_DISPLAY="${1:?missing value for --display}"
      ;;
    --fullscreen)
      QEMU_FULLSCREEN=1
      ;;
    --vga)
      shift
      QEMU_VGA="${1:?missing value for --vga}"
      ;;
    --window-size)
      shift
      QEMU_WINDOW_SIZE="${1:?missing value for --window-size}"
      ;;
    --osascript-fullscreen)
      QEMU_OSASCRIPT_FULLSCREEN=1
      ;;
    --osascript-process)
      shift
      QEMU_OSASCRIPT_PROCESS="${1:?missing value for --osascript-process}"
      ;;
    --zoom-to-fit)
      QEMU_OSASCRIPT_ZOOM_TO_FIT=1
      ;;
    --share-repo)
      QEMU_SHARE_REPO=1
      ;;
    --share-path)
      shift
      QEMU_SHARE_PATH="${1:?missing value for --share-path}"
      ;;
    --share-mount-tag)
      shift
      QEMU_SHARE_MOUNT_TAG="${1:?missing value for --share-mount-tag}"
      ;;
    --share-rw)
      QEMU_SHARE_READONLY=0
      ;;
    --ssh-forward)
      QEMU_SSH_FORWARD=1
      ;;
    --ssh-port)
      shift
      QEMU_SSH_PORT="${1:?missing value for --ssh-port}"
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

qemu_args=(
  -smp "cores=${VM_CORES}"
  -m "$VM_MEMORY_MB"
  -vga "$QEMU_VGA"
  -drive "file=${vm_image},format=qcow2"
)

if [[ "$QEMU_SSH_FORWARD" == 1 ]]; then
  qemu_args+=(
    -netdev "user,id=net0,hostfwd=tcp::${QEMU_SSH_PORT}-:22"
    -device "virtio-net-pci,netdev=net0"
  )
else
  qemu_args+=(
    -net user
    -net nic,model=virtio
  )
fi

if [[ "$arch" == "arm64" ]]; then
  qemu_args=(-accel tcg "${qemu_args[@]}")
fi

display_arg="$QEMU_DISPLAY"
if [[ "$QEMU_FULLSCREEN" == 1 ]]; then
  display_arg="${display_arg},full-screen=on"
fi

qemu_args=(-display "$display_arg" "${qemu_args[@]}")

if [[ "$QEMU_SHARE_REPO" == 1 ]]; then
  share_repo_path="${QEMU_SHARE_PATH:-$PWD}"
  share_repo_path="$(cd "$share_repo_path" && pwd -P)"
  share_ro_opt=""
  if [[ "$QEMU_SHARE_READONLY" == 1 ]]; then
    share_ro_opt=",readonly=on"
  fi
  qemu_args+=(
    -fsdev "local,id=repo,path=${share_repo_path},security_model=none${share_ro_opt}"
    -device "virtio-9p-pci,fsdev=repo,mount_tag=${QEMU_SHARE_MOUNT_TAG}"
  )
fi

qemu_process_name="${QEMU_OSASCRIPT_PROCESS:-$(basename "$qemu_bin")}"

window_width=""
window_height=""
if [[ -n "$QEMU_WINDOW_SIZE" ]]; then
  case "$QEMU_WINDOW_SIZE" in
    *x*)
      window_width="${QEMU_WINDOW_SIZE%x*}"
      window_height="${QEMU_WINDOW_SIZE#*x}"
      ;;
    *)
      echo "Invalid --window-size value: $QEMU_WINDOW_SIZE (expected WxH)" >&2
      exit 1
      ;;
  esac
fi

resize_window() {
  local width="$1"
  local height="$2"
  osascript <<EOF
tell application "System Events"
  repeat until exists process "${qemu_process_name}"
    delay 0.2
  end repeat
  tell process "${qemu_process_name}"
    repeat until exists window 1
      delay 0.2
    end repeat
    set frontmost to true
    set size of window 1 to {${width}, ${height}}
  end tell
end tell
EOF
}

toggle_fullscreen() {
  osascript <<EOF
tell application "System Events"
  repeat until exists process "${qemu_process_name}"
    delay 0.2
  end repeat
  tell process "${qemu_process_name}"
    repeat until exists window 1
      delay 0.2
    end repeat
    set frontmost to true
    set value of attribute "AXFullScreen" of window 1 to true
  end tell
end tell
EOF
}

zoom_to_fit() {
  osascript <<EOF
tell application "System Events"
  repeat until exists process "${qemu_process_name}"
    delay 0.2
  end repeat
  tell process "${qemu_process_name}"
    repeat until exists window 1
      delay 0.2
    end repeat
    set frontmost to true
    click menu item "Zoom to Fit" of menu "View" of menu bar 1
  end tell
end tell
EOF
}

"$qemu_bin" "${qemu_args[@]}" &
qemu_pid=$!

if [[ "$QEMU_SHARE_REPO" == 1 ]]; then
  cat >&2 <<EOF
Shared repo enabled.
Inside the guest, mount it with:
  sudo mkdir -p /mnt/${QEMU_SHARE_MOUNT_TAG}
  sudo mount -t 9p -o trans=virtio,version=9p2000.L ${QEMU_SHARE_MOUNT_TAG} /mnt/${QEMU_SHARE_MOUNT_TAG}
EOF
fi

if [[ -n "$QEMU_WINDOW_SIZE" ]]; then
  resize_window "$window_width" "$window_height"
fi

if [[ "$QEMU_OSASCRIPT_FULLSCREEN" == 1 ]]; then
  toggle_fullscreen
fi

if [[ "$QEMU_OSASCRIPT_ZOOM_TO_FIT" == 1 ]]; then
  zoom_to_fit
fi

wait "$qemu_pid"
