#!/usr/bin/env bash
set -euo pipefail

scan_output_dir="${SCAN_OUTPUT_DIR:-/scans}"
mkdir -p "${scan_output_dir}"

ocr_temp_dir="${TMPDIR:-${scan_output_dir}/.ocr-tmp}"
mkdir -p "${ocr_temp_dir}"
export TMPDIR="${ocr_temp_dir}"

if [[ -n "${SCANNER_URL:-}" ]]; then
  bundled_sane_config_dir="${SANE_CONFIG_DIR:-/app/sane.d}"
  runtime_sane_config_dir="${SANE_RUNTIME_CONFIG_DIR:-/tmp/scannerserver-sane.d}"
  mkdir -p "${runtime_sane_config_dir}"
  cp -a "${bundled_sane_config_dir}/." "${runtime_sane_config_dir}/"
  export SANE_CONFIG_DIR="${runtime_sane_config_dir}"
  scanner_name="${SCANNER_NAME:-ScanSnap iX500}"
  scanner_protocol="${SCANNER_PROTOCOL:-escl}"
  cat > "${SANE_CONFIG_DIR}/airscan.conf" <<EOF
[devices]
"${scanner_name}" = ${scanner_protocol}, ${SCANNER_URL}
EOF
fi

if [[ "${SCAN_ENABLE_DISCOVERY_DAEMONS:-false}" == "true" ]]; then
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "SCAN_ENABLE_DISCOVERY_DAEMONS=true requires the container to run as root; skipping dbus/avahi startup." >&2
  else
    mkdir -p /run/dbus /run/avahi-daemon
    if [[ ! -S /run/dbus/system_bus_socket ]]; then
      dbus-daemon --system --fork
    fi

    if ! pgrep -x avahi-daemon >/dev/null 2>&1; then
      avahi-daemon --daemonize --no-drop-root || true
    fi
  fi
fi

exec "$@"
