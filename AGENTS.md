---
name: spm-local-scansnap-linux
description: Guidance for working on the local ScanSnap Linux Swift Package migration. Use when changing Package.swift, Sources or Tests for scannerserver, ScanSnap iX500 Wi-Fi protocol code, scan/OCR pipeline orchestration, Linux container packaging, compose files, or migration docs in /Users/jolly/git/ScanSnap Linux.
---

# ScanSnap Linux SwiftPM

## Overview

This package is intended to become a Swift 6.3, Linux-first, containerized drop-in replacement for the existing Python scannerserver in `/Users/jolly/git/ScanSnap Linux`.

Use this skill together with `spm-multiplatform-swift-package`, `swift-linux-service`, `swift-concurrency`, and `swift-testing-expert` when those topics apply.

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

## Migration Plan

Start from `docs/swift-migration-plan.md`. Update that plan when implementation decisions change.

The first migration milestone should keep native external tools such as SANE, Tesseract, OCRmyPDF, qpdf/poppler-like utilities, and the existing ScanSnap C implementation only where needed to preserve behavior. Later milestones can replace those subprocesses with Swift or C-library integrations after the drop-in service is stable.

## Validation

- Run `swift build` after manifest, dependency, or source changes.
- Run `swift test` for library behavior.
- Build the image with `docker build` after container file changes.
- Run an HTTP smoke test against the local container before replacing deployment docs.
- Keep scanner hardware tests documented and opt-in so CI can run without a real iX500.
