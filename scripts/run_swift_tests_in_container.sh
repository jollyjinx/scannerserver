#!/usr/bin/env bash
set -euo pipefail

runtime="${CONTAINER_COMMAND:-docker}"
image="${SWIFT_TEST_IMAGE:-swift:6.3.2-noble}"
container_name="scannerserver-swift-tests-$$"

cleanup() {
  "${runtime}" rm --force "${container_name}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${runtime}" run \
  --detach \
  --name "${container_name}" \
  "${image}" \
  sleep infinity >/dev/null

"${runtime}" exec "${container_name}" mkdir -p /workspace
"${runtime}" cp "${PWD}/." "${container_name}:/workspace"

"${runtime}" exec \
  --workdir /workspace \
  --env "SCANNERSERVER_REQUIRE_NATIVE_TOOL_TESTS=${SCANNERSERVER_REQUIRE_NATIVE_TOOL_TESTS:-}" \
  "${container_name}" \
  sh -c "
    set -eu
    sed -i 's/ noble-backports//g' /etc/apt/sources.list.d/ubuntu.sources
    sed -i 's|http://ports.ubuntu.com|https://ports.ubuntu.com|g' /etc/apt/sources.list.d/ubuntu.sources
    apt-get -o Acquire::Retries=5 update
    apt-get -o Acquire::Retries=5 install -y --no-install-recommends libvips-tools poppler-utils qpdf
    rm -rf /var/lib/apt/lists/*
    swift test --scratch-path /tmp/scannerserver-build
  "
