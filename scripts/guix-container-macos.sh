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
DOCKER_HOST_SHARE_ROOT="${DOCKER_HOST_SHARE_ROOT:-$HOME/macOS-SDKs}"
SDK_PATH="${GUIX_CONTAINER_SDK_PATH:-}"
SDK_TARBALL="${GUIX_CONTAINER_SDK_TARBALL:-}"
SDK_URL="${GUIX_CONTAINER_SDK_URL:-https://bitcoincore.org/depends-sources/sdks}"
XCODE_VERSION="${GUIX_CONTAINER_XCODE_VERSION:-26.1.1}"
XCODE_BUILD_ID="${GUIX_CONTAINER_XCODE_BUILD_ID:-17B100}"
SDK_REPO_PATH="${GUIX_CONTAINER_SDK_REPO_PATH:-$DOCKER_HOST_SHARE_ROOT/MacOSX-SDKs}"
SDK_REPO_URL="${GUIX_CONTAINER_SDK_REPO_URL:-git@github.com:bitcoincore-dev/MacOSX-SDKs.git}"
GUIX_SIGS_REPO="${GUIX_CONTAINER_GUIX_SIGS_REPO:-}"
SIGNER="${GUIX_CONTAINER_SIGNER:-}"
RELEASE_STYLE="${GUIX_CONTAINER_RELEASE_STYLE:-0}"
GUIX_SIGS_CONTAINER_PATH="/bitcoin/guix.sigs"
GNUPGHOME="${GUIX_CONTAINER_GNUPGHOME:-$HOME/.gnupg}"
AUTO_IMAGE_CONTEXT=""
ENV_FORWARD=()
MOUNT_ARGS=()
SDK_TEMP_DIR=""
SDK_MOUNT_ROOT=""

dir_has_entries() {
  local dir="$1"
  [[ -d "$dir" ]] && find "$dir" -mindepth 1 -maxdepth 1 | grep -q .
}

print_release_style_help() {
  cat <<EOF >&2
Release-style follow-up commands:
  if [ -f contrib/shell/git-utils.bash ]; then
    source contrib/shell/git-utils.bash
  fi
  uname -m
  build_dir="\$(find . -maxdepth 2 -type d -path './guix-build-*/output' | head -n1)"
  find "\$build_dir" -type f -print0 | env LC_ALL=C sort -z | xargs -r0 sha256sum
  env GUIX_SIGS_REPO=${GUIX_SIGS_CONTAINER_PATH} SIGNER=${SIGNER} ./contrib/guix/guix-attest
  git -C ${GUIX_SIGS_CONTAINER_PATH} pull
  env GUIX_SIGS_REPO=${GUIX_SIGS_CONTAINER_PATH} ./contrib/guix/guix-verify
EOF
}

choose_default_hosts() {
  if [[ -n "${HOSTS:-}" ]]; then
    return
  fi

  local avail_kib
  avail_kib="$(df -Pk "$REPO_PATH" | awk 'NR==2 {print $4}')"
  if [[ -n "$avail_kib" ]] && (( avail_kib < 16777216 )); then
    HOSTS="x86_64-apple-darwin arm64-apple-darwin"
    echo "Low disk space detected; defaulting HOSTS='$HOSTS'" >&2
  fi
}

validate_release_style_args() {
  if [[ "$RELEASE_STYLE" == 1 ]]; then
    if [[ -z "$GUIX_SIGS_REPO" || -z "$SIGNER" ]]; then
      echo "Release style requires --guix-sigs-repo and --signer" >&2
      exit 1
    fi
  fi
}

prepare_guix_sigs_mount() {
  if [[ -z "$GUIX_SIGS_REPO" ]]; then
    return
  fi

  GUIX_SIGS_REPO="$(cd "$GUIX_SIGS_REPO" && pwd -P)"
  if [[ ! -d "$GUIX_SIGS_REPO" ]]; then
    echo "Missing guix.sigs repo: $GUIX_SIGS_REPO" >&2
    exit 1
  fi

  MOUNT_ARGS+=(-v "${GUIX_SIGS_REPO}:${GUIX_SIGS_CONTAINER_PATH}")
  ENV_FORWARD+=(-e "GUIX_SIGS_REPO=${GUIX_SIGS_CONTAINER_PATH}")
}

