---
title: Distributed OCR Workers
description: Current control-plane implementation and planned job execution for optional macOS OCR workers.
type: reference
audience: maintainers and operators
status: in-progress
---

# Distributed OCR Workers

The distributed OCR feature keeps scannerserver authoritative for scanning, queue ownership,
filenames, cancellation, and final publication. Optional workers register from other computers and
will eventually claim leased document-processing jobs. Workers initiate every connection so they
do not need a fixed address or an inbound firewall rule.

## Current Implementation

The first control-plane slice is implemented:

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

The job store is not fed by `OCRQueueActor` or exposed to workers yet. Local processing remains the
only execution path until downloads, verified uploads, and cancellation propagation are added.

## Running The Registration Agent

Build and start the worker on macOS:

```sh
swift build --product scannerserver-worker
swift run scannerserver-worker \
  --server http://SCANNERSERVER-IP \
  --name "Mac Studio" \
  --cpus 11 \
  --jobs 1
```

When scannerserver advertises itself through Bonjour, omit `--server`:

```sh
swift run scannerserver-worker --name "Mac Studio" --cpus 11 --jobs 1
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
active processor count minus one so macOS retains one processor for interactive work. The `--cpus`
value describes future container capacity; no OCR container is started in the current slice.

The registration and heartbeat API currently accepts HTTP because the main service has no TLS
termination contract. Run it only on a trusted network. Document transfer must not be enabled
without an authenticated transport design appropriate for potentially sensitive scans.

## Protocol

The current protocol version is `1`:

```text
POST /api/ocr-workers/register
POST /api/ocr-workers/{worker-id}/heartbeat
GET  /api/ocr-workers
```

The browser approval controls use server-rendered form routes under `/workers/{worker-id}/...`.
The public listing contains worker metadata and status but never authentication tokens.

## Next Vertical Slices

1. Let workers hold a long poll for assignments and stream verified source files from scannerserver.
2. Add a batch document-processing command to the existing container image and invoke it with an
   explicit CPU and memory allocation.
3. Upload results to a temporary server path, verify their digest and expected type, and atomically
   publish them using the existing output names.
4. Propagate cancellation, reclaim abandoned work through the lease store, and fall back to local
   processing.

Initially, one multipage document should be assigned to one worker. More workers increase throughput
across queued documents. Cross-machine page sharding is a separate compatibility project because it
must preserve page order, metadata, PDF/A behavior, and failure atomicity.
