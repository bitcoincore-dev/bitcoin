#!/usr/bin/env bash
set -euo pipefail

ENGINE="${GUIX_CONTAINER_ENGINE:-auto}"
IMAGE="${GUIX_CONTAINER_IMAGE:-alpine_guix}"
IMAGE_CONTEXT="${GUIX_CONTAINER_IMAGE_CONTEXT:-}"
IMAGEFILE_URL="${GUIX_CONTAINER_IMAGEFILE_URL:-https://raw.githubusercontent.com/fanquake/core-review/master/guix/imagefile}"
CONTAINER_NAME="${GUIX_CONTAINER_NAME:-guix-macos}"
REPO_PATH="${GUIX_CONTAINER_REPO_PATH:-$PWD}"
WORKDIR="${GUIX_CONTAINER_WORKDIR:-/bitcoin}"
BUILD_TARGET="${GUIX_CONTAINER_BUILD_TARGET:-}"
BUILD_NO_CACHE="${GUIX_CONTAINER_BUILD_NO_CACHE:-1}"
BUILD_PULL="${GUIX_CONTAINER_BUILD_PULL:-1}"
AUTO_BUILD_IMAGE="${GUIX_CONTAINER_AUTO_BUILD_IMAGE:-1}"
GUIX_DOWNLOAD_PATH="${GUIX_CONTAINER_GUIX_DOWNLOAD_PATH:-https://ftp.gnu.org/gnu/guix}"
SDK_PATH="${GUIX_CONTAINER_SDK_PATH:-}"
SDK_TARBALL="${GUIX_CONTAINER_SDK_TARBALL:-}"
AUTO_IMAGE_CONTEXT=""
ENV_FORWARD=()
MOUNT_ARGS=()
SDK_TEMP_DIR=""
SDK_MOUNT_ROOT=""
DOCKER_HOST_SHARE_ROOT="${DOCKER_HOST_SHARE_ROOT:-$HOME/macOS-SDKs}"

dir_has_entries() {
  local dir="$1"
  [[ -d "$dir" ]] && find "$dir" -mindepth 1 -maxdepth 1 | grep -q .
}

usage() {
  cat <<EOF
Usage: guix-container-macos.sh [OPTIONS] [COMMAND...]

Run the Guix container image on macOS with Docker or Podman.

If COMMAND is omitted, an interactive shell is started inside the container.
Pass '--' before COMMAND arguments if the command itself accepts flags.

Options:
  -h, --help        Show this help and exit
  --engine NAME     Container engine: auto, docker, or podman
  --image IMAGE     Container image to run (default: $IMAGE)
  --image-context PATH  Build context for the image when auto-building
  --imagefile-url URL   imagefile URL to fetch when auto-building (default: $IMAGEFILE_URL)
  --name NAME       Container name (default: $CONTAINER_NAME)
  --repo-path PATH  Host repo path to mount (default: $REPO_PATH)
  --workdir PATH    Container workdir / mount point (default: $WORKDIR)
  --stop            Stop the container and exit
  --no-auto-build   Do not build the image if it is missing
  --build-target T  Build target to pass to the image build
  --build-allow-cache  Allow cache when building the image
  --guix-download-path URL  Guix binary mirror used during image build
  --sdk-path PATH   Mount an extracted macOS SDK directory into the container
  --sdk-tarball FILE Extract an SDK tarball into a temp dir and mount it

Examples:
  ./scripts/guix-container-macos.sh
  ./scripts/guix-container-macos.sh ./contrib/guix/guix-build
  ./scripts/guix-container-macos.sh --image-context /path/to/guix ./contrib/guix/guix-build

Note:
  ./contrib/guix/guix-build checks for a clean worktree before parsing its own
  help flags, so '... guix-build -h' will still fail on a dirty repo unless you
  export FORCE_DIRTY_WORKTREE=1 or run it from a clean tree.

Environment variables:
  GUIX_CONTAINER_ENGINE, GUIX_CONTAINER_IMAGE, GUIX_CONTAINER_NAME,
  GUIX_CONTAINER_REPO_PATH, GUIX_CONTAINER_WORKDIR, GUIX_CONTAINER_IMAGE_CONTEXT,
  GUIX_CONTAINER_IMAGEFILE_URL, GUIX_CONTAINER_BUILD_TARGET, GUIX_CONTAINER_BUILD_NO_CACHE,
  GUIX_CONTAINER_BUILD_PULL, GUIX_CONTAINER_AUTO_BUILD_IMAGE, GUIX_CONTAINER_GUIX_DOWNLOAD_PATH,
  GUIX_CONTAINER_SDK_PATH, GUIX_CONTAINER_SDK_TARBALL, DOCKER_HOST_SHARE_ROOT
EOF
}

stop_container() {
  local engine="$1"
  if "$engine" ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    "$engine" stop "$CONTAINER_NAME" >/dev/null
  fi
}

