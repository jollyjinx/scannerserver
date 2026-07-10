#!/usr/bin/env bash
set -euo pipefail

image="${1:-scannerserver-swift:development}"
port="${SCANNERSERVER_SMOKE_PORT:-18081}"
container_name="scannerserver-swift-smoke-$$"
scan_dir="$(mktemp -d)"
fixture_name="2026-07-10.120000.pdf"

cleanup() {
  container stop "${container_name}" >/dev/null 2>&1 || true
  container rm "${container_name}" >/dev/null 2>&1 || true
  rm -rf "${scan_dir}"
}
trap cleanup EXIT

cp "tests/fixtures/receipt-small-page.pdf" "${scan_dir}/${fixture_name}"

container run \
  --detach \
  --name "${container_name}" \
  --publish "${port}:80" \
  --env WEB_PORT=80 \
  --env SCAN_OUTPUT_DIR=/scans \
  --env SCAN_BACKEND=sane \
  --volume "${scan_dir}:/scans" \
  "${image}" >/dev/null

for _ in $(seq 1 30); do
  if curl --fail --silent "http://127.0.0.1:${port}/health" >/dev/null; then
    break
  fi
  sleep 1
done

curl --fail --silent "http://127.0.0.1:${port}/health" | grep -qx "ok"
curl --fail --silent "http://127.0.0.1:${port}/" | grep -q '<h1>scannerserver</h1>'
curl --fail --silent \
  "http://127.0.0.1:${port}/files/${fixture_name}/preview" \
  --output "${scan_dir}/preview-response.jpg"

test "$(od -An -tx1 -N2 "${scan_dir}/preview-response.jpg" | tr -d '[:space:]')" = "ffd8"
test "$(wc -c < "${scan_dir}/preview-response.jpg" | tr -d '[:space:]')" -ne 2787
test -s "${scan_dir}/.previews/${fixture_name}.jpg"
container exec "${container_name}" sh -c 'touch /scans/.container-smoke && test -w /scans/.container-smoke'

container exec "${container_name}" grep -E '^(Name|VmRSS|VmHWM|Threads):' /proc/1/status
