---
title: Swift Migration Plan
description: Plan for migrating scannerserver to a Swift 6.3 Linux service while preserving the container contract.
type: plan
audience: maintainers
status: current
---

# Swift Migration Plan

## Goal

Replace the long-running Python scannerserver with a Swift 6.3 Linux service that remains a drop-in container replacement for current users.

The replacement keeps the same image purpose, ports, environment variables, `/scans` volume layout, setup files, scan output names, web workflows, physical button support, and compose examples. Reducing resident runtime cost comes first; replacing every native helper or OCR dependency can happen after the service boundary is stable.

Implementation and container cutover are complete. Discovery, scanner selection, pairing, persisted configuration, TCP reachability, and the UDP button listener have been exercised against the project iX500. A physical scan, OCR result, and button press remain release acceptance tasks because they require interaction with the scanner and the complete Linux acquisition toolchain.

## Progress

| Milestone | Status |
| --- | --- |
| Baseline, package skill, and compatibility contract | Complete |
| SwiftPM scaffold and Swift 6.3 service | Complete |
| Settings, HTTP UI, and route parity | Complete |
| Scan pipeline and OCR queue | Complete |
| Native ScanSnap discovery, pairing, and button runtime | Complete |
| Native document and preview helpers | Complete |
| Default container cutover | Complete |
| Physical scan, OCR, and button acceptance | Pending manual validation |

## Measured Baseline

Measurements use the ARM64 production containers at idle after the index and health routes have been requested. RSS is read from `/proc/1/status`; image size is reported by `container image list --verbose`.

| Runtime | Idle RSS | Threads | Compressed image |
| --- | ---: | ---: | ---: |
| Python baseline | 50,164 kB | 2 | 166.3 MB |
| Swift 6.3.2 production image | 35,912 kB | 13 | 259.8 MB |

The Swift service reduces idle RSS by 28.4%. The image is 93.5 MB larger because it includes the Swift runtime and native qpdf, Poppler, libvips, and ExifTool tooling while retaining OCRmyPDF and its transitive Python runtime for on-demand OCR. No production server, orchestration, button, preview, or document-helper path executes a project Python script.

The container build pins the official Swift 6.3.2 Noble images. Swift 6.3.3 on ARM64 crashes in the compiler while expanding `@TaskLocal` in `swift-service-context`; the same dependency graph builds successfully with 6.3.2. The package remains `swift-tools-version: 6.3` and Swift 6 language mode.

## Non-Negotiable Compatibility

- Keep the `ghcr.io/jollyjinx/scannerserver` image contract and the `scannerserver` container name examples.
- Keep host-network deployment working because ScanSnap discovery depends on LAN UDP traffic.
- Keep `WEB_PORT`, `SCAN_OUTPUT_DIR`, `SCAN_SETTINGS_PATH`, `SCANNER_CONFIG_PATH`, `SCAN_BACKEND`, `SCAN_LANGUAGE`, scan mode variables, `SCANNER_IP`, `SCANSNAP_PAIRING_KEY`, `SCANSNAP_CLIENT_IP`, discovery variables, and button variables.
- Keep `/scans/.scanner-settings.json` and `/scans/.scannerserver-scanner.json` readable by the migrated service.
- Keep output naming: `YYYY-MM-DD.HHMMSS.pdf`, `YYYY-MM-DD.HHMMSS.ocr.pdf`, `YYYY-MM-DD.HHMMSS-page-0001.pdf`, page OCR variants, PNG exports, and `.previews`.
- Keep the web UI workflows: first-run scanner setup, manual scanner setup, scan start, mode save/delete/default, grouped scan list, preview, download, delete, OCR status, and physical button scans.
- Use `container` in docs and normal workflows. Use `docker` only where a required option is unavailable through `container`, such as a documented buildx publishing path.

## Architecture

Create a SwiftPM package with `// swift-tools-version: 6.3`, Swift 6 language mode, and strict concurrency enabled for all targets.

Proposed package shape:

```text
Package.swift
Sources/
  scannerserver/
    scannerserver.swift
  ScannerServerCore/
    Runtime/
    HTTP/
    ScanSnap/
    ScanPipeline/
    Documents/
    Settings/
    Files/
    Resources/
Tests/
  ScannerServerCoreTests/
```

The executable target owns command-line parsing, environment loading, signal setup, HTTP server startup, and runtime wiring. The library owns scanner discovery, pairing, button handling, scan orchestration, OCR queueing, settings persistence, file grouping, preview generation, and testable domain logic.

Prefer a lightweight SwiftNIO-based HTTP layer. Hummingbird should be evaluated first because this service needs simple routes and low overhead, not a large web framework. Use `swift-argument-parser` for CLI options and `JLog` for service logs unless implementation work finds a strong reason to stay with SwiftLog.

## Dependency Strategy

Swift cannot use PDFKit on Linux, and OCRmyPDF is itself Python-based. The implemented boundary is:

1. The always-running HTTP service, button coordinator, ScanSnap protocol logic, scan orchestration, settings, and document-processing decisions are Swift.
2. SANE, Tesseract/OCRmyPDF, qpdf, Poppler, libvips, ExifTool, `img2pdf`, and the existing `scansnap-wifi` acquisition binary remain subprocess tools.
3. Project-owned Python and scan-orchestration shell helpers are removed from the production image and repository.
4. Direct replacement of OCRmyPDF is deferred because matching searchable PDF quality is a separate project and Python is not resident while the service is idle.

