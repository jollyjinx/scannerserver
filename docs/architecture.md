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
    ScanPipeline/         single-flight scans, acquisition, subprocesses, and OCR queue
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
- `ScanJobActor` enforces single-flight acquisition, publishes the multipage source PDF, and ends
  the scanner lifecycle before document processing begins.
- `OCRQueueActor` is the compatibility-named background document-processing queue. It schedules
  blank-page removal, autocrop, and optional OCR against one cgroup-aware CPU budget while reserving
  one detected processor for acquisition and HTTP work. Multipage OCR gives the budget to
  OCRmyPDF's page workers, while page analysis and single-page OCR are bounded concurrently. It
  exposes aggregate running/queued state, targeted cancellation, and recent jobs.
- The ScanSnap button lifecycle retains the scanner notification session, coordinates heartbeat
  handoff during scans, and performs recovery after failed or cancelled acquisition.
- `/updates` uses a revision-backed long poll; do not add an independent browser polling loop for
  state already covered by that notifier.
- Blocking subprocess pipe reads and `waitpid` calls stay off Swift’s cooperative executor.

## External Tool Boundary

The always-running service, protocol handling, orchestration, settings, and document-processing
decisions are Swift. SANE, Tesseract/OCRmyPDF, qpdf, Poppler, libvips, ExifTool, `img2pdf`, and the
`scansnap-wifi` acquisition binary remain external tools because they preserve established output
and hardware behavior. Replacing one is a separate compatibility project.

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
