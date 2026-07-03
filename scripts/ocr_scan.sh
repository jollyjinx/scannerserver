#!/usr/bin/env bash
set -euo pipefail

raw_pdf="${1:?raw PDF path required}"

language="${SCAN_LANGUAGE:-deu+eng}"

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT

if [[ "$raw_pdf" != *.pdf || "$raw_pdf" == *.ocr.pdf ]]; then
  echo "Raw PDF must end in .pdf and must not already be an OCR PDF: $raw_pdf" >&2
  exit 64
fi

ocr_pdf="${raw_pdf%.pdf}.ocr.pdf"
sidecar="$workdir/ocr.txt"

if [[ -e "$ocr_pdf" ]]; then
  echo "OCR output file already exists: $ocr_pdf" >&2
  exit 73
fi

ocrmypdf --language "$language" --rotate-pages --deskew --optimize 1 --sidecar "$sidecar" "$raw_pdf" "$ocr_pdf"

echo "$ocr_pdf"
