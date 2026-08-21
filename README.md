# ScanSnap iX500 scanner server

Turn a Fujitsu/Ricoh ScanSnap iX500 into a self-hosted network document service.

`scannerserver` discovers and configures the scanner, accepts scans from its web UI or physical
button, writes documents to your own storage, and produces cropped, blank-filtered, searchable PDFs
in the background. OCR can run on the scanner host, spread across approved worker machines, or be
used directly by LLM tools and other services through an OpenAPI-described HTTP API.

The service runs as a non-root Linux container on Raspberry Pi (`arm64`) and x86-64 hosts. Scanning,
document processing, and OCR stay on machines you operate.

## What you get

| Area | Included |
| --- | --- |
| ScanSnap integration | Native iX500 Wi-Fi discovery, setup, pairing, reachability, JPEG acquisition, PDF assembly, and resilient physical-button sessions |
| Ways to scan | Web button, physical scanner button, PDF drag-and-drop import, and asynchronous HTTP API |
| Output | Multipage PDF, individual PDFs, PNG pages, searchable `.ocr.pdf`, and optional OCR-only publication |
| Document processing | Automatic page cropping, configurable blank-page removal, previews, metadata, source-order assembly, and safe failure fallbacks |
| Presets | Saved simplex/duplex modes with format, OCR language, crop, and blank-page settings |
| OCR capacity | A configurable built-in worker with container-aware CPU scheduling and priority, plus optional approved Linux-container or native macOS workers with automatic local fallback |
| Integrations | OpenAPI 3.1 job API returning searchable PDFs or UTF-8 text, with optional bearer authentication |
| Operations | Browser status and worker controls, cancellation, throughput history, atomic file publication, persistent settings, health/version endpoints, and arbitrary host UID/GID support |

The normal deployment needs no proprietary desktop ScanSnap software, Docker socket, privileged
worker container, nested container, or cloud OCR account. An optional SANE backend remains
available for compatible non-Wi-Fi acquisition setups.

## Quick start

Run the container on a Linux host that can reach the scanner's network. Host networking is important
for UDP discovery and physical-button notifications.

```bash
mkdir -p scans
docker run -d \
  --name scannerserver \
  --restart unless-stopped \
  --network host \
  --user "$(id -u):$(id -g)" \
  -e WEB_PORT=80 \
  -e TZ="${TZ:-Europe/Berlin}" \
  -v "$PWD/scans:/scans" \
  ghcr.io/jollyjinx/scannerserver:latest
```

Open `http://YOUR_LINUX_HOST/`.

The published image supports `linux/amd64` and `linux/arm64`. Your `./scans` directory holds the
documents and persistent service settings, so replacing the container does not lose them.

### First run

1. Open **Network Setup**. Scannerserver continuously discovers reachable iX500 devices while
   leaving manual setup available.
2. Select the scanner. If exactly one is found, scannerserver can derive and test its factory
   password from the product serial number automatically.
3. Open **Scan Settings** to choose the physical-button default or create presets for duplex,
   simplex, PDF, PNG, OCR, crop, and blank removal.
4. Open **Workers** to set the built-in worker's processing CPU allowance and post-scan priority.
5. Start a scan in the browser or press the iX500's physical scan button.

The header shows the configured scanner and a live reachability indicator. The page also reports
scan, processing, OCR, and worker activity without requiring a manual refresh loop.

## Everyday document workflow

The web UI separates routine use from administration:

- **Scanner** starts a scan with a saved preset and shows live activity.
- **Documents** groups output by day, generates previews, opens or downloads files, supports bulk
  deletion, and accepts existing PDFs by drag and drop for OCR.
- **Scan Settings** manages presets and shared blank-page detector thresholds.
- **Workers** configures or pauses the built-in worker, manages remote OCR workers, and shows
  waiting, running, recent, and throughput information.
- **Network Setup** discovers, pairs, tests, changes, or clears the scanner configuration.

The scanner becomes available again before most document processing finishes. For an OCR-enabled
Wi-Fi scan, pages can enter OCR, crop, and blank filtering as they arrive instead of waiting for the
feeder to empty. The final searchable document is assembled in source order and published
atomically.

### Output and failure safety

The default multipage PDF flow publishes both files:

```text
2026-08-21.143015.pdf
2026-08-21.143015.ocr.pdf
```

With `SCAN_OCR_ONLY=true`, the raw PDF stays private while processing succeeds and only the
searchable PDF is published. If OCR or document processing fails, scannerserver publishes the raw
PDF as a fallback rather than losing the scan. Imported PDFs always preserve their uploaded source.

Deleting a document cancels its queued and active work before removing its output and cached
preview. Late worker results cannot recreate a deleted or cancelled document.

See [configuration and scan behavior](docs/configuration.md) for single-page PDF/PNG names,
crop and blank-page tuning, OCR-only behavior, environment variables, and troubleshooting.

## Use scannerserver as an OCR service

The asynchronous REST API uses the same presets, bounded queue, local capacity, remote workers,
validation, and atomic publication as browser imports. Its OpenAPI 3.1 description is available at:

```text
GET /api/v1/openapi.json
```

Set `SCAN_OCR_API_TOKEN` on the server when clients should authenticate, then submit a PDF:

