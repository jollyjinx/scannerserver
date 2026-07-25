#!/usr/bin/env bash
set -euo pipefail

image="${1:-scannerserver-swift:development}"
port="${SCANNERSERVER_SMOKE_PORT:-18081}"
container_name="scannerserver-swift-smoke-$$"
seed_container="${container_name}-seed"
scan_dir="$(mktemp -d)"
fake_bin="$(mktemp -d)"
fixture_name="2026-07-10.120000.pdf"
scan_name="2026-07-10.120001.pdf"
runtime="${CONTAINER_COMMAND:-container}"
use_docker_volumes="${SCANNERSERVER_SMOKE_USE_DOCKER_VOLUMES:-0}"
scan_volume=""
fake_bin_volume=""
scan_mount_source="${scan_dir}"
fake_bin_mount_source="${fake_bin}"

cleanup() {
  "${runtime}" rm --force "${seed_container}" >/dev/null 2>&1 || true
  "${runtime}" stop "${container_name}" >/dev/null 2>&1 || true
  "${runtime}" rm "${container_name}" >/dev/null 2>&1 || true
  if test -n "${scan_volume}"; then
    "${runtime}" volume rm "${scan_volume}" >/dev/null 2>&1 || true
  fi
  if test -n "${fake_bin_volume}"; then
    "${runtime}" volume rm "${fake_bin_volume}" >/dev/null 2>&1 || true
  fi
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

if test "${use_docker_volumes}" = "1"; then
  scan_volume="${container_name}-scans"
  fake_bin_volume="${container_name}-smoke-bin"
  scan_mount_source="${scan_volume}"
  fake_bin_mount_source="${fake_bin_volume}"

  "${runtime}" volume create "${scan_volume}" >/dev/null
  "${runtime}" volume create "${fake_bin_volume}" >/dev/null
  "${runtime}" create \
    --name "${seed_container}" \
    --user 0:0 \
    --entrypoint sh \
    --volume "${scan_volume}:/scans" \
    --volume "${fake_bin_volume}:/smoke-bin" \
    "${image}" \
    -c "sleep infinity" >/dev/null
  "${runtime}" start "${seed_container}" >/dev/null
  "${runtime}" cp \
    "tests/fixtures/receipt-small-page.pdf" \
    "${seed_container}:/scans/${fixture_name}"
  "${runtime}" cp "${fake_bin}/scanimage" "${seed_container}:/smoke-bin/scanimage"
  "${runtime}" exec "${seed_container}" chmod 0755 /smoke-bin/scanimage
  "${runtime}" exec "${seed_container}" \
    chown -R "$(id -u):$(id -g)" /scans /smoke-bin
  "${runtime}" rm --force "${seed_container}" >/dev/null
fi

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
  --volume "${fake_bin_mount_source}:/smoke-bin:ro" \
  --volume "${scan_mount_source}:/scans" \
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
if test "${use_docker_volumes}" = "1"; then
  "${runtime}" exec "${container_name}" test -s "/scans/.previews/${fixture_name}.jpg"
else
  test -s "${scan_dir}/.previews/${fixture_name}.jpg"
fi

curl --fail --silent \
  --request POST \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data 'mode_id=duplex-pdf-no-ocr' \
  "http://127.0.0.1:${port}/scan" \
  --output /dev/null
for _ in $(seq 1 60); do
  if test "${use_docker_volumes}" = "1"; then
    if "${runtime}" exec "${container_name}" test -s "/scans/${scan_name}"; then
      break
    fi
  else
    if test -s "${scan_dir}/${scan_name}"; then
      break
    fi
  fi
  sleep 1
done
if test "${use_docker_volumes}" = "1"; then
  "${runtime}" exec "${container_name}" test -s "/scans/${scan_name}"
else
  test -s "${scan_dir}/${scan_name}"
fi
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
