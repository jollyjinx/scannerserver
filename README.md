# iX500 scannerserver

`scannerserver` is a containerized web scanner service for the Fujitsu/Ricoh ScanSnap iX500.

It runs on a Raspberry Pi or other Linux host, finds the iX500 on your local network, and lets you scan from a web page or by pressing the scanner's physical button. Scans are written to a host directory as PDFs, with OCR running in the background.

The service is implemented as a Swift 6.3 package, including ScanSnap discovery, pairing, button
sessions, JPEG acquisition, and PDF assembly. OCRmyPDF, Tesseract, qpdf, Poppler, libvips,
ExifTool, and the optional SANE backend remain external command-line tools used for document
processing and compatibility.

## Quick Start

On the Linux host that can reach the scanner, create a scan directory and start the container. Host networking and restart policies require options that are not available in Apple’s `container` CLI, so this deployment command uses Docker:

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

Open:

```text
http://YOUR_LINUX_HOST/
```

The web page header shows the running release version. Published images derive it from the Git
commit date in `YYYY.MM.DD.HHMMSS` format; `/version` returns the same value for scripts and
deployment checks.

On first start, open **Network Setup** to set up the scanner. Discovery keeps running in the background while the manual fields remain usable. When exactly one ScanSnap is found, setup automatically derives and tests its factory-default password from the scanner serial number. Multiple scanners are listed for manual selection.

The web UI separates everyday scanning from management: **Scanner** starts scans and shows live activity, **Documents** contains completed output and accepts PDF drag-and-drop imports for OCR, **Scan Settings** manages presets and blank-page detection thresholds shared by every preset, and **Network Setup** manages the scanner connection.

After setup, scan either way:

- Press **Start scan** in the web UI.
- Press the physical scan button on the iX500.

The top of the page shows the configured scanner name with a live reachability indicator: green
when the scanner's control port is reachable and grey when it is not reachable.

