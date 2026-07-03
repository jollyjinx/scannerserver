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
    ocr_pdf="$workdir/ocr-$timestamp.pdf"
    sidecar="$workdir/ocr-$timestamp.txt"
    ocrmypdf --language "$language" --rotate-pages --deskew --optimize 1 --sidecar "$sidecar" "$raw_pdf" "$ocr_pdf"
    classify_args=(
      --pdf "$ocr_pdf"
      --text "$sidecar"
      --rules "$topic_rules"
      --output-dir "$output_dir"
      --fallback-topic "$fallback_topic"
      --date "$scan_date"
    )
    if [[ -n "$topic" ]]; then
      classify_args+=(--topic "$topic")
    fi
    final_path="$(classify-scan "${classify_args[@]}")"
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
