#!/usr/bin/env bash
set -euo pipefail

image="${1:-gitmaster.jinx.eu/jnxpublic/scannerserver:jinx}"
port="${SCANNERSERVER_CONTAINER_WORKER_SMOKE_PORT:-18083}"
server_name="scannerserver-container-worker-smoke-$$"
worker_name="scannerserver-ocr-worker-smoke-$$"
worker_volume="scannerserver-ocr-worker-state-smoke-$$"
scan_dir="$(mktemp -d)"
fake_bin="$(mktemp -d)"
base_url="http://127.0.0.1:${port}"
worker_server_url="http://host.docker.internal:${port}"
scan_name="2026-08-15.120500.pdf"
ocr_name="2026-08-15.120500.ocr.pdf"

cleanup() {
  docker rm --force "${worker_name}" >/dev/null 2>&1 || true
  docker rm --force "${server_name}" >/dev/null 2>&1 || true
  docker volume rm "${worker_volume}" >/dev/null 2>&1 || true
  rm -rf "${scan_dir}" "${fake_bin}"
}
trap cleanup EXIT

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
  --env SCAN_TIMESTAMP=2026-08-15.120500 \
  --env SCAN_REMOVE_BLANK_PAGES=false \
  --env SCAN_CROP_PAGES=false \
  --env SCAN_OCR_ENABLED=true \
  --env SCAN_OCR_REMOTE_ASSIGNMENT_WAIT_SECONDS=30 \
  --env PATH=/smoke-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/scannerserver \
  --volume "${fake_bin}:/smoke-bin:ro" \
  --volume "${scan_dir}:/scans" \
  "${image}" >/dev/null

for _ in $(seq 1 30); do
  curl --fail --silent "${base_url}/health" >/dev/null && break
  sleep 1
done
curl --fail --silent "${base_url}/health" | grep -qx ok

docker run \
  --detach \
  --name "${worker_name}" \
  --add-host host.docker.internal:host-gateway \
  --cpus 2 \
  --memory 4g \
  --volume "${worker_volume}:/home/scansnap/.config/scannerserver-worker" \
  "${image}" \
  scannerserver-worker \
  --server "${worker_server_url}" \
  --name "Container smoke worker" \
  --jobs 1 >/dev/null

worker_id=""
for _ in $(seq 1 30); do
  workers_json="$(curl --fail --silent "${base_url}/api/ocr-workers")"
  worker_id="$(printf '%s' "${workers_json}" | sed -nE 's/.*"workerID":"([^"]+)".*/\1/p')"
  test -n "${worker_id}" && break
  sleep 1
done
test -n "${worker_id}"
curl --fail --silent --request POST "${base_url}/workers/${worker_id}/approve" >/dev/null

curl --fail --silent \
  --request POST \
  --header 'Content-Type: application/x-www-form-urlencoded' \
  --data 'mode_id=duplex-pdf-ocr' \
  "${base_url}/scan" >/dev/null

for _ in $(seq 1 180); do
  test -s "${scan_dir}/${ocr_name}" && break
  if test "$(docker inspect --format '{{.State.Running}}' "${worker_name}")" != "true"; then
    docker logs "${worker_name}" >&2
    docker logs "${server_name}" >&2
    exit 1
  fi
  sleep 1
done

test -s "${scan_dir}/${scan_name}"
test -s "${scan_dir}/${ocr_name}"
docker exec "${server_name}" qpdf --check "/scans/${ocr_name}" >/dev/null
curl --fail --silent "${base_url}/workers" | grep -q '>Completed</dt><dd>1</dd>'
curl --fail --silent "${base_url}/workers" | grep -q '2 CPUs · 1 job slot'
docker logs "${worker_name}" 2>&1 | grep -q 'Completed remote OCR job'
printf 'Container worker smoke passed: %s -> %s\n' "${scan_name}" "${ocr_name}"
