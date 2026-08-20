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
    Documents/            visible collection lifecycle, processing, previews, naming, and grouping
    Settings/             persisted scanner and mode configuration
tests/
  ScannerServerCoreTests/ Swift Testing suites and opt-in integration coverage
```

The executable owns command-line parsing, startup configuration, signal handling, and top-level
runtime startup. Reusable behavior and mutable service state belong in `ScannerServerCore`. Use
actors or otherwise isolated runtime types for scan jobs, OCR work, scanner discovery/setup,
persisted stores, reachability, and physical-button session state.

## Runtime Boundaries

- `ScanDocumentCollection` is the actor-isolated boundary for browser-visible scan outputs. It
  discovers and groups regular PDF/PNG files, validates and reads requested outputs, delegates
  preview generation, and coordinates cancellation before removing an output and its preview
  sidecar. Scan and OCR publishers retain their atomic file-publication contracts; newly published
  outputs appear in the next collection snapshot.
- Hummingbird and SwiftNIO provide the HTTP service.
- `ScanJobActor` enforces single-flight acquisition, publishes a multipage source PDF or hands a
  captured single-page/PNG document to the background queue, and ends the scanner lifecycle before
  document processing begins. `NativeScanExecuting` returns `NativeScanResult`, whose typed
  post-processing disposition distinguishes queue-owned published outputs, deferred processing,
  and streaming work that was already handed off. Generic subprocess results no longer carry scan
  lifecycle state.
- `OCRQueueActor` is the compatibility-named background document-processing queue. It schedules
  blank-page removal, autocrop, and optional OCR against one cgroup-aware CPU budget while reserving
  one detected processor for acquisition and HTTP work. Deferred single-page PDF and PNG jobs keep
  global blank removal and crop semantics before publishing their final files, then schedule
  per-file OCR. Under `SCAN_OCR_ONLY`, deferred PDF jobs split into the private scan workspace,
  publish only the OCR results, and remove the workspace once the queue empties; failed pages or a
  failed whole-document pass publish the raw PDF as a fallback, and a fallback that cannot be
  published keeps the workspace and reports the error. Multipage OCR gives the budget to OCRmyPDF's page workers, while page analysis and
  single-page OCR are bounded concurrently. Remote-capable OCR admission uses the sum of every
  online approved worker's advertised concurrent page slots plus the internal OCR capacity when it
  is unpaused. Remote slots are assigned first and any added internal slots are explicitly kept
  local, avoiding remote queueing while scanner-host CPUs sit idle. A shared weighted local-capacity
  pool gates queue-owned processing and typed OCR local fallback, so losing remote workers cannot
  oversubscribe the scanner host. When preprocessing hands a job to OCR, the queue releases its
  reservation before the OCR execution module acquires the same shared pool; ownership is never
  duplicated. When reduced priority is enabled, the queue applies the
  configured nice level to every external document-processing subprocess; the service and scanner
  acquisition remain at normal priority. The queue owns FIFO admission, CPU and worker-capacity
  selection, page-process task cancellation, and recent per-page timing, but not ordering-sensitive
  document assembly or publication policy. It exposes aggregate running/queued state and composes
  the document module's finalization state into the compatibility status snapshot.
- `StreamingOCRDocumentModule` is the package-scoped actor for page-oriented OCR document state.
  It owns document creation, page reservation and typed completion, sealing, source-order assembly,
  the all-blank keep-one safeguard, creator metadata, exclusive publication, origin-specific failure
  policy, cancellation invalidation, and workspace cleanup. Finalization runs in an owned task that
  may only create a staging PDF in the private workspace. The actor records an opaque generation
  before that task suspends and revalidates it when the task returns; only the actor may perform the
  synchronous exclusive publication commit. Cancellation invalidates the generation before queue
  work is cancelled, so a late page or finalizer result cannot publish a deleted document.
- For OCR-enabled multipage ScanSnap Wi-Fi scans, acquisition calls the queue after every accepted
  JPEG side. The document module reserves each page before the asynchronous PDF
  writer runs, so an earlier page completion cannot be overwritten by a stale pre-suspension batch
  snapshot, then the queue schedules the returned one-page work immediately. Workers advertising
  the relevant capabilities run the same native autocrop and blank
  filtering after OCR on each page; an unavailable or failed remote worker falls back to local OCR
  and the same per-page operations. The scanner host retains the all-blank keep-one safeguard,
  creator metadata, and exclusive `.ocr.pdf` publication. With `SCAN_OCR_ONLY`, the raw PDF stays
  private and is removed once the assembled `.ocr.pdf` is published; OCR or document-processing
  failure publishes the raw PDF as a fallback instead of losing the scan, while cancellation
  publishes nothing. If that fallback cannot be published, the raw PDF remains in the private
  workspace and the error is reported. Without it, the raw PDF is published before page processing
  begins. The
  Workers page reports this
  document-finalization phase separately instead
  of continuing to show the already completed final OCR page as worker activity. This streaming
  path retains the raw PDF, local fallback, cancellation, CPU
  budgeting, crop settings, and failure atomicity contracts. SANE acquisition still enters the
  established whole-document path.
- PDFs imported through the Documents page use the same document actor and page-completion
  Interface. The module creates their private workspace, counts and splits the source with `qpdf`,
  reserves each prepared page, and yields it immediately to the queue so OCR begins before the
  complete source has been split. Imports explicitly preserve their visible source on processing
  failure; Wi-Fi OCR-only scans explicitly publish `raw.pdf` as fallback. That difference is a typed
  creation policy rather than a cleanup-time environment check.
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
- `OCRWorkerJobTransferCoordinator` is the deep boundary between those HTTP routes and the worker
  registry/job store actors. It combines worker authentication with capability- and capacity-aware
  long-poll leasing, confines source and result paths to the scan directory, verifies source bytes,
  and owns result staging, validation, atomic publication, and rollback when a lease is cancelled or
  replaced across an asynchronous validation step. The coordinator has no mutable state of its own,
  so independent transfers stay concurrent while durable transitions remain serialized by
  `OCRWorkerJobStore`.
- `OCRWorkerRuntimeModule` is the reusable worker-process lifecycle boundary. The
  `scannerserver-worker` executable retains command-line and environment parsing, worker-identity
  persistence, explicit-URL or Bonjour selection, and dependency construction, then immediately
  hands registration, approval/disabled waiting, reconnects, heartbeat supervision, leasing, and
  job-task ownership to the Core module. An activity actor serializes the heartbeat's running-job
  count. Structured session task groups bind the heartbeat, dispatcher, and every page process to
  one approved registration; loss of approval, heartbeat failure, or cancellation tears down that
  complete session before registration recovery begins. The dispatcher's single owner tracks both
  capacity and its one in-progress long poll, so it fills all advertised page slots without issuing
  simultaneous lease requests. Narrow client, processor, sleeper, and event interfaces keep this
  lifecycle testable without launching the executable.
- `OCRExecuting` is the package-scoped typed OCR boundary. `OCRExecutionRequest` carries explicit
  input/output URLs, OCR options, process context, worker metadata, optional per-page crop and
  blank-page configurations, and a remote-first or reserved-internal dispatch preference.
  `OCRExecutionResult` separates a typed success/nonzero outcome from the local/remote execution
  location; infrastructure failures and cancellation throw. `OCRExecutionModule` is an immutable,
  `Sendable` policy object that owns remote-first selection, protocol-v1 manifest construction,
  assignment and completion waiting, timeout/cancellation handling, internal-worker pause and
  takeover behavior, shared local-capacity acquisition, and local fallback. Approved, enabled,
  language- and capability-compatible worker
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
- `LocalOCRProcessAdapter` is the only server-side boundary that translates typed OCR requests into
  OCRmyPDF arguments. It also owns local crop and blank-page post-processing, including the same
  environment, working-directory, reduced-priority, nonzero-exit, and cancellation behavior.
  `ProcessExecutor`, `ProcessRequest`, and `ProcessResult` remain the generic subprocess adapter:
  executable, arguments, environment, working directory, timeout, nice level, exit status, stdout,
  and stderr only. They carry no OCR routing, worker metadata, document-operation configuration,
  execution location, or scan-finalization state.
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

The runtime image installs Ubuntu's OCRmyPDF package to retain its native program dependencies,
then overlays pinned OCRmyPDF `17.8.1` in the isolated `/opt/ocrmypdf` Python environment. The
image `PATH` and `/usr/local/bin/ocrmypdf` select that environment instead of Ubuntu Noble's older
Python package. `OCRMYPDF_VERSION` records the build-time pin, and the container smoke test requires
the selected executable to report the same version.

## Compatibility Contracts

Preserve these unless the user explicitly authorizes a breaking change:

- image name, host networking, ports `80` and `8080`, arbitrary non-root UID/GID operation, and the
  `/scans` volume;
- documented environment variable names and Compose examples;
- `/scans/.scanner-settings.json` (presets, button default, and shared blank-page thresholds) and
  `/scans/.scannerserver-scanner.json` schemas;
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
