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
AUTO_IMAGE_CONTEXT=""

usage() {
  cat <<EOF
Usage: guix-container-macos.sh [OPTIONS] [COMMAND...]

Run the Guix container image on macOS with Docker or Podman.

If COMMAND is omitted, an interactive shell is started inside the container.

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

Environment variables:
  GUIX_CONTAINER_ENGINE, GUIX_CONTAINER_IMAGE, GUIX_CONTAINER_NAME,
  GUIX_CONTAINER_REPO_PATH, GUIX_CONTAINER_WORKDIR, GUIX_CONTAINER_IMAGE_CONTEXT,
  GUIX_CONTAINER_IMAGEFILE_URL, GUIX_CONTAINER_BUILD_TARGET, GUIX_CONTAINER_BUILD_NO_CACHE,
  GUIX_CONTAINER_BUILD_PULL, GUIX_CONTAINER_AUTO_BUILD_IMAGE, GUIX_CONTAINER_GUIX_DOWNLOAD_PATH
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
  :
elif container_exists; then
  "$ENGINE" start "$CONTAINER_NAME" >/dev/null
else
  "$ENGINE" run -d \
    --name "$CONTAINER_NAME" \
    --privileged \
    -v "${REPO_PATH}:${WORKDIR}" \
    -w "$WORKDIR" \
    "$IMAGE" >/dev/null
fi

if (($# == 0)); then
  set -- /bin/bash
fi

exec "$ENGINE" exec -it "$CONTAINER_NAME" "$@"