resolve_engine() {
  case "$ENGINE" in
    auto)
      if command -v docker >/dev/null 2>&1; then
        ENGINE=docker
      elif command -v podman >/dev/null 2>&1; then
        ENGINE=podman
      else
        echo "Need docker or podman on PATH" >&2
        exit 1
      fi
      ;;
    docker|podman)
      if ! command -v "$ENGINE" >/dev/null 2>&1; then
        echo "Missing container engine: $ENGINE" >&2
        exit 1
      fi
      ;;
    *)
      echo "Unknown engine: $ENGINE" >&2
      exit 1
      ;;
  esac

  if [[ "$ENGINE" == podman ]]; then
    podman machine start >/dev/null 2>&1 || true
  fi
}

populate_env_forward() {
  local var
  for var in FORCE_DIRTY_WORKTREE GUIX_BUILD_OPTIONS SOURCE_DATE_EPOCH HOSTS JOBS ADDITIONAL_GUIX_COMMON_FLAGS ADDITIONAL_GUIX_BUILD_FLAGS BASE_CACHE SOURCES_PATH SDK_PATH; do
    if [[ ${!var-} != "" ]]; then
      ENV_FORWARD+=(-e "${var}=${!var}")
    fi
  done
}

prepare_sdk_mount() {
  if [[ -n "$SDK_TARBALL" ]]; then
    SDK_TARBALL="$(cd "$(dirname "$SDK_TARBALL")" && pwd -P)/$(basename "$SDK_TARBALL")"
    if [[ ! -f "$SDK_TARBALL" ]]; then
      echo "Missing SDK tarball: $SDK_TARBALL" >&2
      exit 1
    fi
    SDK_TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/guix-sdk.XXXXXX")"
    trap 'rm -rf "$SDK_TEMP_DIR"' EXIT
    tar -C "$SDK_TEMP_DIR" -xf "$SDK_TARBALL"
    SDK_PATH="$SDK_TEMP_DIR"
    echo "Using SDK tarball: $SDK_TARBALL" >&2
  elif [[ -z "$SDK_PATH" ]]; then
    local xcode_app xcode_version xcode_build_id extracted_name sdk_tarball candidate
    if [[ "$(uname -s)" == Darwin ]] && command -v xcodebuild >/dev/null 2>&1; then
      xcode_app="$(cd "$(dirname "$(dirname "$(xcode-select -p)")")" && pwd -P)"
      if [[ -d "$xcode_app" ]]; then
        xcode_version="$(xcodebuild -version | awk '/^Xcode / {print $2; exit}')"
        xcode_build_id="$(xcodebuild -version | awk '/^Build version / {print $3; exit}')"
        extracted_name="Xcode-${xcode_version}-${xcode_build_id}-extracted-SDK-with-libcxx-headers"
        SDK_MOUNT_ROOT="$DOCKER_HOST_SHARE_ROOT"
        mkdir -p "$SDK_MOUNT_ROOT"
        if [[ ! -d "$SDK_MOUNT_ROOT/$extracted_name" ]]; then
          sdk_tarball="$SDK_MOUNT_ROOT/${extracted_name}.tar"
          python3 "$(dirname "${BASH_SOURCE[0]}")/../contrib/macdeploy/gen-sdk.py" "$xcode_app" -o "$sdk_tarball"
          tar -C "$SDK_MOUNT_ROOT" -xf "$sdk_tarball"
          rm -f "$sdk_tarball"
        fi
        MOUNT_ARGS+=(-v "${SDK_MOUNT_ROOT}:${SDK_MOUNT_ROOT}:ro")
        SDK_PATH="$SDK_MOUNT_ROOT"
        echo "Using system Xcode SDK: $xcode_app -> $SDK_MOUNT_ROOT/$extracted_name" >&2
      fi
    fi

    if [[ -z "$SDK_PATH" ]]; then
      for candidate in \
        "$REPO_PATH/depends/SDKs" \
        "$HOME/macOS-SDKs" \
        "$HOME/Downloads/macOS-SDKs" \
        "/Users/Shared/macOS-SDKs"
      do
        if dir_has_entries "$candidate"; then
          SDK_PATH="$candidate"
          echo "Using SDK path: $SDK_PATH" >&2
          break
        fi
      done
    fi
  fi

  if [[ -n "$SDK_PATH" ]]; then
    SDK_PATH="$(cd "$SDK_PATH" && pwd -P)"
    if [[ ! -d "$SDK_PATH" ]]; then
      echo "Missing SDK path: $SDK_PATH" >&2
      exit 1
    fi
    ENV_FORWARD+=(-e "SDK_PATH=${SDK_PATH}")
    MOUNT_ARGS+=(-v "${SDK_PATH}:${SDK_PATH}:ro")
  fi
}

start_docker_daemon() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$(uname -s)" != Darwin ]]; then
    return 1
  fi

  if command -v open >/dev/null 2>&1; then
    open -ga Docker >/dev/null 2>&1 || open -a Docker >/dev/null 2>&1 || true
  fi

  for _ in $(seq 1 60); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  return 1
}

