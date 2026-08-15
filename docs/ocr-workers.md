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
  heartbeats. They can be paused temporarily or disabled without forgetting their approval.
- Registrations and approvals are stored atomically in
  `/scans/.scannerserver-ocr-workers.json` by default.
- `OCRWorkerJobStore` provides an atomically persisted manifest and lease state machine at
  `/scans/.scannerserver-ocr-jobs.json`. It supports FIFO capability matching, opaque lease tokens,
  renewal, authenticated terminal transitions, cancellation, and restart-safe lease expiry.
- `OCRQueueActor` gives approved, enabled, compatible workers first refusal on `ocrmypdf` commands,
  including when a registered worker is temporarily offline. Blank-page removal, autocrop, scan
  acquisition, naming, and final publication stay on scannerserver.
- Multipage ScanSnap Wi-Fi scans are streamed page by page. Each accepted JPEG is wrapped in a
  one-page PDF and queued before the scanner transfers the next page. Completed one-page OCR
  results are uploaded immediately, retained in the scan workspace, and assembled in source order
  after the feeder is empty. The raw `.pdf` remains independently published; blank removal,
  trimming, creator metadata, and atomic `.ocr.pdf` publication happen after ordered assembly.
  The SANE backend remains whole-document because `scanimage` does not expose the same page-arrival
  callback.
- The worker downloads a size- and SHA-256-verified PDF, runs OCRmyPDF directly in worker-container
  mode or starts the existing image with Apple `container` in native macOS mode, and uploads the
  result through its authenticated lease.
- scannerserver requires a PDF result, calculates its SHA-256 digest, writes it to a same-directory
  staging file, validates it with `qpdf --check`, and atomically publishes the established
  `.ocr.pdf` output name.
- No approved and enabled compatible worker, assignment timeout, or reported worker failure falls
  back to the existing local OCR executor. Cancellation invalidates the remote lease.

## Run A Worker Container

The production image contains both `scannerserver` and `scannerserver-worker`. Start the worker by
overriding the image's default command:

```sh
docker run -d \
  --name scannerserver-worker \
  --restart unless-stopped \
  --cpus 11 \
  --memory 8g \
  --volume scannerserver-worker-state:/home/scansnap/.config/scannerserver-worker \
  gitmaster.jinx.eu/jnxpublic/scannerserver:jinx \
  scannerserver-worker \
  --server http://SCANNERSERVER-IP \
  --name "Mac Studio" \
  --jobs 1
```

The image enables direct execution automatically: OCRmyPDF runs inside the worker container, so no
Docker socket, privileged mode, or nested container is needed. The worker detects Docker's cgroup
CPU allowance; `--cpus 11` therefore advertises and uses 11 CPUs. Its named volume retains the
worker identity and scannerserver approval when the container is replaced.

If scannerserver is another container on the same Docker network, use its service name in
`--server`. To reach a scannerserver published on the Docker host, use
`http://host.docker.internal:PORT` on Docker Desktop.

Open the **Workers** page on scannerserver and approve the new worker. `--jobs` controls concurrent
page or document jobs, and the detected CPUs are divided across those slots. With the recommended
`--jobs 1`, one OCR page can use the entire container CPU allowance while additional network workers
consume other queued pages. The page includes the scannerserver's internal fallback worker,
highlights processing workers, reports successful page count and average seconds per page, and shows
waiting, running, and recent terminal work in compact lists with document, page, operations, worker,
timing, and result details.

**Pause** temporarily removes a remote worker from dispatch and immediately returns its active
leases to the queue. Another compatible worker can claim them without waiting for lease expiry. The
paused process remains registered and continues heartbeating; if it is still processing an old
lease, its next renewal or upload is rejected and that work is discarded. **Resume** makes it
eligible again. **Disable** remains the administrative off switch.

Deleting a worker removes its persisted registration and approval. If that worker process is still
running, it registers again with the same identity and must be approved again.

## Native macOS Worker

The native executable remains useful when Apple Container should isolate each OCR job. Start the
Apple Container system, pull the OCR image, and run the worker from this repository:

```sh
container system start
container system kernel set --recommended  # only when no default kernel is configured
container image pull gitmaster.jinx.eu/jnxpublic/scannerserver:jinx
swift run -c release scannerserver-worker \
  --server http://SCANNERSERVER-IP \
  --name "Mac Studio" \
  --cpus 11 \
  --jobs 1 \
  --container-image gitmaster.jinx.eu/jnxpublic/scannerserver:jinx \
  --memory-per-job 8G
```

When scannerserver advertises itself through Bonjour, omit `--server`:

```sh
swift run -c release scannerserver-worker \
  --name "Mac Studio" \
  --cpus 11 \
  --jobs 1 \
  --container-image gitmaster.jinx.eu/jnxpublic/scannerserver:jinx
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

The native command defaults to the active processor count minus one so macOS retains one processor
for interactive work.

Useful worker overrides:

```text
--container-runtime container
--container-image gitmaster.jinx.eu/jnxpublic/scannerserver:jinx
--memory-per-job 8G
--workspace ~/Library/Caches/scannerserver-worker/jobs
--direct-ocr
```

Stop a foreground native worker with Control-C. Its identity remains in
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

The browser approval, pause/resume, enable/disable, and delete controls use server-rendered form
routes under `/workers/{worker-id}/...`.
The public listing contains worker metadata and status but never authentication tokens.

Remote manifests may carry optional document, batch, page, and operation metadata. Older persisted
jobs without these fields remain decodable. ScanSnap Wi-Fi page sharding preserves source order and
publishes the assembled `.ocr.pdf` only when every page has completed successfully; cancellation or
failure removes the private scan workspace without replacing the already published raw PDF.
