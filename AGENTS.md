---
name: spm-local-scansnap-linux
description: Guidance for working on the current ScanSnap Linux Swift package. Use when changing Package.swift, Sources or Tests, ScanSnap protocol code, scan/OCR orchestration, container packaging, compose files, or project documentation.
---

# ScanSnap Linux SwiftPM

## Overview

This package is the Swift 6.3, Linux-first, containerized replacement for the former Python scannerserver. The production service and default container have already migrated to Swift.

Use this skill together with `spm-multiplatform-swift-package`, `swift-linux-service`, `swift-concurrency`, and `swift-testing-expert` when those topics apply.

Read `docs/architecture.md` before broad source changes. It is the normative description of the current service. `docs/history/swift-migration.md` is historical evidence only and must not be treated as an active plan or backlog.

## Task Interpretation

- Verify a task's premise against the current tree and recent history before starting a broad rewrite.
- If a request assumes the Python service still exists or the Swift migration is incomplete, report the stale premise and restrict work to genuine remaining cleanup.
- Treat an unqualified “cleanup” as behavior-preserving removal of dead files, generated artifacts, obsolete documentation, duplication, or clearly unused code.
- Do not change runtime orchestration, actor ownership, public API, external contracts, or working subsystems under the label of cleanup. Those changes require explicit authorization.

## Compatibility Contract

- Preserve the container contract: image name, host networking assumptions, ports `80`/`8080`, `/scans` volume, non-root runtime, existing environment variable names, and compose examples.
- Preserve output names and state files: `/scans/.scanner-settings.json`, `/scans/.scannerserver-scanner.json`, `YYYY-MM-DD.HHMMSS.pdf`, `.ocr.pdf`, single-page PDF names, PNG exports, and `.previews`.
- Use Docker commands in documentation and workflows.
- Keep the current ScanSnap iX500 Wi-Fi protocol behavior unless explicitly changing it. The protocol notes in `docs/protocol.md` are part of the implementation contract.

## Package Shape

- Use `// swift-tools-version: 6.3`.
- Use Swift 6 language mode and strict concurrency for every target unless a blocker is documented.
- Keep the executable target thin. Put scan protocol, settings, file grouping, queues, button handling, and post-processing orchestration in a library target.
- Prefer actors or isolated runtime types for mutable service state: scan job state, OCR queue, discovery state, scanner config, settings, and button arming.
- Use Swift Testing for package tests. Keep hardware/network integration tests opt-in.

## Current Architecture And History

Use `docs/architecture.md` for current package boundaries, dependency strategy, compatibility contracts, and validation requirements.

Use `docs/history/swift-migration.md` only when historical migration evidence is relevant. The migration milestones are complete. ScanSnap Wi-Fi acquisition and PDF assembly are native Swift. The service intentionally retains SANE, Tesseract, OCRmyPDF, qpdf, Poppler, libvips, ExifTool, and `img2pdf` for optional-backend, OCR, and document-processing work; replacing them is separate follow-up work.

## Validation

- Run `swift build` after manifest, dependency, or source changes.
- Run `swift test` for library behavior.
- Build the image with `docker build` after container file changes.
- Run an HTTP smoke test against the local container before replacing deployment docs.
- Keep scanner hardware tests documented and opt-in so CI can run without a real iX500.
