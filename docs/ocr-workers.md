---
title: Distributed OCR Workers
description: Running and operating optional macOS OCR workers for scannerserver.
type: reference
audience: maintainers and operators
status: current
---

# Distributed OCR Workers

The distributed OCR feature keeps scannerserver authoritative for scanning, queue ownership,
filenames, cancellation, and final publication. Optional workers register from other computers and
claim leased OCR jobs. Workers initiate every connection so they
do not need a fixed address or an inbound firewall rule.

## How It Works

- The `scannerserver-worker` Swift executable connects to an explicit scannerserver URL or discovers
  `_scannerserver._tcp` through Bonjour on macOS.
- Each worker creates a persistent ID and authentication token in
  `~/.config/scannerserver-worker/identity.json`.
- Registration reports its name, hostname, architecture, CPU capacity, job slots, version, and OCR
  languages.
- New workers require approval on the scannerserver **Workers** page.
- Heartbeats report liveness and running-job count. Approved workers become offline after missed
  heartbeats and can be disabled without forgetting their approval.
- Registrations and approvals are stored atomically in
  `/scans/.scannerserver-ocr-workers.json` by default.
- `OCRWorkerJobStore` provides an atomically persisted manifest and lease state machine at
  `/scans/.scannerserver-ocr-jobs.json`. It supports FIFO capability matching, opaque lease tokens,
  renewal, authenticated terminal transitions, cancellation, and restart-safe lease expiry.
- `OCRQueueActor` sends compatible `ocrmypdf` commands to an approved online worker. Blank-page
  removal, autocrop, scan acquisition, naming, and final publication stay on scannerserver.
- The worker downloads a size- and SHA-256-verified PDF, starts the existing scannerserver image
  with Apple `container`, and uploads the result through its authenticated lease.
- scannerserver requires a PDF result, calculates its SHA-256 digest, writes it to a same-directory
  staging file, validates it with `qpdf --check`, and atomically publishes the established
  `.ocr.pdf` output name.
- No eligible worker, assignment timeout, or reported worker failure falls back to the existing
  local OCR executor. Cancellation invalidates the remote lease.

## Run A Worker On macOS

Install and start Apple's Container system, then pull the same image used by scannerserver:

```sh
container system start
container system kernel set --recommended  # only when no default kernel is configured
container image pull ghcr.io/jollyjinx/scannerserver:latest
```

Build and start the worker from this repository:

```sh
swift run -c release scannerserver-worker \
  --server http://SCANNERSERVER-IP \
  --name "Mac Studio" \
  --cpus 11 \
  --jobs 1 \
  --memory-per-job 8G
```

When scannerserver advertises itself through Bonjour, omit `--server`:

```sh
swift run -c release scannerserver-worker --name "Mac Studio" --cpus 11 --jobs 1
```

Set `SCAN_OCR_WORKER_BONJOUR_ENABLED=true` on scannerserver to start the optional
`avahi-publish-service` publisher. Its Avahi daemon must already be reachable. Set
`SCANNERSERVER_BONJOUR_URL` to the URL that Macs can use, particularly when scannerserver's
container hostname is not resolvable on the LAN:

```yaml
environment:
  SCAN_OCR_WORKER_BONJOUR_ENABLED: "true"
  SCANNERSERVER_BONJOUR_URL: "http://scanner-host.local"
```

Bonjour publication is best-effort and does not affect the scanner service if Avahi is missing or
unavailable. Passing `--server` to the worker bypasses discovery completely.

Open the **Workers** page on scannerserver and approve the new worker. The command defaults to the
active processor count minus one so macOS retains one processor for interactive work. `--cpus` is
divided across `--jobs`; with the recommended `--jobs 1`, one document uses every advertised CPU.
The page shows online capacity plus queued, running, completed, and failed remote jobs.

Useful worker overrides:

```text
--container-runtime container
--container-image ghcr.io/jollyjinx/scannerserver:latest
--memory-per-job 8G
--workspace ~/Library/Caches/scannerserver-worker/jobs
```

Stop the worker with Control-C. Its identity remains in
`~/.config/scannerserver-worker/identity.json`, so it does not need approval again.

The API accepts HTTP because the main service has no TLS termination contract. Worker and lease
tokens authenticate every document operation, but document bytes are not encrypted over plain HTTP.
Run this only on a trusted LAN or put scannerserver behind HTTPS before using an untrusted network.

## Protocol

The current protocol version is `1`:

```text
POST /api/ocr-workers/register
POST /api/ocr-workers/{worker-id}/heartbeat
POST /api/ocr-workers/{worker-id}/jobs/lease
GET  /api/ocr-workers/{worker-id}/jobs/{job-id}/source
POST /api/ocr-workers/{worker-id}/jobs/{job-id}/renew
POST /api/ocr-workers/{worker-id}/jobs/{job-id}/result
POST /api/ocr-workers/{worker-id}/jobs/{job-id}/fail
GET  /api/ocr-workers
```

The browser approval controls use server-rendered form routes under `/workers/{worker-id}/...`.
The public listing contains worker metadata and status but never authentication tokens.

Initially, one multipage document should be assigned to one worker. More workers increase throughput
across queued documents. Cross-machine page sharding is a separate compatibility project because it
must preserve page order, metadata, PDF/A behavior, and failure atomicity.
