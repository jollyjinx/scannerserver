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

- The `scannerserver-worker` Swift executable connects to an explicit scannerserver URL.
- Each worker creates a persistent ID and authentication token in
  `~/.config/scannerserver-worker/identity.json`.
- Registration reports its name, hostname, architecture, CPU capacity, job slots, version, and OCR
  languages.
- New workers require approval on the scannerserver **Workers** page.
- Heartbeats report liveness and running-job count. Approved workers become offline after missed
  heartbeats and can be disabled without forgetting their approval.
- Registrations and approvals are stored atomically in
  `/scans/.scannerserver-ocr-workers.json` by default.

This slice does not send documents to remote workers yet. Local `OCRQueueActor` processing remains
the only execution path until job manifests, leases, downloads, verified uploads, and cancellation
are added.

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

1. Advertise scannerserver as `_scannerserver._tcp` and add Bonjour resolution to the macOS worker,
   while retaining the explicit `--server` override.
2. Add a durable server-side job manifest and lease state machine.
3. Let workers hold a long poll for assignments and stream verified source files from scannerserver.
4. Add a batch document-processing command to the existing container image and invoke it with an
   explicit CPU and memory allocation.
5. Upload results to a temporary server path, verify their digest and expected type, and atomically
   publish them using the existing output names.
6. Propagate cancellation, expire abandoned leases, and fall back to local processing.

Initially, one multipage document should be assigned to one worker. More workers increase throughput
across queued documents. Cross-machine page sharding is a separate compatibility project because it
must preserve page order, metadata, PDF/A behavior, and failure atomicity.