container_running() {
  "$ENGINE" ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"
}

container_exists() {
  "$ENGINE" ps -a --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"
}

run_container() {
  "$ENGINE" run -d \
    --name "$CONTAINER_NAME" \
    --privileged \
    "${ENV_FORWARD[@]}" \
    -v "${REPO_PATH}:${WORKDIR}" \
    "${MOUNT_ARGS[@]}" \
    -w "$WORKDIR" \
    "$IMAGE" >/dev/null
}

while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --engine)
      shift
      ENGINE="${1:?missing value for --engine}"
      ;;
    --image)
      shift
      IMAGE="${1:?missing value for --image}"
      ;;
    --image-context)
      shift
      IMAGE_CONTEXT="${1:?missing value for --image-context}"
      ;;
    --imagefile-url)
      shift
      IMAGEFILE_URL="${1:?missing value for --imagefile-url}"
      ;;
    --name)
      shift
      CONTAINER_NAME="${1:?missing value for --name}"
      ;;
    --repo-path)
      shift
      REPO_PATH="${1:?missing value for --repo-path}"
      ;;
    --workdir)
      shift
      WORKDIR="${1:?missing value for --workdir}"
      ;;
    --stop)
      shift
      resolve_engine
      stop_container "$ENGINE"
      exit 0
      ;;
    --no-auto-build)
      AUTO_BUILD_IMAGE=0
      ;;
    --build-target)
      shift
      BUILD_TARGET="${1:?missing value for --build-target}"
      ;;
    --build-allow-cache)
      BUILD_NO_CACHE=0
      ;;
    --guix-download-path)
      shift
      GUIX_DOWNLOAD_PATH="${1:?missing value for --guix-download-path}"
      ;;
    --sdk-path)
      shift
      SDK_PATH="${1:?missing value for --sdk-path}"
      ;;
    --sdk-tarball)
      shift
      SDK_TARBALL="${1:?missing value for --sdk-tarball}"
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
  shift
done

resolve_engine

REPO_PATH="$(cd "$REPO_PATH" && pwd -P)"
prepare_sdk_mount
populate_env_forward

if [[ "$ENGINE" == docker ]]; then
  if ! start_docker_daemon; then
    echo "Docker daemon is not available. Start Docker Desktop and rerun this script." >&2
    exit 1
  fi
fi

build_image() {
  local build_context="$1"
  local build_args=()

  if [[ "$BUILD_PULL" == 1 ]]; then
    build_args+=(--pull)
  fi
  if [[ "$BUILD_NO_CACHE" == 1 ]]; then
    build_args+=(--no-cache)
  fi
  if [[ -n "$BUILD_TARGET" ]]; then
    build_args+=(--target "$BUILD_TARGET")
  fi
  if [[ -n "$GUIX_DOWNLOAD_PATH" ]]; then
    build_args+=(--build-arg "guix_download_path=${GUIX_DOWNLOAD_PATH}")
  fi

  "$ENGINE" build "${build_args[@]}" -t "$IMAGE" -f "$build_context/imagefile" "$build_context"
}

prepare_image_context() {
  local context="$1"
  if [[ -n "$context" ]]; then
    context="$(cd "$context" && pwd -P)"
    if [[ ! -f "$context/imagefile" ]]; then
      echo "Missing image context: expected ${context}/imagefile" >&2
      exit 1
    fi
    AUTO_IMAGE_CONTEXT="$context"
    return
  fi

  AUTO_IMAGE_CONTEXT="$(mktemp -d "${TMPDIR:-/tmp}/guix-image-context.XXXXXX")"
  trap 'rm -rf "$AUTO_IMAGE_CONTEXT"' EXIT
  curl -fsSL "$IMAGEFILE_URL" -o "$AUTO_IMAGE_CONTEXT/imagefile"
}

if ! "$ENGINE" image inspect "$IMAGE" >/dev/null 2>&1; then
  if [[ "$AUTO_BUILD_IMAGE" != 1 ]]; then
    cat >&2 <<EOF
Missing image: $IMAGE

Build or load the Guix container image first, then rerun this script.
EOF
    exit 1
  fi

  prepare_image_context "$IMAGE_CONTEXT"
  build_image "$AUTO_IMAGE_CONTEXT"
fi

if container_running; then
  if [[ -n "$SDK_PATH" ]]; then
    echo "Container '$CONTAINER_NAME' is already running; stop it and rerun to apply SDK mounts." >&2
    exit 1
  fi
elif container_exists; then
  if [[ -n "$SDK_PATH" ]]; then
    "$ENGINE" rm "$CONTAINER_NAME" >/dev/null
    run_container
  else
    "$ENGINE" start "$CONTAINER_NAME" >/dev/null
  fi
else
  run_container
fi

if (($# == 0)); then
  set -- /bin/bash
fi

exec "$ENGINE" exec -it "${ENV_FORWARD[@]}" "$CONTAINER_NAME" "$@"
