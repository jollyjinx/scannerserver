#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

IMAGE="${IMAGE:-ghcr.io/jollyjinx/scannerserver}"
TAG="${TAG:-development-arm64}"
PLATFORM="${PLATFORM:-linux/arm64}"
DOCKER="${DOCKER:-docker}"

cd "${REPO_ROOT}"

if ! command -v "${DOCKER}" >/dev/null 2>&1; then
  echo "error: '${DOCKER}' command not found" >&2
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

echo "Building ${IMAGE_REF}"
echo "Platform: ${PLATFORM}"
echo "VCS_REF: ${COMMIT}"

build_image() {
  "${DOCKER}" buildx build \
    --platform "${PLATFORM}" \
    --build-arg "VCS_REF=${COMMIT}" \
    -t "${IMAGE_REF}" \
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
  $0

EOF
  fi
  exit 1
fi

echo "Done: ${IMAGE_REF}"