prepare_gnupg_mount() {
  if [[ "$RELEASE_STYLE" != 1 ]]; then
    return
  fi

  GNUPGHOME="$(cd "$GNUPGHOME" && pwd -P)"
  if [[ ! -d "$GNUPGHOME" ]]; then
    echo "Missing GNUPG home: $GNUPGHOME" >&2
    exit 1
  fi

  MOUNT_ARGS+=(-v "${GNUPGHOME}:${GNUPGHOME}")
  ENV_FORWARD+=(-e "GNUPGHOME=${GNUPGHOME}")
}

resolve_signer_key() {
  if [[ "$RELEASE_STYLE" != 1 || -z "$SIGNER" ]]; then
    return
  fi

  local signer_name="$SIGNER"
  if [[ "$SIGNER" == *"="* ]]; then
    signer_name="${SIGNER#*=}"
    SIGNER="${SIGNER%%=*}"
  fi

  if gpg --homedir "$GNUPGHOME" --list-secret-keys --keyid-format LONG "$SIGNER" >/dev/null 2>&1; then
    SIGNER="${SIGNER}=${signer_name}"
    return
  fi

  local resolved=""
  local current_fpr=""
  local line
  while IFS= read -r line; do
    case "$line" in
      sec\ *)
        current_fpr=""
        ;;
      [[:space:]]*[0-9A-F][0-9A-F]*)
        if [[ -n "$current_fpr" ]]; then
          continue
        fi
        current_fpr="${line//[[:space:]]/}"
        ;;
      uid\ *|[[:space:]]uid\ *)
        if [[ -n "$current_fpr" ]] && [[ "${line,,}" == *"${SIGNER,,}"* ]]; then
          resolved="$current_fpr"
          break
        fi
        ;;
    esac
  done < <(gpg --homedir "$GNUPGHOME" --list-secret-keys --keyid-format LONG 2>/dev/null)

  if [[ -n "$resolved" ]]; then
    echo "Resolved signer '$SIGNER' to fingerprint '$resolved'" >&2
    SIGNER="${resolved}=${signer_name}"
    return
  fi

  echo "GPG can't seem to find any secret key matching '$SIGNER' in '$GNUPGHOME'" >&2
  echo "Available secret keys:" >&2
  gpg --homedir "$GNUPGHOME" --list-secret-keys --keyid-format LONG >&2 || true
  exit 1
}

