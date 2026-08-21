---
title: OCR HTTP API
description: OpenAPI-described asynchronous PDF OCR interface for LLM tools and other services.
type: reference
audience: integrators, operators, and maintainers
status: current
---

# OCR HTTP API

Scannerserver exposes an asynchronous REST API for submitting PDFs to the same OCR queue used by
the browser, scanner, and distributed workers. The API is the primary integration boundary because
ordinary services can call HTTP directly and LLM platforms can import its OpenAPI description. An
MCP server can be added later as a thin adapter without duplicating OCR, scheduling, or file state.

The OpenAPI 3.1 document is served at:

```text
GET /api/v1/openapi.json
```

## Authentication

Set `SCAN_OCR_API_TOKEN` to require the same bearer token on every OCR API operation. The OpenAPI
document and the existing browser routes remain available without it.

```yaml
environment:
  SCAN_OCR_API_TOKEN: "replace-with-a-long-random-token"
```

When the variable is empty or absent, OCR API operations are unauthenticated, matching the existing
trusted-LAN web interface. Configure the token or an authenticating reverse proxy before exposing
the service outside a trusted network.

Pass the token as:

```text
Authorization: Bearer replace-with-a-long-random-token
```

## Workflow

List the presets that can supply OCR language, blank-page, and crop settings:

```bash
curl --fail --silent \
  -H "Authorization: Bearer $SCAN_OCR_API_TOKEN" \
  http://scanner/api/v1/ocr/presets
```

Submit a PDF. `filename` is optional; scannerserver generates a unique PDF name when it is omitted.
`mode_id` is optional and defaults to the configured default preset.

```bash
curl --fail --silent \
  -H "Authorization: Bearer $SCAN_OCR_API_TOKEN" \
  -H "Content-Type: application/pdf" \
  --data-binary @invoice.pdf \
  "http://scanner/api/v1/ocr/jobs?filename=invoice.pdf&mode_id=duplex-pdf-ocr"
```

The `202 Accepted` response contains an opaque job `id`, the page count, current state, progress
counts, and relative result links. Its `Location` header is the same status URL returned in `links`:

```json
{
  "id": "aW52b2ljZS5wZGY",
  "state": "processing",
  "filename": "invoice.pdf",
  "page_count": 2,
  "queued_pages": 1,
  "processing_pages": 1,
  "links": {
    "status": "/api/v1/ocr/jobs/aW52b2ljZS5wZGY",
    "searchable_pdf": "/api/v1/ocr/jobs/aW52b2ljZS5wZGY/document",
    "text": "/api/v1/ocr/jobs/aW52b2ljZS5wZGY/text"
  }
}
```

Poll the status link until `state` is `completed` or `failed`:

```bash
curl --fail --silent \
  -H "Authorization: Bearer $SCAN_OCR_API_TOKEN" \
  http://scanner/api/v1/ocr/jobs/aW52b2ljZS5wZGY
```

Download either the searchable PDF or UTF-8 text. Text extraction reads the completed PDF's text
layer with Poppler `pdftotext -layout`; it does not run OCR a second time.

```bash
curl --fail --silent \
  -H "Authorization: Bearer $SCAN_OCR_API_TOKEN" \
  -o invoice.ocr.pdf \
  http://scanner/api/v1/ocr/jobs/aW52b2ljZS5wZGY/document

curl --fail --silent \
  -H "Authorization: Bearer $SCAN_OCR_API_TOKEN" \
  http://scanner/api/v1/ocr/jobs/aW52b2ljZS5wZGY/text
```

The result routes return `409 Conflict` while OCR is incomplete. Cancel work and remove its source,
searchable result, and previews with:

```text
DELETE /api/v1/ocr/jobs/{job}
```

## Processing And Recovery Semantics

- Uploads use `SCAN_PDF_UPLOAD_MAX_BYTES`, PDF signature validation, exclusive file publication,
  the selected preset, page-oriented OCR, configured local CPU capacity, and approved remote workers.
- The uploaded source PDF and completed `.ocr.pdf` appear in the Documents collection, matching
  browser PDF imports.
- Job states are derived from atomically published files and the actor-isolated OCR queue rather than
  a second job database.
- A completed job remains discoverable after a service restart. Work that was incomplete when the
  process stopped is reported as failed after restart, and its source PDF is preserved for retry.
- The first version accepts PDFs. Images can be added later by normalizing them to PDF before the
  existing queue boundary, without changing the job/result protocol.

## Endpoint Summary

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/v1/openapi.json` | OpenAPI 3.1 description |
| `GET` | `/api/v1/ocr/presets` | List preset IDs and OCR-relevant settings |
| `POST` | `/api/v1/ocr/jobs` | Upload a PDF and enqueue OCR |
| `GET` | `/api/v1/ocr/jobs/{job}` | Read job state and result links |
| `GET` | `/api/v1/ocr/jobs/{job}/document` | Download the searchable PDF |
| `GET` | `/api/v1/ocr/jobs/{job}/text` | Download UTF-8 extracted text |
| `DELETE` | `/api/v1/ocr/jobs/{job}` | Cancel work and delete its files |
