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
docker build \
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
- Repeat setup with the manual IPv4-address/host-name and MAC form and confirm both the scanner's
  IP and a resolvable name select the same scanner.
- Verify `/scans/.scannerserver-scanner.json` is created, remains owned by the configured container UID/GID, and contains no transient file beside it.
- Clear setup and confirm scanning is blocked until the scanner is configured again.

For a scanner whose configured password derives to more than 16 identity bytes, run the opt-in
long-password reservation diagnostic before the browser flow:

```bash
SCANNERSERVER_RUN_SCANSNAP_HARDWARE_TESTS=1 \
SCANSNAP_TEST_IP=SCANNER_IP \
SCANSNAP_TEST_PASSWORD=SCANNER_PASSWORD \
swift test --filter ScanSnapLongPasswordHardwareTests
```

The credentials are read only from the test process environment. Do not add real scanner
credentials to the repository or ordinary test fixtures.

## Scan And OCR

- Run a duplex PDF scan from the web UI and confirm exactly one scan job starts.
- Attempt a second scan while the first is running and confirm it is ignored without interrupting the active scan.
- Verify source naming follows `YYYY-MM-DD.HHMMSS.pdf` and the file opens successfully.
- Confirm the source PDF remains downloadable while blank removal, crop, and OCR run on a copy.
- While `pdfimages` or OCR is actively consuming CPU, repeatedly refresh the index and verify HTTP
  responses remain immediate; background native-tool pipe reads and process waits must not starve
  the physical-button or HTTP actors.
- With OCR enabled, wait for the serial OCR queue and verify the matching `.ocr.pdf` is searchable.
- Test simplex, single-page PDF, and PNG modes; verify page numbers use four digits.
- Enable blank-page removal and crop with the existing fixture document and compare the result with a known-good legacy image.
- Confirm creator metadata, previews, inline view, download, selected deletion, and preview-cache deletion.

## Physical Button

- Confirm startup logs show the UDP `53220` listener and `ScanSnap button client armed`.
- Power the scanner off, wait at least ten seconds, then power it on. Confirm a startup-advertisement log appears and the button session re-arms without periodic replacement enabled.
- If the startup log is absent, capture `udp port 53220` on the host and confirm the advertisement reaches the service host with VENS command `0x21`.
- Leave the service idle for at least ten minutes and confirm the 500 ms heartbeat keeps the scanner button ready.
- During the idle test, optionally capture UDP `52217` and confirm heartbeats originate about every 500 ms from the configured client address/source port `55264`.
- Press the physical scan button once and confirm one scan starts with the configured default mode and `SCAN_TRIGGER=button`; the native client must not report registration error `-7`.
- Confirm the handoff stops the UDP heartbeat, sends D6 on TCP `53218`, consumes
  the iX500's complete 40-byte VENS acknowledgement, half-closes the client write side, and observes
  the scanner close before native acquisition continues with `--reuse-session`; there must be no
  second full UDP registration or TCP pairing/initialization sequence.
- If acquisition fails, confirm the native diagnostic (including a registration status such as
  `-7`) appears both in the web status and the container log.
- Press repeatedly during debounce, cooldown, and an active scan; confirm no duplicate scan starts.
- Wait for scan completion and confirm the retained session heartbeat resumes without a fresh
  registration or container restart.
- Start a scan from the web UI, wait for completion, then press the physical button and confirm it starts another scan immediately.
- Press the button with an empty feeder, wait for the brief orange error indication to clear, then load paper and confirm the next button press scans without restarting the scanner or container.
- While failed-scan recovery is still arming, press the button again and confirm the log reports
  `Scanner button notice reclaimed the session during recovery`; acquisition must reuse that session
  and the lifecycle must not wait through another fresh-registration cycle.
- As an explicit diagnostic only, set `SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS` to a short interval,
  wait through one full safety re-arm, and confirm the service finalizes the retained command
  sequence before re-arming. Restore it to `0`; periodic replacement is disabled by default because
  the iX500 may reject that unnecessary registration with `-7`.
- Change the default mode and scanner configuration, then confirm the next button scan uses the new values.
- Temporarily disconnect the scanner and confirm the web page changes to a grey **Not reachable**
  indicator after the health check. Reconnect it and confirm reachability retry changes the
  indicator to green **Reachable**.
- Confirm only the configured scanner's startup advertisement or UDP `55265` button notice can trigger lifecycle work.

## Restart Compatibility

- Stop the Swift container and copy known-good legacy `.scanner-settings.json` and `.scannerserver-scanner.json` files into the scan directory.
- Restart the Swift container with the same environment and confirm it uses the stored scanner and modes without rewriting their schema.
- Run one web scan and one button scan, then restart again while OCR output is present.
- Confirm existing PDF, OCR PDF, PNG, and preview entries remain visible and deletable.

## Resource Capture

```bash
docker exec scannerserver-swift-hardware \
  grep -E '^(Name|VmRSS|VmHWM|Threads):' /proc/1/status

docker image list --verbose
docker logs scannerserver-swift-hardware
```

Record idle RSS after the index and health routes have been requested, peak RSS during scan and OCR, compressed image size, architecture, Swift image tag, and scanner firmware version in the release notes.

## Cleanup

```bash
docker stop scannerserver-swift-hardware
docker rm scannerserver-swift-hardware
```
