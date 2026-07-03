#!/usr/bin/env bash
set -euo pipefail

output_dir="${SCAN_OUTPUT_DIR:-/scans}"
language="${SCAN_LANGUAGE:-deu+eng}"
resolution="${SCAN_RESOLUTION:-300}"
mode="${SCAN_MODE:-Color}"
source="${SCAN_SOURCE:-ADF Duplex}"
format="${SCAN_FORMAT:-pdf}"
backend="${SCAN_BACKEND:-sane}"
device="${SCAN_DEVICE:-}"
topic="${SCAN_TOPIC:-}"
topic_rules="${SCAN_TOPIC_RULES:-/app/config/topics.json}"
fallback_topic="${SCAN_FALLBACK_TOPIC:-Unsortiert Scan}"
scan_date="${SCAN_DATE:-$(date +%Y--%m--%d)}"
scanner_ip="${SCANNER_IP:-}"
pairing_key="${SCAN_PAIRING_KEY:-${SCANSNAP_PAIRING_KEY:-}}"
client_ip="${SCANSNAP_CLIENT_IP:-}"
simplex="${SCAN_SIMPLEX:-false}"
wifi_debug="${SCAN_WIFI_DEBUG:-false}"

timestamp="$(date +%Y%m%d-%H%M%S)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

mkdir -p "$output_dir"

raw_pdf="$workdir/raw.pdf"

unique_raw_path() {
  local base="$output_dir/$scan_date.Scan $timestamp.scan.pdf"
  local candidate="$base"
  local counter=2
  while [[ -e "$candidate" ]]; do
    candidate="$output_dir/$scan_date.Scan $timestamp.$counter.scan.pdf"
    counter=$((counter + 1))
  done
  printf '%s\n' "$candidate"
}

case "$backend" in
  sane)
    scan_args=(
      --output-file "$workdir/page-%04d.pnm"
      --resolution "$resolution"
      --mode "$mode"
      --source "$source"
    )

    if [[ -n "$device" ]]; then
      scan_args=(--device-name "$device" "${scan_args[@]}")
    fi

    scanadf "${scan_args[@]}"

    shopt -s nullglob
    pages=("$workdir"/page-*.pnm)
    if [[ "${#pages[@]}" -eq 0 ]]; then
      echo "No pages were scanned. Check that paper is loaded and SCAN_SOURCE matches the scanner options." >&2
      exit 2
    fi

    img2pdf "${pages[@]}" -o "$raw_pdf"
    ;;
  wifi)
    if [[ -z "$scanner_ip" ]]; then
      echo "SCAN_BACKEND=wifi requires SCANNER_IP." >&2
      exit 64
    fi
    if [[ -z "$pairing_key" ]]; then
      echo "SCAN_BACKEND=wifi requires SCAN_PAIRING_KEY or SCANSNAP_PAIRING_KEY." >&2
      exit 64
    fi

    wifi_args=(-s "$scanner_ip" -k "$pairing_key" -o "$raw_pdf")
    if [[ -n "$client_ip" ]]; then
      wifi_args+=(--client-ip "$client_ip")
    fi
    if [[ "$simplex" == "true" || "$source" == *"Simplex"* || "$source" == *"simplex"* ]]; then
      wifi_args+=(-1)
    fi
    if [[ "$wifi_debug" == "true" ]]; then
      wifi_args+=(-d)
    fi

    scansnap-wifi "${wifi_args[@]}"
    ;;
  *)
    echo "Unsupported SCAN_BACKEND: $backend" >&2
    exit 64
    ;;
esac

case "$format" in
  pdf)
    set-pdf-creator "$raw_pdf" --creator "${SCAN_RAW_PDF_CREATOR:-ScanSnap}"
    final_path="$(unique_raw_path)"
    mv "$raw_pdf" "$final_path"
    ;;
  image|images)
    final_path="$output_dir/scan-$timestamp"
    mkdir -p "$final_path"
    cp "${pages[@]}" "$final_path/"
    ;;
  *)
    echo "Unsupported SCAN_FORMAT: $format" >&2
    exit 64
    ;;
esac

echo "$final_path"