```bash
curl --fail --silent \
  -H "Authorization: Bearer $SCAN_OCR_API_TOKEN" \
  -H "Content-Type: application/pdf" \
  --data-binary @invoice.pdf \
  "http://YOUR_LINUX_HOST/api/v1/ocr/jobs?filename=invoice.pdf"
```

The `202 Accepted` response contains a status URL. Poll it until the job completes, then follow the
returned links to download either the searchable PDF or extracted UTF-8 text. Jobs can also be
cancelled and deleted through the API.

See the [OCR HTTP API guide](docs/ocr-api.md) for presets, response fields, authentication, recovery
semantics, and every endpoint.

## Scale OCR across other machines

The same image contains `scannerserver-worker`. Start it on another Linux or Docker-capable machine
and point it at the scanner server:

```bash
docker run -d \
  --name scannerserver-worker \
  --restart unless-stopped \
  --cpus 8 \
  --memory 8g \
  -v scannerserver-worker-state:/home/scansnap/.config/scannerserver-worker \
  ghcr.io/jollyjinx/scannerserver:latest \
  scannerserver-worker \
  --server http://YOUR_LINUX_HOST \
  --name "Office OCR"
```

Open **Workers** and approve the registration. The worker detects its container CPU allowance and
uses that many concurrent one-page slots. Cap it with `--max-concurrent-jobs` when memory or thermal
limits matter.

Workers initiate all connections, retain an authenticated identity in their named volume, and need
no inbound firewall rule. Compatible workers can perform OCR, crop, and blank filtering; the server
retains queue ownership, naming, verification, ordered assembly, cancellation, and final
publication. If no suitable worker is available or a remote job fails, local processing is the
safety fallback.

Native macOS workers can use Bonjour discovery and Apple Container for per-job isolation. See
[distributed OCR workers](docs/ocr-workers.md) for macOS startup, discovery, approval, security,
pause/resume behavior, and resource controls.

## Compose

The included host-network Compose configuration is an alternative to `docker run`:

```bash
git clone https://gitmaster.jinx.eu/jnxpublic/scannerserver.git
cd scannerserver
mkdir -p scans
docker compose up -d
```

Then open `http://YOUR_LINUX_HOST/`.

See [deployment and builds](docs/deployment.md) for image platforms, macvlan deployment, local
builds, publishing, and the complete container contract.

## Network and security model

- The scanner service is designed for a trusted LAN and does not terminate TLS.
- Use host networking or a correctly routed macvlan/static address for automatic discovery and
  physical-button traffic. Manual setup remains available for routed networks.
- Set `SCAN_OCR_API_TOKEN` for OCR API bearer authentication. Put an authenticating TLS reverse
  proxy in front of the service before exposing it outside a trusted network.
- The container runs as the host UID/GID you provide. All visible documents and settings live under
  the `/scans` bind mount.
- Remote OCR workers use registered identities, explicit approval, authenticated leases, digest
  verification, bounded uploads, `qpdf` validation, and atomic result publication.

## Updating

For a standalone Docker deployment:

```bash
docker pull ghcr.io/jollyjinx/scannerserver:latest
docker stop scannerserver
docker rm scannerserver
# rerun the docker run command from Quick start
```

For Compose:

```bash
git pull
docker compose pull
docker compose up -d
```

The page header and `/version` report the running release. Published builds use the Git commit time
in `YYYY.MM.DD.HHMMSS` form.

## Troubleshooting

Follow service logs:

```bash
docker logs -f scannerserver
```

If discovery finds no scanner, verify that the iX500 is powered on with Wi-Fi enabled, the Linux
host can reach its network, and the container uses host networking or an appropriate macvlan/static
address. Manual setup accepts an IPv4 address or host name plus either the scanner password or
product serial number; scannerserver does not sweep every address in the subnet.

If the UI reports **Scan directory is not accessible**, fix the bind mount path or host UID/GID
permissions and refresh. The service repeats the access check, so a restart is not required.

For protocol ports, button-session diagnostics, crop and blank-page logging, and other operator
checks, see [configuration troubleshooting](docs/configuration.md#troubleshooting).

## Documentation

- [Documentation index](docs/index.md)
- [Configuration and scan behavior](docs/configuration.md)
- [OCR HTTP API for LLMs and services](docs/ocr-api.md)
- [Distributed OCR workers](docs/ocr-workers.md)
- [Deployment and builds](docs/deployment.md)
- [ScanSnap iX500 protocol notes](docs/protocol.md)
- [Current Swift architecture](docs/architecture.md)
- [Real-hardware validation](docs/swift-hardware-validation.md)
- [Completed Python-to-Swift migration history](docs/history/swift-migration.md)

## Implementation

The always-running service, ScanSnap Wi-Fi protocol, JPEG acquisition, PDF assembly, queueing,
settings, worker coordination, and HTTP application are implemented as a Swift 6.3 package with
strict concurrency. OCRmyPDF/Tesseract, qpdf, Poppler, libvips, ExifTool, `img2pdf`, and the optional
SANE backend remain focused external document tools inside the container.

The reverse-engineered ScanSnap protocol work builds on findings from
[`bramheerink/scansnap`](https://github.com/bramheerink/scansnap). Searchable PDF creation uses
[OCRmyPDF](https://ocrmypdf.readthedocs.io/) and [Tesseract OCR](https://github.com/tesseract-ocr/tesseract).
