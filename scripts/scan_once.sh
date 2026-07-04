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
scanner_ip="${SCANNER_IP:-}"
pairing_key="${SCAN_PAIRING_KEY:-${SCANSNAP_PAIRING_KEY:-}}"
client_ip="${SCANSNAP_CLIENT_IP:-}"
simplex="${SCAN_SIMPLEX:-false}"
wifi_debug="${SCAN_WIFI_DEBUG:-false}"
remove_blank_pages="${SCAN_REMOVE_BLANK_PAGES:-true}"

scan_timestamp="${SCAN_TIMESTAMP:-$(date +%Y-%m-%d.%H%M%S)}"
log_event() {
  printf '%s scan-once.%s\n' "$(date -Iseconds)" "$*" >&2
}

mkdir -p "$output_dir"
workdir="$(mktemp -d "$output_dir/.scan-work.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

raw_pdf="$workdir/raw.pdf"
log_event "start backend=$backend format=$format output_dir=$output_dir timestamp=$scan_timestamp"

case "$backend" in
  sane)
    log_event "sane.start resolution=$resolution mode=$mode source=$source device=${device:-default}"
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
    log_event "sane.scanadf.finished"

    shopt -s nullglob
    pages=("$workdir"/page-*.pnm)
    log_event "sane.pages.detected count=${#pages[@]}"
    if [[ "${#pages[@]}" -eq 0 ]]; then
      echo "No pages were scanned. Check that paper is loaded and SCAN_SOURCE matches the scanner options." >&2
      exit 2
    fi

    log_event "pdf.create.start pages=${#pages[@]}"
    img2pdf "${pages[@]}" -o "$raw_pdf"
    log_event "pdf.create.finished raw_pdf=$raw_pdf"
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

    log_event "wifi.start scanner_ip=$scanner_ip simplex=$simplex source=$source debug=$wifi_debug"
    scansnap-wifi "${wifi_args[@]}"
    log_event "wifi.finished raw_pdf=$raw_pdf"
    ;;
  *)
    echo "Unsupported SCAN_BACKEND: $backend" >&2
    exit 64
    ;;
esac

case "$format" in
  pdf)
    if [[ "$remove_blank_pages" == "true" || "$remove_blank_pages" == "1" || "$remove_blank_pages" == "yes" || "$remove_blank_pages" == "on" ]]; then
      log_event "blank-removal.start raw_pdf=$raw_pdf"
      remove-blank-pages "$raw_pdf" \
        --white-threshold "${SCAN_BLANK_WHITE_THRESHOLD:-245}" \
        --content-ratio-threshold "${SCAN_BLANK_CONTENT_RATIO_THRESHOLD:-0.003}" \
        --mean-threshold "${SCAN_BLANK_MEAN_THRESHOLD:-248.0}" \
        ${SCAN_BLANK_DEBUG:+--debug} >&2
      log_event "blank-removal.finished raw_pdf=$raw_pdf"
    else
      log_event "blank-removal.skipped"
    fi
    log_event "metadata.start creator=${SCAN_RAW_PDF_CREATOR:-ScanSnap}"
    set-pdf-creator "$raw_pdf" --creator "${SCAN_RAW_PDF_CREATOR:-ScanSnap}"
    log_event "metadata.finished"
    final_path="$output_dir/$scan_timestamp.pdf"
    if [[ -e "$final_path" ]]; then
      echo "Output file already exists: $final_path" >&2
      exit 73
    fi
    log_event "output.move.start final_path=$final_path"
    mv "$raw_pdf" "$final_path"
    log_event "output.move.finished final_path=$final_path"
    ;;
  image|images)
    final_path="$output_dir/scan-$scan_timestamp"
    mkdir -p "$final_path"
    log_event "output.copy-images.start final_path=$final_path pages=${#pages[@]}"
    cp "${pages[@]}" "$final_path/"
    log_event "output.copy-images.finished final_path=$final_path"
    ;;
  *)
    echo "Unsupported SCAN_FORMAT: $format" >&2
    exit 64
    ;;
esac

log_event "finished final_path=$final_path"
echo "$final_path"
