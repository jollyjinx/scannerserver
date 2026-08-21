---
name: scannerserver-ocr-api
description: Maintain scannerserver's asynchronous REST/OpenAPI PDF OCR interface. Use when changing `/api/v1/ocr`, its OpenAPI contract, PDF submission and job status, searchable-PDF or text results, bearer authentication, or an LLM/MCP integration over this API.
---

# Scannerserver OCR API

## Purpose

Keep one universal OCR integration boundary for LLM tools and ordinary services. REST plus OpenAPI
is the primary boundary. An MCP integration should remain a thin client of this API rather than
introducing another OCR implementation, scheduler, or job store.

Before changing the interface, read:

- [`docs/ocr-api.md`](../../../docs/ocr-api.md) for the external contract and examples.
- [`docs/architecture.md`](../../../docs/architecture.md) for runtime ownership and compatibility.
- [`Sources/ScannerServerCore/HTTP/OCRAPI.swift`](../../../Sources/ScannerServerCore/HTTP/OCRAPI.swift)
  for routes, models, authentication, and text extraction.
- [`tests/ScannerServerCoreTests/HTTP/OCRAPITests.swift`](../../../tests/ScannerServerCoreTests/HTTP/OCRAPITests.swift)
  and the OCR API cases in
  [`ScannerServerApplicationTests.swift`](../../../tests/ScannerServerCoreTests/HTTP/ScannerServerApplicationTests.swift)
  before changing observable behavior.

## Contract

- Preserve the versioned `/api/v1/ocr` routes unless the user explicitly authorizes a breaking
  change. Keep `/api/v1/openapi.json` synchronized with runtime behavior.
- Submit raw `application/pdf` request bodies asynchronously. Reuse the imported-PDF path,
  `OCRQueueActor`, configured CPU budget, presets, and approved remote workers.
- Preserve exclusive source/result publication, scan-directory confinement, upload-size and PDF
  signature checks, cancellation, and source preservation on failure.
- Derive job state from safe regular-file resolution plus actor-isolated queue snapshots. Completed
  jobs remain discoverable across restart; interrupted jobs report failure and keep their source.
- Treat job IDs as opaque externally. Their current base64url filename encoding avoids a second
  durable API job database and must continue to reject unsafe filenames and directory traversal.
- Return the completed searchable PDF directly. Produce UTF-8 text from that PDF's existing text
  layer with Poppler `pdftotext -layout`; do not OCR the document again.
- When `SCAN_OCR_API_TOKEN` is set, require its bearer token for every OCR operation. The OpenAPI
  document remains public for discovery. Keep sensitive API responses non-cacheable.

## Change Guidance

- Add OCR policy and state to `ScannerServerCore`, not the executable target.
- Keep dependencies injectable and `Sendable`; shared mutable state belongs behind an actor.
- Prefer extending the current queue and document lifecycle over route-local background tasks.
- For a new input type, normalize it before the established imported-PDF boundary when possible.
- For an MCP server or LLM-specific adapter, call the OpenAPI-described routes and preserve their
  async job semantics. Do not bypass authentication, resource limits, or worker scheduling.
- Update the runtime OpenAPI document, `docs/ocr-api.md`, configuration documentation, and tests in
  the same change whenever an endpoint, field, state, status code, or authentication rule changes.

## Validation

Run the checks appropriate to the change:

```bash
swift build
swift test --filter 'OCRAPI|ScannerServerApplicationTests.ocrAPI'
swift test
git diff --check
```

The OpenAPI route test must parse the served document as JSON and exercise the changed operation.
Build the container only when container files or runtime tool dependencies change. Poppler
`pdftotext` is already supplied by the production image's `poppler-utils` package.