The physical button uses a volatile notification session stored in the scanner. While that session
is armed, scannerserver retains it with a 500 ms heartbeat. Web and button scans borrow that same
scanner-side session: scannerserver pauses the heartbeat, completes the button control sequence,
and tells the native acquisition client to skip duplicate registration. After a successful scan it
resumes the heartbeat without re-registering. Failed or cancelled scans use the slower recovery-arm
path. The service also
listens for the scanner's UDP `53220` power-on advertisement and re-arms after a restart without
waiting for a periodic refresh. See [ScanSnap protocol notes](docs/protocol.md#physical-button-support)
for packet directions and [configuration](docs/configuration.md#physical-button-troubleshooting)
for firewall and log checks.

Raw multipage PDFs appear immediately in `./scans` after acquisition, and the scanner button is
rearmed before document processing begins. For single-page PDF and PNG modes, the captured raw
document is handed directly to the bounded background queue; blank-page removal, autocrop, and
final file splitting or image export happen there while the scanner is already available again.
Without OCR, a processed multipage copy atomically replaces its raw PDF. With OCR, both files are
published by default. With `SCAN_OCR_ONLY=true`, only the searchable `.ocr.pdf` is published: the
raw PDF stays in the private scan workspace and is deleted after OCR succeeds, and it is published
as a fallback only if OCR or document processing fails. If that fallback publication fails, the raw
PDF remains in the private workspace and the error is reported.

## Compose

Compose is optional. If you prefer it, clone the repo and use the included host-network compose file:

```bash
git clone https://gitmaster.jinx.eu/jnxpublic/scannerserver.git
cd scannerserver
mkdir -p scans
docker compose up -d
```

Then open:

```text
http://YOUR_LINUX_HOST/
```

## What The Setup Does

The setup flow:

1. Continuously discovers scanners on the local network using broadcast and ARP/neighbor entries while setup is open.
2. Automatically chooses the scanner when exactly one iX500 is found; with multiple scanners, it shows them for manual selection.
3. Keeps manual setup available while discovery runs, using an IPv4 address/host name and one field that accepts either the scanner password or product serial number.
4. Reads the scanner serial number before pairing when the network permits it.
5. Tries the factory-default password derived from the serial number.
6. Tries the unified value as a serial-derived factory password and as the complete scanner password, retaining the entered form values in the browser when pairing fails.
7. Saves the working scanner config in `/scans/.scannerserver-scanner.json`.

It does not sweep every IP address in your subnet.

For a scanner on another routed network, enter its IPv4 address or host name and either its product
serial number or scanner password. Setup resolves host names to IPv4 and first attempts targeted
discovery. It derives the factory password from a discovered or entered serial number, then falls
back to treating the complete entered value as the scanner password. The manual form does not ask
for an Ethernet/MAC address or generated pairing key.

## Features

- First-run ScanSnap Wi-Fi setup in the browser.
- Web scan button and physical iX500 button support.
- Saved scan modes for duplex/simplex, PDF/PNG, post-scan CPU count and priority, autocrop, and blank-page removal.
- Scan list grouped by day with previews and download/delete controls.
- CPU-budgeted background blank-page removal, autocrop, and OCR, including automatic container CPU
  detection, bounded per-page concurrency, configurable caps, and optional reduced-priority nice mode.
- Optional approved OCR worker containers that use their assigned CPUs and automatically fall back
  to local OCR when unavailable.
- Runs as a non-root user while still binding the web UI to port `80`.

## Optional OCR Worker Container

Start a worker with the same image. The named volume preserves its identity and approval across
container replacement:

```bash
docker run -d \
  --name scannerserver-worker \
  --restart unless-stopped \
  --cpus 11 \
  --memory 8g \
  -v scannerserver-worker-state:/home/scansnap/.config/scannerserver-worker \
  gitmaster.jinx.eu/jnxpublic/scannerserver:jinx \
  scannerserver-worker \
  --server http://YOUR_LINUX_HOST \
  --name "Mac OCR"
```

Open **Workers** in scannerserver and approve it. New OCR PDFs are then dispatched automatically;
for streaming ScanSnap scans, capable workers also autocrop and blank-filter each searchable page
before returning it. The scanner host retains scanning, the all-blank keep-one safeguard, filenames,
verification, ordered assembly, and final publication. The Workers page reports throughput in pages/minute and can pause
or resume both remote workers and the internal fallback worker. Pausing active internal OCR returns
that page to remote dispatch instead of continuing to consume scannerserver CPU. The worker detects
the container CPU allowance and runs the job
directly—no Docker socket or nested container is required. See
[Distributed OCR workers](docs/ocr-workers.md) for native macOS mode, resource options, security,
and failure behavior.

## Updating

For the standalone Docker deployment:

```bash
docker pull ghcr.io/jollyjinx/scannerserver:latest
docker stop scannerserver
docker rm scannerserver
# rerun the docker run command from Quick Start
```

For Compose:

```bash
git pull
docker compose pull
docker compose up -d
```

## Troubleshooting

Check logs:

```bash
docker logs -f scannerserver
```

For Compose:

```bash
docker compose logs -f scansnap
```

If setup finds no scanner, make sure:

- The scanner is powered on and Wi-Fi is enabled.
- The Linux host can reach the scanner network.
- The container uses host networking or a macvlan/static IP on the scanner VLAN.
- The scanner appears in the host/container ARP table.

With Compose:

```bash
docker compose exec scansnap ip neigh show
```

If discovery still fails but you know the scanner IPv4 address or host name, enter it manually on
the setup page.

If the web UI reports **Scan directory is not accessible**, verify that the `SCAN_OUTPUT_DIR`
bind mount exists and that the container user can list it and create, read, and delete files in
it. Correct the directory or host UID/GID permissions, then refresh the page; restarting the
container is not required.

## More Documentation

- [Documentation index](docs/index.md)
- [Current Swift architecture](docs/architecture.md)
- [Deployment and builds](docs/deployment.md)
- [Configuration and scan behavior](docs/configuration.md)
- [Distributed OCR workers](docs/ocr-workers.md)
- [ScanSnap protocol notes](docs/protocol.md)
- [Swift hardware validation](docs/swift-hardware-validation.md)
- [Completed Python-to-Swift migration history](docs/history/swift-migration.md)

## References

- [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap) was an important reference for the reverse-engineered ScanSnap iX500 Wi-Fi protocol now implemented natively in Swift.
- [OCRmyPDF](https://ocrmypdf.readthedocs.io/) creates searchable PDFs.
- [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) provides OCR language support.
