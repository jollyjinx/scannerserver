#!/usr/bin/env bash
set -euo pipefail

mkdir -p "${SCAN_OUTPUT_DIR:-/scans}" /run/dbus /run/avahi-daemon /etc/sane.d

if [[ -n "${SCANNER_URL:-}" ]]; then
  scanner_name="${SCANNER_NAME:-ScanSnap iX500}"
  scanner_protocol="${SCANNER_PROTOCOL:-escl}"
  cat > /etc/sane.d/airscan.conf <<EOF
[devices]
"${scanner_name}" = ${scanner_protocol}, ${SCANNER_URL}
EOF
fi

if [[ ! -S /run/dbus/system_bus_socket ]]; then
  dbus-daemon --system --fork
fi

if ! pgrep -x avahi-daemon >/dev/null 2>&1; then
  avahi-daemon --daemonize --no-drop-root || true
fi

exec "$@"
