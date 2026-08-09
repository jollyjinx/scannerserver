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

Implementation, the repository’s default container cutover, and registry promotion are complete. The main-branch container workflow for commit `ecc051b` completed successfully on 2026-07-12, and release `2.0.1` was published afterward. `ghcr.io/jollyjinx/scannerserver:latest` now follows the Swift service on the default branch. Discovery, scanner selection, pairing, persisted configuration, TCP reachability, the UDP button listener, physical button scanning, source PDF publication, blank/crop processing, and searchable OCR output have been exercised against the project iX500 on the Raspberry Pi deployment.

The production ARM64 image passes its non-root container acceptance flow: health and index routes, native preview generation, deterministic SANE acquisition and PDF conversion, qpdf validation, writable bind mounts, packaged command availability, and arbitrary-UID `SCANNER_URL` setup.

Browser acceptance against that image also passes: changing the physical-button default survives navigation, the PDF view route opens the fixture, and bulk deletion removes the selected document without losing the mode setting.

The advanced mode editor persists the autocrop margin per mode, defaults it to one PDF point, and
shows inline explanations for every mode control. Legacy mode files that omit the margin inherit
the default without requiring a schema migration.

## Progress

| Milestone | Status |
| --- | --- |
| Baseline, package skill, and compatibility contract | Complete |
| SwiftPM scaffold and Swift 6.3 service | Complete |
| Settings, HTTP UI, and route parity | Complete |
| Scan pipeline and OCR queue | Complete |
| Native ScanSnap discovery, pairing, and button runtime | Complete |
| Native document and preview helpers | Complete |
| Default container cutover | Complete; main, `latest`, and release `2.0.1` published |
| Physical scan, OCR, and button acceptance | Complete |
| Main-branch registry publication | Complete on 2026-07-12 |

## Hardware Evidence

Validation on 2026-07-10 used the Mac's `vlan5` address, `10.112.10.129`. The requested deployment address, `10.112.10.6`, was not assigned to the Mac and adding it requires administrator privileges; it must not be aliased while another deployment container owns that address.

- An explicit service bind to `10.112.10.6` failed with macOS `errno 49` (`Can't assign requested address`); `arp` showed no owner for the address, and passwordless administrator access was unavailable.
- The Swift service bound to `10.112.10.129` and discovered the iX500 at `10.112.10.11`.
- Scanner selection, pairing, compatible config persistence, TCP control/data reachability, and UDP port `55265` listener startup succeeded.
- A web scan reached the native `scansnap-wifi` acquisition path and reported `Scanning...`, then `No pages scanned` because no document was available in the feeder.
- Physical button scans completed on 2026-07-10, including post-scan re-arm, source PDF download,
  blank/crop processing, searchable OCR output, and preview generation.
- Long-password pairing validation on 2026-08-09 used the iX500 at `10.112.10.11`. Its
  six-character test password derived to an 18-byte identity: the former 16-byte truncation was
  rejected with status `-1`, while the complete identity in bytes `52..<100` of the existing
  128-byte VENS frame was accepted with status `0`. The Swift builder and container-pinned
  `scansnap-wifi` helper now use the full 48-byte identity field.

After confirming `10.112.10.6` is unused, an administrator can temporarily add and later remove the requested macOS alias:

```bash
sudo ifconfig vlan5 alias 10.112.10.6 netmask 255.255.255.0
sudo ifconfig vlan5 -alias 10.112.10.6
```

## Measured Baseline

Measurements use the ARM64 production containers at idle after the index and health routes have been requested. RSS is read from `/proc/1/status`; image size is reported by `docker image list --verbose`.

| Runtime | Idle RSS | Threads | Compressed image |
| --- | ---: | ---: | ---: |
| Python baseline | 50,164 kB | 2 | 166.3 MB |
| Swift 6.3.2 production image | 36,180 kB | 11 | 259.9 MB |

The Swift service reduces idle RSS by 27.9%. The image is 93.6 MB larger because it includes the Swift runtime and native qpdf, Poppler, libvips, and ExifTool tooling while retaining OCRmyPDF and its transitive Python runtime for on-demand OCR. No production server, orchestration, button, preview, or document-helper path executes a project Python script.

The container build pins the official Swift 6.3.2 Noble images. Swift 6.3.3 on ARM64 crashes in the compiler while expanding `@TaskLocal` in `swift-service-context`; the same dependency graph builds successfully with 6.3.2. The package remains `swift-tools-version: 6.3` and Swift 6 language mode.

## Non-Negotiable Compatibility

- Keep the `ghcr.io/jollyjinx/scannerserver` image contract and the `scannerserver` container name examples.
- Keep host-network deployment working because ScanSnap discovery depends on LAN UDP traffic.
- Keep `WEB_PORT`, `SCAN_OUTPUT_DIR`, `SCAN_SETTINGS_PATH`, `SCANNER_CONFIG_PATH`, `SCAN_BACKEND`, `SCAN_LANGUAGE`, scan mode variables, `SCANNER_IP`, `SCANSNAP_PAIRING_KEY`, `SCANSNAP_CLIENT_IP`, discovery variables, and button variables.
- Keep `/scans/.scanner-settings.json` and `/scans/.scannerserver-scanner.json` readable by the migrated service.
- Keep output naming: `YYYY-MM-DD.HHMMSS.pdf`, `YYYY-MM-DD.HHMMSS.ocr.pdf`, `YYYY-MM-DD.HHMMSS-page-0001.pdf`, page OCR variants, PNG exports, and `.previews`.
- Keep the web UI workflows: first-run scanner setup, manual scanner setup, scan start, mode save/delete/default, grouped scan list, preview, download, delete, OCR status, and physical button scans.
- Keep OCR work observable and controllable: the web UI can cancel the active OCR subprocess together with queued jobs and shows bounded recent-job durations (per page when the scan mode emits one PDF per page, per document for multipage PDFs).
- Use Docker commands consistently in documentation, development workflows, smoke tests, and publishing examples.

