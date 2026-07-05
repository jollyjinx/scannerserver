#!/usr/bin/env bash
set -euo pipefail

output_dir="${SCAN_OUTPUT_DIR:-/scans}"
language="${SCAN_LANGUAGE:-deu+eng}"
resolution="${SCAN_RESOLUTION:-300}"
mode="${SCAN_MODE:-Color}"
source="${SCAN_SOURCE:-ADF Duplex}"
format="${SCAN_FORMAT:-pdf}"
page_mode="${SCAN_PAGE_MODE:-multi}"
backend="${SCAN_BACKEND:-sane}"
device="${SCAN_DEVICE:-}"
scanner_ip="${SCANNER_IP:-}"
pairing_key="${SCAN_PAIRING_KEY:-${SCANSNAP_PAIRING_KEY:-}}"
client_ip="${SCANSNAP_CLIENT_IP:-}"
simplex="${SCAN_SIMPLEX:-false}"
wifi_debug="${SCAN_WIFI_DEBUG:-false}"
remove_blank_pages="${SCAN_REMOVE_BLANK_PAGES:-true}"
crop_pages="${SCAN_CROP_PAGES:-true}"

scan_timestamp="${SCAN_TIMESTAMP:-$(date +%Y-%m-%d.%H%M%S)}"
log_event() {
  printf '%s scan-once.%s\n' "$(date -Iseconds)" "$*" >&2
}

is_truthy() {
  case "${1,,}" in
    true|1|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

mkdir -p "$output_dir"
workdir="$(mktemp -d "$output_dir/.scan-work.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

raw_pdf="$workdir/raw.pdf"
log_event "start backend=$backend format=$format page_mode=$page_mode output_dir=$output_dir timestamp=$scan_timestamp"

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

if is_truthy "$remove_blank_pages"; then
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

if is_truthy "$crop_pages"; then
  log_event "crop.start raw_pdf=$raw_pdf"
  crop-pdf-pages "$raw_pdf" \
    --background-delta "${SCAN_CROP_BACKGROUND_DELTA:-8}" \
    --border-px "${SCAN_CROP_BORDER_PX:-64}" \
    --margin-points "${SCAN_CROP_MARGIN_POINTS:-12}" \
    --max-width-ratio "${SCAN_CROP_MAX_WIDTH_RATIO:-0.80}" \
    --max-height-ratio "${SCAN_CROP_MAX_HEIGHT_RATIO:-0.80}" \
    --min-density "${SCAN_CROP_MIN_DENSITY:-0.08}" \
    ${SCAN_CROP_KEEP_ORIGINAL_BOXES:+--keep-original-boxes} \
    ${SCAN_CROP_DEBUG:+--debug} >&2
  log_event "crop.finished raw_pdf=$raw_pdf"
else
  log_event "crop.skipped"
fi

log_event "metadata.start creator=${SCAN_RAW_PDF_CREATOR:-ScanSnap}"
set-pdf-creator "$raw_pdf" --creator "${SCAN_RAW_PDF_CREATOR:-ScanSnap}"
log_event "metadata.finished"

final_paths=()
case "$format" in
  pdf)
    if [[ "$page_mode" == "single" ]]; then
      log_event "pdf.split.start raw_pdf=$raw_pdf"
      paths_file="$workdir/final-paths.txt"
      split-pdf-pages "$raw_pdf" "$output_dir" "$scan_timestamp" > "$paths_file"
      mapfile -t final_paths < "$paths_file"
      log_event "pdf.split.finished pages=${#final_paths[@]}"
    else
      if [[ "$page_mode" != "multi" ]]; then
        log_event "page-mode.unsupported value=$page_mode fallback=multi"
      fi
      final_path="$output_dir/$scan_timestamp.pdf"
      if [[ -e "$final_path" ]]; then
        echo "Output file already exists: $final_path" >&2
        exit 73
      fi
      log_event "output.move.start final_path=$final_path"
      mv "$raw_pdf" "$final_path"
      log_event "output.move.finished final_path=$final_path"
      final_paths=("$final_path")
    fi
    ;;
  png|image|images)
    log_event "png.export.start raw_pdf=$raw_pdf"
    paths_file="$workdir/final-paths.txt"
    export-scan-images "$raw_pdf" "$output_dir" "$scan_timestamp" > "$paths_file"
    mapfile -t final_paths < "$paths_file"
    log_event "png.export.finished pages=${#final_paths[@]}"
    ;;
  *)
    echo "Unsupported SCAN_FORMAT: $format" >&2
    exit 64
    ;;
esac

if [[ "${#final_paths[@]}" -eq 0 ]]; then
  echo "No output files were created." >&2
  exit 2
fi

for final_path in "${final_paths[@]}"; do
  echo "$final_path"
done

log_event "finished final_paths=${#final_paths[@]}"
