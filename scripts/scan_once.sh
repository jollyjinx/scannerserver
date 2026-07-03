#!/usr/bin/env bash
set -euo pipefail

output_dir="${SCAN_OUTPUT_DIR:-/scans}"
language="${SCAN_LANGUAGE:-deu+eng}"
resolution="${SCAN_RESOLUTION:-300}"
mode="${SCAN_MODE:-Color}"
source="${SCAN_SOURCE:-ADF Duplex}"
format="${SCAN_FORMAT:-pdf}"
device="${SCAN_DEVICE:-}"
topic="${SCAN_TOPIC:-}"
topic_rules="${SCAN_TOPIC_RULES:-/app/config/topics.json}"
fallback_topic="${SCAN_FALLBACK_TOPIC:-Unsortiert Scan}"
scan_date="${SCAN_DATE:-$(date +%Y--%m--%d)}"

timestamp="$(date +%Y%m%d-%H%M%S)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

mkdir -p "$output_dir"

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

raw_pdf="$workdir/raw.pdf"
img2pdf "${pages[@]}" -o "$raw_pdf"

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
