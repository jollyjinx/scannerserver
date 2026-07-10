#!/usr/bin/env bash
set -euo pipefail

image="${1:-scannerserver-swift:development}"
port="${SCANNERSERVER_SMOKE_PORT:-18081}"
container_name="scannerserver-swift-smoke-$$"
scan_dir="$(mktemp -d)"
fake_bin="$(mktemp -d)"
fixture_name="2026-07-10.120000.pdf"
scan_name="2026-07-10.120001.pdf"
runtime="${CONTAINER_COMMAND:-container}"

cleanup() {
  "${runtime}" stop "${container_name}" >/dev/null 2>&1 || true
  "${runtime}" rm "${container_name}" >/dev/null 2>&1 || true
  rm -rf "${scan_dir}"
  rm -rf "${fake_bin}"
}
trap cleanup EXIT

cp "tests/fixtures/receipt-small-page.pdf" "${scan_dir}/${fixture_name}"
cat > "${fake_bin}/scanimage" <<'EOF'
#!/bin/sh
set -eu
output_pattern=""
for argument; do
  case "${argument}" in
    --batch=*) output_pattern=${argument#--batch=} ;;
  esac
done
test -n "${output_pattern}"
output=$(printf '%s' "${output_pattern}" | sed 's/%04d/0001/')
printf 'P6\n32 32\n255\n' > "${output}"
head -c 3072 /dev/zero >> "${output}"
EOF
chmod 0755 "${fake_bin}/scanimage"

"${runtime}" run \
  --detach \
  --name "${container_name}" \
  --publish "${port}:80" \
  --user "$(id -u):$(id -g)" \
  --env WEB_PORT=80 \
  --env SCAN_OUTPUT_DIR=/scans \
  --env SCAN_BACKEND=sane \
  --env SCAN_TIMESTAMP=2026-07-10.120001 \
  --env SCAN_REMOVE_BLANK_PAGES=false \
  --env SCAN_CROP_PAGES=false \
  --env SCAN_OCR_ENABLED=false \
  --env PATH=/smoke-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/scannerserver \
  --volume "${fake_bin}:/smoke-bin:ro" \
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

curl --fail --silent \
  --request POST \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data 'mode_id=duplex-pdf-no-ocr' \
  "http://127.0.0.1:${port}/scan" \
  --output /dev/null
for _ in $(seq 1 60); do
  if test -s "${scan_dir}/${scan_name}"; then
    break
  fi
  sleep 1
done
test -s "${scan_dir}/${scan_name}"
"${runtime}" exec "${container_name}" qpdf --check "/scans/${scan_name}" >/dev/null

"${runtime}" exec "${container_name}" sh -c 'touch /scans/.container-smoke && test -w /scans/.container-smoke'
"${runtime}" exec "${container_name}" sh -c '
  set -eu
  for command in scannerserver scansnap-wifi img2pdf ocrmypdf qpdf pdfimages pdfinfo vips exiftool; do
    command -v "$command" >/dev/null
  done
  test -x /usr/bin/scanimage
'

"${runtime}" run --rm \
  --user 12345:12345 \
  --env SCANNER_URL=http://192.0.2.10/eSCL \
  --entrypoint scansnap-entrypoint \
  "${image}" \
  sh -c 'test "$SANE_CONFIG_DIR" = /tmp/scannerserver-sane.d && test -s "$SANE_CONFIG_DIR/airscan.conf"'

"${runtime}" exec "${container_name}" grep -E '^(Name|VmRSS|VmHWM|Threads):' /proc/1/status
