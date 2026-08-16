---
title: Current Architecture
description: Current Swift service boundaries, compatibility contracts, dependency strategy, and validation requirements.
type: reference
audience: maintainers and agents
status: current
---

# Current Architecture

`scannerserver` is already a production Swift 6.3 Linux service. The former project-owned Python
server and helper scripts are gone. Python remains in the container only as a transitive runtime for
OCRmyPDF, which is an intentional external-tool dependency.

This document is normative for current implementation work. The completed migration record under
[`history/swift-migration.md`](history/swift-migration.md) is evidence and history, not a backlog.

## Scope Gate

Before making a broad change, inspect the current tree, recent commits, and this document. If a task
assumes the Python service still exists or that the Swift migration is unfinished, report that the
premise is stale and limit work to genuine remaining cleanup.

In this repository, an unqualified “cleanup” means removing dead files, generated artifacts,
obsolete documentation, duplication, or clearly unused code without changing observable behavior.
It does not authorize:

- redesigning runtime orchestration or actor ownership;
- contracting or expanding the Swift library API;
- changing HTTP, persisted-data, file-naming, container, or ScanSnap protocol contracts;
- replacing external tools or rewriting working subsystems.

Those changes require an explicit request and validation appropriate to the affected contract.

## Package Boundaries

```text
Package.swift
Sources/
  scannerserver/          thin ArgumentParser entry point
  ScannerServerCore/
    Runtime/              service lifecycle and composition
    HTTP/                 Hummingbird routes and web resources
    ScanSnap/             discovery, pairing, transport, setup, and button protocol
      Acquisition/        native JPEG transfer state machine and PDF assembly
    ScanPipeline/         single-flight scans, acquisition, subprocesses, and OCR queue
    OCRWorkers/           remote-worker registry, discovery, manifests, and lease state
    Documents/            PDF/image processing, previews, naming, and grouping
    Settings/             persisted scanner and mode configuration
tests/
  ScannerServerCoreTests/ Swift Testing suites and opt-in integration coverage
```

The executable owns command-line parsing, startup configuration, signal handling, and top-level
runtime startup. Reusable behavior and mutable service state belong in `ScannerServerCore`. Use
actors or otherwise isolated runtime types for scan jobs, OCR work, scanner discovery/setup,
persisted stores, reachability, and physical-button session state.

## Runtime Boundaries

- Hummingbird and SwiftNIO provide the HTTP service.
- `ScanJobActor` enforces single-flight acquisition, publishes a multipage source PDF or hands a
  captured single-page/PNG document to the background queue, and ends the scanner lifecycle before
  document processing begins.
- `OCRQueueActor` is the compatibility-named background document-processing queue. It schedules
  blank-page removal, autocrop, and optional OCR against one cgroup-aware CPU budget while reserving
  one detected processor for acquisition and HTTP work. Deferred single-page PDF and PNG jobs keep
  global blank removal and crop semantics before publishing their final files, then schedule
  per-file OCR. Multipage OCR gives the budget to OCRmyPDF's page workers, while page analysis and
  single-page OCR are bounded concurrently. Remote-capable OCR admission uses the sum of every
  online approved worker's advertised concurrent page slots plus the internal OCR capacity when it
  is unpaused. Remote slots are assigned first and any added internal slots are explicitly kept
  local, avoiding remote queueing while scanner-host CPUs sit idle. A shared weighted local-capacity
  pool separately gates queue-owned processing and distributed OCR fallback, so losing remote
  workers cannot oversubscribe the scanner host. When reduced priority is enabled, the queue applies the
  configured nice level to every external document-processing subprocess; the service and scanner
  acquisition remain at normal priority. The queue exposes aggregate running/queued state, targeted
  cancellation, and recent jobs.
- For OCR-enabled multipage ScanSnap Wi-Fi scans, acquisition calls the queue after every accepted
  JPEG side. The queue immediately creates and schedules a one-page PDF, owns the private scan
  workspace after raw publication, receives each remote result independently, and assembles pages
  in source order. It reserves each page in actor-isolated batch state before the asynchronous PDF
  writer runs, so an earlier page completion cannot be overwritten by a stale pre-suspension batch
  snapshot. Workers advertising the relevant capabilities run the same native autocrop and blank
  filtering after OCR on each page; an unavailable or failed remote worker falls back to local OCR
  and the same per-page operations. The scanner host retains the all-blank keep-one safeguard,
  creator metadata, and exclusive `.ocr.pdf` publication. The Workers page reports this
  document-finalization phase separately instead
  of continuing to show the already completed final OCR page as worker activity. This streaming
  path retains the raw PDF, local fallback, cancellation, CPU
  budgeting, crop settings, and failure atomicity contracts. SANE acquisition still enters the
  established whole-document path.
- `OCRWorkerRegistry` is the persistent control-plane registry for optional remote OCR workers. It
  owns registration authentication, explicit approval, enablement, heartbeat state, and UI
  snapshots.