## Milestones

### 0. Baseline And Skill

- Add a package-specific global skill for this project so future SwiftPM work has local context.
- Capture the current compatibility contract in tests before changing the runtime.
- Record current image size and idle memory usage for comparison.

### 1. SwiftPM Scaffold

- Add `Package.swift` with Swift 6.3, executable and library products, strict concurrency, Swift Testing, ArgumentParser, and the selected HTTP dependency.
- Add a minimal runtime that serves health and index placeholders on `WEB_PORT`.
- Add a multi-stage Swift 6.3 container file while keeping the existing image runnable during migration.

Acceptance:

- `swift build` and `swift test` pass.
- `container build` succeeds for the Swift image.
- A local container responds on the configured web port.

### 2. Model And Settings Parity

- Port environment parsing, truthy handling, scanner config load/save, scan settings normalization, built-in modes, mode summary, and mode edit/delete/default behavior.
- Keep JSON file shape compatible with existing deployments.
- Add Swift Testing coverage matching current settings and config behavior.

Acceptance:

- Existing `.scanner-settings.json` and `.scannerserver-scanner.json` examples load without migration.
- Swift tests cover defaults, invalid data recovery, mode IDs, pairing key derivation, and IPv4/MAC normalization.

### 3. HTTP UI Parity

- Port the Flask routes to Swift routes.
- Render the current HTML/CSS from Swift templates or typed HTML builders.
- Preserve route paths and form field names.
- Keep previews/download/delete behavior compatible.

Acceptance:

- Browser smoke test covers first-run setup screen, mode form, scan button disabled/configured states, file list, preview endpoint, and delete forms.
- Routes keep the same methods and paths unless explicitly documented.

### 4. Scan Pipeline

- Replace the legacy scan orchestration with Swift process execution.
- Keep the first implementation calling known-good external tools where that reduces risk.
- Preserve SANE fallback, Wi-Fi backend invocation, output naming, blank-page removal, crop, metadata, split, PNG export, and OCR queue semantics.
- Replace tiny Python JSON parsing in the shell path with Swift config loading.

Acceptance:

- Dry-run or fixture-backed tests cover command construction and output path parsing.
- Hardware-required scanning tests are opt-in and documented.
- Scan state and OCR queue are actor-isolated and cancellation-aware.

### 5. ScanSnap Protocol And Button Support

- Port VENS packet parsing, discovery, registration, pairing-key derivation, manual lookup, release, button arming, and UDP button listener to Swift.
- Keep retry and session-busy behavior from the current implementation.
- Keep `SCANSNAP_CLIENT_IP`, `SCANSNAP_CLIENT_MAC`, `SCANSNAP_CLIENT_INTERFACE`, source port, registration port, and button timing variables.

Acceptance:

- Unit tests cover packet builders/parsers with fixture bytes.
- Button coordinator tests cover non-blocking start, drain result, debounce, cooldown, and re-arm scheduling.
- Hardware integration test instructions document how to validate against a real iX500.

### 6. PDF, Preview, And OCR Helpers

- Decide per helper whether Swift plus native libraries, qpdf/poppler/mupdf CLI, or a temporary compatibility helper is the best first replacement.
- Port or replace crop, blank-page removal, PDF splitting, PNG export, PDF creator metadata, and preview generation.
- Keep OCRmyPDF initially unless a direct Tesseract pipeline can match output quality.

Acceptance:

- Fixture tests preserve the current crop result for `tests/fixtures/receipt-small-page.pdf`.
- Tests cover blank-page removal thresholds, split names, PNG naming, metadata, and preview fallback.

### 7. Container Cutover

- Switch the production image to the Swift executable.
- Remove Python runtime packages only after no production path imports Python.
- Keep OCRmyPDF/Tesseract packages as long as OCR uses OCRmyPDF.
- Update README, deployment docs, compose files, and build scripts.

Acceptance:

- `container compose up -d --build` works from a clean checkout.
- Existing `container run` command still works.
- Scan directory ownership and non-root port binding still work.
- Docs contain no stale `docker` command unless the section explains why Docker-only functionality is needed.

## Test Plan

- Swift unit tests for parsing, settings, file grouping, output naming, protocol packet construction, protocol packet parsing, and state machines.
- Swift async tests for scan job locking, OCR queue ordering, button arm scheduling, cancellation, and signal/log-level helpers.
- Fixture tests for PDF/image post-processing with deterministic sample files.
- Route-level tests for methods, redirects, response codes, and form field compatibility.
- Container smoke test for startup, port binding, `/scans` write access, and health/index routes.
- Manual hardware test checklist for iX500 discovery, setup, scan, button press, OCR, and update flow.

## Subagent Work Split

Use subagents for independent slices with disjoint write scopes.

- Scanner protocol agent: own `Sources/ScannerServerCore/ScanSnap/`, protocol fixtures, and protocol tests.
- HTTP/settings agent: own `Sources/ScannerServerCore/HTTP/`, `Sources/ScannerServerCore/Settings/`, route tests, and UI template resources.
- Scan pipeline agent: own `Sources/ScannerServerCore/ScanPipeline/`, process execution, OCR queue, and command-construction tests.
- PDF/container agent: own `Sources/ScannerServerCore/Documents/`, container files, package resource copying, and deployment doc updates.

The main agent should own integration, `Package.swift`, final container cutover, and compatibility review.
