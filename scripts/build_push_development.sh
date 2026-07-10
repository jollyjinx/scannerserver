#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

usage() {
  echo "Usage: $0 [tag]" >&2
}

if [ "$#" -gt 1 ]; then
  usage
  exit 2
fi

IMAGE="${IMAGE:-ghcr.io/jollyjinx/scannerserver}"
TAG="${1:-${TAG:-development}}"
PLATFORMS="linux/amd64,linux/arm64"
DOCKER="${DOCKER:-docker}"
MIN_FREE_GIB="${MIN_FREE_GIB:-10}"

if [ -z "${TAG}" ]; then
  echo "error: tag must not be empty" >&2
  exit 2
fi

case "${MIN_FREE_GIB}" in
  ''|*[!0-9]*)
    echo "error: MIN_FREE_GIB must be a non-negative integer" >&2
    exit 2
    ;;
esac

cd "${REPO_ROOT}"

AVAILABLE_KIB="$(df -Pk "${REPO_ROOT}" | awk 'NR == 2 { print $4 }')"
REQUIRED_KIB="$((MIN_FREE_GIB * 1024 * 1024))"
if [ -z "${AVAILABLE_KIB}" ] || [ "${AVAILABLE_KIB}" -lt "${REQUIRED_KIB}" ]; then
  AVAILABLE_GIB="$(( ${AVAILABLE_KIB:-0} / 1024 / 1024 ))"
  cat >&2 <<EOF
error: only approximately ${AVAILABLE_GIB} GiB is free on the build volume.
At least ${MIN_FREE_GIB} GiB is required for a dual-architecture build.
Free disk space, then rerun this script. Set MIN_FREE_GIB=0 only to bypass this check deliberately.
EOF
  exit 1
fi

if ! command -v "${DOCKER}" >/dev/null 2>&1; then
  echo "error: '${DOCKER}' command not found; multi-architecture publishing requires Docker Buildx" >&2
  exit 1
fi

if ! "${DOCKER}" buildx version >/dev/null 2>&1; then
  echo "error: '${DOCKER} buildx' is unavailable; multi-architecture publishing requires Docker Buildx" >&2
  exit 1
fi

COMMIT="${VCS_REF:-$(git rev-parse HEAD)}"
IMAGE_REF="${IMAGE}:${TAG}"

if ! git diff --quiet || ! git diff --cached --quiet; then
  if [ -z "${VCS_REF:-}" ]; then
    COMMIT="${COMMIT}-dirty"
  fi
  echo "warning: building from a dirty working tree; image version will be ${COMMIT}" >&2
fi

echo "Building and pushing ${IMAGE_REF}"
echo "Platforms: ${PLATFORMS}"
echo "VCS_REF: ${COMMIT}"

build_image() {
  "${DOCKER}" buildx build \
    --platform "${PLATFORMS}" \
    --build-arg "VCS_REF=${COMMIT}" \
    --tag "${IMAGE_REF}" \
    --push \
    .
}

BUILD_LOG="$(mktemp -t scannerserver-build.XXXXXX.log)"
trap 'rm -f "${BUILD_LOG}"' EXIT

if ! build_image 2>&1 | tee "${BUILD_LOG}"; then
  if grep -Eqi \
      "Structure needs cleaning|input/output error|disk I/O error|read-only file system|metadata_v2\\.db" \
      "${BUILD_LOG}"; then
    cat >&2 <<EOF

The Docker or BuildKit filesystem is unhealthy. This is not an image-tag error.

1. Confirm the host has at least ${MIN_FREE_GIB} GiB free:

  df -h "${REPO_ROOT}"

2. Restart Docker Desktop and remove the affected Buildx builder.

3. If Docker reports "UNEXPECTED INCONSISTENCY" or cannot start, back up Docker.raw
   and use Docker Desktop's supported recovery or Clean / Purge data workflow.

After Docker storage is healthy, rerun:

  $0 ${TAG}

EOF
  fi
  exit 1
fi

echo "Done: ${IMAGE_REF} (${PLATFORMS})"