- `OCRWorkerJobStore` owns atomically persisted remote-job manifests and FIFO lease transitions,
  including capability filtering, renewal, authenticated completion, cancellation, and recovery of
  expired leases. Server startup cancels nonterminal manifests because their owning in-memory queue
  tasks cannot survive a process restart, and document deletion cancels manifests by their
  user-facing document metadata as well as direct paths. Authenticated HTTP routes lease jobs and
  transfer digest-verified PDFs. Optional manifest metadata identifies the user-facing document,
  streaming batch, page number, and requested operations without breaking persisted jobs from the
  original protocol shape.
- `DistributedOCRProcessExecutor` wraps the `ocrmypdf` process boundary and carries an optional
  typed per-page crop configuration. Approved, enabled, language- and capability-compatible worker
  registrations get first refusal even across a temporary heartbeat outage; assignment timeout or
  remote failure preserves local OCR plus local per-page crop as the safety fallback. The persisted
  internal-worker control can pause that fallback, cancel active local OCR, and keep the same work
  dispatchable so newly available remote capacity can take over. Older OCR-only workers cannot lease
  crop or blank-filter jobs unless they advertise the matching capability. Paused workers are
  excluded from dispatch, and pausing immediately requeues their active
  leases so another worker can claim them; stale renewals and results are rejected. Completed jobs
  retain their worker and lease-start time for per-page throughput statistics. The worker either
  runs OCRmyPDF followed by the native crop implementation when the worker itself is the production
  container, or runs that combined operation in the existing image through Apple Container from the
  native macOS executable. Both modes isolate each job in its own workspace and use the worker
  CPU count as page capacity: each concurrent one-page job receives one CPU and OCRmyPDF `--jobs 1`.
  An optional worker-side concurrency cap can deliberately leave capacity unused for memory or
  thermal limits. Each worker has one long-polling lease dispatcher, which fills that capacity with
  structured child tasks, while registration and heartbeats use an independent HTTP session so
  pending lease requests cannot starve liveness. The server verifies results with SHA-256 and
  `qpdf --check`, then atomically publishes them before reporting OCR completion.
- The Workers page combines persisted remote lease state with actor-isolated local queue snapshots.
  It always exposes the internal fallback worker, current waiting/running work, compact terminal
  history, and successful pages-per-minute measurements without exposing authentication or lease
  tokens.
- `OCRWorkerBonjourPublisher` optionally owns a cancellable `avahi-publish-service` subprocess for
  `_scannerserver._tcp`. The macOS worker uses Network.framework to browse compatible TXT records;
  an explicit server URL remains available and takes precedence over Bonjour.
- The ScanSnap button lifecycle retains the scanner notification session, coordinates heartbeat
  handoff during scans, and performs recovery after failed or cancelled acquisition.
- `/updates` uses a revision-backed long poll; do not add an independent browser polling loop for
  state already covered by that notifier.
- Blocking subprocess pipe reads and `waitpid` calls stay off Swift’s cooperative executor.

## External Tool Boundary

The always-running service, complete ScanSnap Wi-Fi protocol, JPEG acquisition, PDF assembly,
orchestration, settings, and document-processing decisions are Swift. SANE, Tesseract/OCRmyPDF,
qpdf, Poppler, libvips, ExifTool, and `img2pdf` remain external tools because they preserve
established optional-backend, OCR, and document-processing behavior. Replacing one is a separate
compatibility project.

## Compatibility Contracts

Preserve these unless the user explicitly authorizes a breaking change:

- image name, host networking, ports `80` and `8080`, arbitrary non-root UID/GID operation, and the
  `/scans` volume;
- documented environment variable names and Compose examples;
- `/scans/.scanner-settings.json` and `/scans/.scannerserver-scanner.json` schemas;
- `YYYY-MM-DD.HHMMSS.pdf`, `.ocr.pdf`, single-page PDF, PNG, and `.previews` naming;
- existing HTTP routes, form workflows, scan visibility, OCR cancellation, and file operations;
- ScanSnap discovery, pairing, port, packet, retained-session, heartbeat, and recovery behavior.

See [`configuration.md`](configuration.md), [`deployment.md`](deployment.md), and
[`protocol.md`](protocol.md) for the detailed contracts.

## Validation

Choose checks from the changed layer:

| Changed layer | Required validation |
| --- | --- |
| Documentation only | YAML front matter, local links, and `git diff --check` |
| Swift source or tests | `swift build` and `swift test` |
| Container files or packaged tools | `docker build --tag scannerserver:local .` |
| Deployment behavior | `CONTAINER_COMMAND=docker ./scripts/smoke_swift_container.sh scannerserver:local` |
| ScanSnap protocol/session behavior | Unit tests plus the opt-in real-hardware checklist |

Hardware tests remain opt-in. Unit tests alone cannot certify scanner-session or wire-protocol
changes; follow [`swift-hardware-validation.md`](swift-hardware-validation.md) before publishing them.
