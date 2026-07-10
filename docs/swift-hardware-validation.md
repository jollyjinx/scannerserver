---
title: Swift Hardware Validation
description: Manual iX500 acceptance checklist for the Swift scannerserver container.
type: guide
audience: maintainers
status: current
---

# Swift Hardware Validation

Run this checklist against a real ScanSnap iX500 before publishing the Swift image as `latest`. Unit and container smoke tests do not validate the scanner's session ownership, button protocol, or LAN routing.

## Build And Start

```bash
container build \
  --file Dockerfile \
  --tag scannerserver-swift:hardware \
  .

mkdir -p scans-swift-hardware

docker run \
  --detach \
  --name scannerserver-swift-hardware \
  --network host \
  --env WEB_PORT=8080 \
  --env SCAN_OUTPUT_DIR=/scans \
  --env SCAN_BACKEND=wifi \
  --env SCANSNAP_BUTTON_SCAN_ENABLED=true \
  --volume "${PWD}/scans-swift-hardware:/scans" \
  scannerserver-swift:hardware
```

Use a dedicated scan directory for the clean-setup pass. Do not copy an existing `.scannerserver-scanner.json` into it until the restart-compatibility step.

## Clean Setup

- Open `http://<host>:8080/` and confirm scanner setup appears without an existing config file.
- Start discovery and confirm the iX500 appears with its expected name, IP, MAC address, and serial number.
- Select the scanner. If it requires a password, enter the scanner password and confirm pairing succeeds.
- Repeat setup with the manual IP/MAC form and confirm the same scanner is resolved.
- Verify `/scans/.scannerserver-scanner.json` is created, remains owned by the configured container UID/GID, and contains no transient file beside it.
- Clear setup and confirm scanning is blocked until the scanner is configured again.

## Scan And OCR

- Run a duplex PDF scan from the web UI and confirm exactly one scan job starts.
- Attempt a second scan while the first is running and confirm it is ignored without interrupting the active scan.
- Verify source naming follows `YYYY-MM-DD.HHMMSS.pdf` and the file opens successfully.
- With OCR enabled, wait for the serial OCR queue and verify the matching `.ocr.pdf` is searchable.
- Test simplex, single-page PDF, and PNG modes; verify page numbers use four digits.
- Enable blank-page removal and crop with the existing fixture document and compare the result with a known-good legacy image.
- Confirm creator metadata, previews, inline view, download, selected deletion, and preview-cache deletion.

## Physical Button

- Leave the service idle until the configured arm interval has elapsed and confirm the scanner remains ready.
- Press the physical scan button once and confirm one scan starts with the configured default mode and `SCAN_TRIGGER=button`.
- Press repeatedly during debounce, cooldown, and an active scan; confirm no duplicate scan starts.
- Wait for scan completion and confirm the session re-arms without restarting the container.
- Change the default mode and scanner configuration, then confirm the next button scan uses the new values.
- Temporarily disconnect the scanner, reconnect it, and confirm reachability retry and periodic re-arming recover.

## Restart Compatibility

- Stop the Swift container and copy known-good legacy `.scanner-settings.json` and `.scannerserver-scanner.json` files into the scan directory.
- Restart the Swift container with the same environment and confirm it uses the stored scanner and modes without rewriting their schema.
- Run one web scan and one button scan, then restart again while OCR output is present.
- Confirm existing PDF, OCR PDF, PNG, and preview entries remain visible and deletable.

## Resource Capture

```bash
docker exec scannerserver-swift-hardware \
  grep -E '^(Name|VmRSS|VmHWM|Threads):' /proc/1/status

container image list --verbose
docker logs scannerserver-swift-hardware
```

Record idle RSS after the index and health routes have been requested, peak RSS during scan and OCR, compressed image size, architecture, Swift image tag, and scanner firmware version in the release notes.

## Cleanup

```bash
docker stop scannerserver-swift-hardware
docker rm scannerserver-swift-hardware
```