## Architecture

The SwiftPM package uses `// swift-tools-version: 6.3`, Swift 6 language mode, and strict concurrency for all targets.

Package shape:

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

Hummingbird provides the lightweight SwiftNIO-based HTTP layer, `swift-argument-parser` owns CLI parsing, and `JLog` provides service logging.

The browser keeps one cancellable long-poll request open to `/updates`. Scan and OCR actors increment a shared revision and resume suspended requests only when visible state changes. This avoids interval polling and idle busy-waiting; the client uses a five-second reconnect backoff only after connection failure.

Fresh scanner setup synchronously hands the saved configuration to the physical-button lifecycle.
The setup response waits for the first button arming attempt, so a configured page is not exposed
during the former polling gap between the released setup probe and the persistent button session.

The button lifecycle also owns scanner online/session state. It listens for the iX500 UDP `53220`
startup advertisement, retains an armed session with a 500 ms UDP heartbeat, performs low-rate TCP
health checks, and keeps a five-minute full re-arm only as a fallback. `ScanJobActor` publishes
start/finish events for every scan origin, so web and physical-button scans both stop the heartbeat,
send the D6 release on TCP `53218`, and only then hand ownership to acquisition. They immediately
restore the notification session afterward. The five-minute safety refresh also releases the
retained session before replacing it; closing its UDP heartbeat socket does not release scanner
ownership and otherwise causes registration status `-7`.

The web UI renders that shared lifecycle reachability state in a summary at the top of the page,
beside the configured scanner name rather than inside Advanced settings. Reachability transitions
notify the existing browser long-poll, producing a green `Reachable` or grey `Not reachable`
indicator without a second network probe or a new polling loop.

While first-run setup remains unresolved, an actor-owned discovery loop continues with a bounded
retry delay alongside manual input. A single discovered scanner is paired automatically with its
serial-derived default identity; an explicit password prompt appears only after that identity is
rejected or the serial is unavailable. The browser polls a setup-only JSON state endpoint and
updates just the discovery results, preserving any manual form input. Setup revisions give
explicit user operations priority over suspended automatic discovery or pairing work.

Manual setup accepts either an IPv4 address or a host name. Host names are resolved without
blocking the setup actor, and the resolved IPv4 address is persisted so protocol packets and
physical-button source matching continue to use the iX500's IPv4-only contract.

## Dependency Strategy

Swift cannot use PDFKit on Linux, and OCRmyPDF is itself Python-based. The implemented boundary is:

1. The always-running HTTP service, button coordinator, ScanSnap protocol logic, scan orchestration, settings, and document-processing decisions are Swift.
2. SANE, Tesseract/OCRmyPDF, qpdf, Poppler, libvips, ExifTool, `img2pdf`, and the existing `scansnap-wifi` acquisition binary remain subprocess tools. The container applies a small pinned-source patch so `scansnap-wifi` sends and captures the protocol's complete 48-byte pairing-identity field.
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
- `docker build` succeeds for the Swift image.
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
- Refresh scan, OCR, and file state through the actor-backed `/updates` long-poll rather than periodic browser polling.

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
- Hand successful first-run setup directly to the button lifecycle and await initial arming instead of relying on periodic store polling.

Acceptance:

- Unit tests cover packet builders/parsers with fixture bytes.
- Button coordinator tests cover non-blocking start, drain result, debounce, cooldown, and re-arm scheduling.
- Hardware integration test instructions document how to validate against a real iX500.

### 6. PDF, Preview, And OCR Helpers

- Decide per helper whether Swift plus native libraries, qpdf/poppler/mupdf CLI, or a temporary compatibility helper is the best first replacement.
- Port or replace crop, blank-page removal, PDF splitting, PNG export, PDF creator metadata, and preview generation.
- Keep OCRmyPDF initially unless a direct Tesseract pipeline can match output quality.

Acceptance:

- Fixture tests preserve the current crop result for `tests/fixtures/receipt-small-page.pdf`, and
  a synthetic regression test covers full sheets inside noisy scanner borders.
- Tests cover blank-page removal thresholds, split names, PNG naming, metadata, and preview fallback.

### 7. Container Cutover

- Switch the production image to the Swift executable.
- Remove Python runtime packages only after no production path imports Python.
- Keep OCRmyPDF/Tesseract packages as long as OCR uses OCRmyPDF.
- Update README, deployment docs, compose files, and build scripts.

Acceptance:

- `docker compose up -d --build` works from a clean checkout.
- The documented Docker host-network deployment remains a drop-in replacement.
- Scan directory ownership and non-root port binding still work.
- Documentation uses Docker consistently for build, run, Compose, smoke-test, and publishing workflows.

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