ensure_release_style_tools() {
  if [[ "$RELEASE_STYLE" != 1 ]]; then
    return
  fi

  if "$ENGINE" exec "$CONTAINER_NAME" sh -lc 'command -v gpg >/dev/null 2>&1'; then
    return
  fi

  if "$ENGINE" exec "$CONTAINER_NAME" sh -lc 'command -v apk >/dev/null 2>&1'; then
    echo "Installing gnupg in container..." >&2
    "$ENGINE" exec "$CONTAINER_NAME" sh -lc 'apk add --no-cache gnupg >/dev/null'
    return
  fi

  echo "Release style requires gpg, but no package manager was found in the container" >&2
  exit 1
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
  --sdk-url URL     Download extracted SDK tarballs from this URL
  --xcode-version V  SDK version to fetch (default: $XCODE_VERSION)
  --xcode-build-id B  SDK build id to fetch (default: $XCODE_BUILD_ID)
  --sdk-repo-path PATH  Clone or use an SDK repo checkout at PATH
  --sdk-repo-url URL    Git URL for the SDK repo (default: $SDK_REPO_URL)
  --release-style      Print post-build release steps
  --guix-sigs-repo PATH  Path to guix.sigs for attest/verify
  --signer NAME       GPG key name for guix-attest
  --gnupg-home PATH   Mount host GnuPG home into the container (default: $GNUPGHOME)

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
  GUIX_CONTAINER_SDK_PATH, GUIX_CONTAINER_SDK_TARBALL, GUIX_CONTAINER_SDK_URL,
  GUIX_CONTAINER_XCODE_VERSION, GUIX_CONTAINER_XCODE_BUILD_ID,
  GUIX_CONTAINER_SDK_REPO_PATH, GUIX_CONTAINER_SDK_REPO_URL, DOCKER_HOST_SHARE_ROOT,
  GUIX_CONTAINER_GUIX_SIGS_REPO, GUIX_CONTAINER_SIGNER, GUIX_CONTAINER_RELEASE_STYLE,
  GUIX_CONTAINER_GNUPGHOME
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
  fi

  if [[ -z "$SDK_PATH" ]]; then
    local extracted_name candidate sdk_tarball repo_extracted
    extracted_name="Xcode-${XCODE_VERSION}-${XCODE_BUILD_ID}-extracted-SDK-with-libcxx-headers"

    for candidate in \
      "$REPO_PATH/depends/SDKs/$extracted_name" \
      "$DOCKER_HOST_SHARE_ROOT/$extracted_name" \
      "$HOME/Downloads/macOS-SDKs/$extracted_name"
    do
      if [[ -d "$candidate" ]]; then
        SDK_PATH="$(dirname "$candidate")"
        echo "Using extracted SDK directory: $candidate" >&2
        break
      fi
    done
  fi

  if [[ -z "$SDK_PATH" ]]; then
    local extracted_name repo_extracted sdk_tarball
    extracted_name="Xcode-${XCODE_VERSION}-${XCODE_BUILD_ID}-extracted-SDK-with-libcxx-headers"

    if [[ -d "$SDK_REPO_PATH/$extracted_name" ]]; then
      SDK_PATH="$SDK_REPO_PATH"
      echo "Using SDK repo checkout: $SDK_PATH/$extracted_name" >&2
    elif [[ ! -d "$SDK_REPO_PATH" ]]; then
      mkdir -p "$(dirname "$SDK_REPO_PATH")"
      if command -v git >/dev/null 2>&1; then
        git clone --depth 1 "$SDK_REPO_URL" "$SDK_REPO_PATH" >&2
      else
        echo "git is required to clone SDK repo $SDK_REPO_URL" >&2
        exit 1
      fi
    fi
    if [[ -z "$SDK_PATH" ]]; then
      sdk_tarball="$DOCKER_HOST_SHARE_ROOT/${extracted_name}.tar"
      mkdir -p "$DOCKER_HOST_SHARE_ROOT"
      if [[ ! -f "$sdk_tarball" ]]; then
        curl -fsSL "${SDK_URL}/${extracted_name}.tar" -o "$sdk_tarball"
      fi
      if [[ ! -d "$DOCKER_HOST_SHARE_ROOT/$extracted_name" ]]; then
        tar -C "$DOCKER_HOST_SHARE_ROOT" -xf "$sdk_tarball"
      fi
      SDK_PATH="$DOCKER_HOST_SHARE_ROOT"
      echo "Using downloaded SDK tarball: $sdk_tarball" >&2
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

  if ! pgrep -f 'com\.docker\.(vmnetd|backend)|Docker Desktop|Docker\.app' >/dev/null 2>&1; then
    if command -v open >/dev/null 2>&1; then
      open -gj -a "Docker Desktop" >/dev/null 2>&1 || true
      open -gj -a Docker >/dev/null 2>&1 || true
    fi
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

remove_container() {
  "$ENGINE" rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
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
    --sdk-url)
      shift
      SDK_URL="${1:?missing value for --sdk-url}"
      ;;
    --xcode-version)
      shift
      XCODE_VERSION="${1:?missing value for --xcode-version}"
      ;;
    --xcode-build-id)
      shift
      XCODE_BUILD_ID="${1:?missing value for --xcode-build-id}"
      ;;
    --sdk-repo-path)
      shift
      SDK_REPO_PATH="${1:?missing value for --sdk-repo-path}"
      ;;
    --sdk-repo-url)
      shift
      SDK_REPO_URL="${1:?missing value for --sdk-repo-url}"
      ;;
    --release-style)
      RELEASE_STYLE=1
      ;;
    --guix-sigs-repo)
      shift
      GUIX_SIGS_REPO="${1:?missing value for --guix-sigs-repo}"
      ;;
    --signer)
      shift
      SIGNER="${1:?missing value for --signer}"
      ;;
    --gnupg-home)
      shift
      GNUPGHOME="${1:?missing value for --gnupg-home}"
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
choose_default_hosts
validate_release_style_args
prepare_guix_sigs_mount
prepare_gnupg_mount
resolve_signer_key
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
  remove_container
  run_container
elif container_exists; then
  remove_container
  run_container
else
  run_container
fi

if (($# == 0)); then
  set -- /bin/bash
fi

if [[ "$RELEASE_STYLE" == 1 ]]; then
  ensure_release_style_tools
  print_release_style_help
fi

exec "$ENGINE" exec -it "${ENV_FORWARD[@]}" "$CONTAINER_NAME" "$@"
