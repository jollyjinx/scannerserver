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

if [ -z "${TAG}" ]; then
  echo "error: tag must not be empty" >&2
  exit 2
fi

cd "${REPO_ROOT}"

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
  if grep -qi "Structure needs cleaning" "${BUILD_LOG}"; then
    cat >&2 <<EOF

The Docker builder filesystem looks corrupt.
Repair it, then rerun this script:

  docker buildx prune --all --force
  docker builder prune --all --force
  $0 ${TAG}

EOF
  fi
  exit 1
fi

echo "Done: ${IMAGE_REF} (${PLATFORMS})"
