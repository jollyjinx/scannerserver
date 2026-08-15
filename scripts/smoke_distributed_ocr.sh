#!/usr/bin/env bash
set -euo pipefail

server_image="${1:-scannerserver:distributed-ocr}"
worker_image="${2:-ghcr.io/jollyjinx/scannerserver:latest}"
port="${SCANNERSERVER_DISTRIBUTED_SMOKE_PORT:-18082}"
server_name="scannerserver-distributed-smoke-$$"
scan_dir="$(mktemp -d)"
fake_bin="$(mktemp -d)"
worker_state="$(mktemp -d)"
worker_log="${worker_state}/worker.log"
worker_binary="${SCANNERSERVER_WORKER_BINARY:-.build/release/scannerserver-worker}"
worker_id="distributed-smoke-worker"
worker_token="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
base_url="http://127.0.0.1:${port}"
scan_name="2026-08-15.103700.pdf"
ocr_name="2026-08-15.103700.ocr.pdf"
worker_pid=""

cleanup() {
  if test -n "${worker_pid}"; then
    kill "${worker_pid}" >/dev/null 2>&1 || true
    wait "${worker_pid}" >/dev/null 2>&1 || true
  fi
  docker rm --force "${server_name}" >/dev/null 2>&1 || true
  rm -rf "${scan_dir}" "${fake_bin}" "${worker_state}"
}
trap cleanup EXIT

test -x "${worker_binary}"
cat > "${worker_state}/identity.json" <<EOF
{
  "authenticationToken" : "${worker_token}",
  "workerID" : "${worker_id}"
}
EOF

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
printf 'P6\n64 64\n255\n' > "${output}"
head -c 12288 /dev/zero >> "${output}"
EOF
chmod 0755 "${fake_bin}/scanimage"

docker run \
  --detach \
  --name "${server_name}" \
  --publish "${port}:80" \
  --user "$(id -u):$(id -g)" \
  --env WEB_PORT=80 \
  --env SCAN_OUTPUT_DIR=/scans \
  --env SCAN_BACKEND=sane \
  --env SCAN_TIMESTAMP=2026-08-15.103700 \
  --env SCAN_REMOVE_BLANK_PAGES=false \
  --env SCAN_CROP_PAGES=false \
  --env SCAN_OCR_ENABLED=true \
  --env SCAN_OCR_REMOTE_ASSIGNMENT_WAIT_SECONDS=30 \
  --env PATH=/smoke-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/scannerserver \
  --volume "${fake_bin}:/smoke-bin:ro" \
  --volume "${scan_dir}:/scans" \
  "${server_image}" >/dev/null

for _ in $(seq 1 30); do
  curl --fail --silent "${base_url}/health" >/dev/null && break
  sleep 1
done
curl --fail --silent "${base_url}/health" | grep -qx ok

"${worker_binary}" \
  --server "${base_url}" \
  --name "Distributed smoke worker" \
  --cpus 2 \
  --identity-file "${worker_state}/identity.json" \
  --container-image "${worker_image}" \
  --workspace "${worker_state}/jobs" \
  >"${worker_log}" 2>&1 &
worker_pid=$!

for _ in $(seq 1 30); do
  curl --fail --silent "${base_url}/api/ocr-workers" | grep -q "${worker_id}" && break
  sleep 1
done
curl --fail --silent "${base_url}/api/ocr-workers" | grep -q "${worker_id}"
curl --fail --silent --request POST "${base_url}/workers/${worker_id}/approve" >/dev/null

curl --fail --silent \
  --request POST \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data 'mode_id=duplex-pdf-ocr' \
  "${base_url}/scan" >/dev/null

for _ in $(seq 1 180); do
  test -s "${scan_dir}/${ocr_name}" && break
  if ! kill -0 "${worker_pid}" >/dev/null 2>&1; then
    cat "${worker_log}" >&2
    docker logs "${server_name}" >&2
    exit 1
  fi
  sleep 1
done

test -s "${scan_dir}/${scan_name}"
test -s "${scan_dir}/${ocr_name}"
docker exec "${server_name}" qpdf --check "/scans/${ocr_name}" >/dev/null
curl --fail --silent "${base_url}/workers" | grep -q '>Completed</dt><dd>1</dd>'
grep -q 'Completed remote OCR job' "${worker_log}"
printf 'Distributed OCR smoke passed: %s -> %s\n' "${scan_name}" "${ocr_name}"
