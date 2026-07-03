#!/usr/bin/env bash
set -euo pipefail

raw_pdf="${1:?raw PDF path required}"

output_dir="${SCAN_OUTPUT_DIR:-/scans}"
language="${SCAN_LANGUAGE:-deu+eng}"
topic="${SCAN_TOPIC:-}"
topic_rules="${SCAN_TOPIC_RULES:-/app/config/topics.json}"
fallback_topic="${SCAN_FALLBACK_TOPIC:-Unsortiert Scan}"
scan_date="${SCAN_DATE:-$(date +%Y--%m--%d)}"

timestamp="$(date +%Y%m%d-%H%M%S)"
workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

mkdir -p "$output_dir"

ocr_pdf="$workdir/ocr-$timestamp.pdf"
sidecar="$workdir/ocr-$timestamp.txt"

ocrmypdf --language "$language" --rotate-pages --deskew --optimize 1 --sidecar "$sidecar" "$raw_pdf" "$ocr_pdf"

classify_args=(
  --raw-pdf "$raw_pdf"
  --ocr-pdf "$ocr_pdf"
  --text "$sidecar"
  --rules "$topic_rules"
  --output-dir "$output_dir"
  --fallback-topic "$fallback_topic"
  --date "$scan_date"
)

if [[ -n "$topic" ]]; then
  classify_args+=(--topic "$topic")
fi

classify-scan "${classify_args[@]}"
