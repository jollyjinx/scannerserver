# scannerserver

`scannerserver` is a containerized web scanner service for the Fujitsu/Ricoh ScanSnap iX500.

It was built for running an iX500 from a Raspberry Pi or other always-on Linux host after the macOS ScanSnap software stopped being a good fit. The scanner is used over Wi-Fi, scanned PDFs are stored in a host directory, and OCR runs in the background so the next scan can start while the previous scan is still being processed.

## Features

- Web UI for starting scans, downloading files, and deleting one or many files at once.
- Scan list grouped by day with first-page preview thumbnails.
- Physical iX500 scan button support over the ScanSnap Wi-Fi protocol.
- Raw PDF is available immediately after the scan.
- OCR PDF is created asynchronously with OCRmyPDF and Tesseract.
- Default OCR languages: German and English (`deu+eng`).
- Optional blank-page removal before OCR.
- Raw PDFs are marked with PDF creator metadata `ScanSnap` for tools that expect ScanSnap-created documents.
- Runs as a non-root user while still binding the web UI to port `80`.

## Output Files

Each scan produces up to two files:

```text
YYYY-MM-DD.HHMMSS.pdf
YYYY-MM-DD.HHMMSS.ocr.pdf
```

The plain `.pdf` is the raw source scan and is written as soon as the scanner finishes. The `.ocr.pdf` file is the searchable OCR version and appears later when the background OCR job completes.

Example:

```text
2026-07-04.103512.pdf
2026-07-04.103512.ocr.pdf
```

## Hardware And Network Requirements

You need:

- A ScanSnap iX500 with Wi-Fi enabled.
- A Linux host that can reach the scanner on the network.
- Docker Engine with the Docker Compose plugin.
- The iX500 pairing key from your ScanSnap setup.

The iX500 does not behave like a normal eSCL/AirScan scanner in this setup. This project uses the reverse-engineered ScanSnap Wi-Fi protocol implemented by [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap), built into the image as `scansnap-wifi`.

The important scanner ports are:

| Port | Purpose |
| --- | --- |
| UDP `52217` | ScanSnap discovery/registration |
| TCP `53219` | Pairing/control handshake |
| TCP `53218` | Scan control/data |
| UDP `55265` | Button notice listener in this app |

Keep your `SCANSNAP_PAIRING_KEY` out of git. Put it in `.env`.

## Install With The Published Image

The recommended install path is to use the prebuilt multi-architecture image published by GitHub Actions:

```text
ghcr.io/jollyjinx/scannerserver:latest
```

This image supports `linux/amd64` and `linux/arm64`, so it works on typical x86 Linux hosts and Raspberry Pi systems without building locally.

Clone the repository on the Linux host:

```bash
git clone https://github.com/jollyjinx/scannerserver.git
cd scannerserver
```

Create the output directory and local environment file:

```bash
mkdir -p scans
cp .env.example .env
```

Edit `.env` and set:

```text
SCANNER_IP=your-scanner-ip-address
SCANSNAP_PAIRING_KEY=your-pairing-key
```

Start the service:

```bash
docker compose up -d
```

The included Compose file pulls `ghcr.io/jollyjinx/scannerserver:latest`. No local image build is needed for normal installation.

Open the web UI:

```text
http://YOUR_LINUX_HOST/
```

Press **Start scan** or press the scanner's physical scan button.

## First Scan Checklist

Before debugging the app, verify the basics:

```bash
ping SCANNER_IP
```

Check that the container starts:

```bash
docker compose ps
docker compose logs -f scansnap
```

Run one scan from the command line:

```bash
docker compose run --rm scansnap scan-once
```

Expected result: a raw PDF appears in `./scans`, then the web service queues OCR and creates the `.ocr.pdf` file.

## Physical Button Support

Button support is active by default.

The app periodically arms itself with the scanner by:

1. Registering over UDP `52217`.
2. Completing the TCP `53219` pairing handshake.
3. Running the TCP `53218` init sequence.
4. Listening for button notices on UDP `55265`.

When a notice arrives from `SCANNER_IP`, the app starts the same scan workflow as the web button.

Useful log lines:

```text
Listening for ScanSnap button notices on UDP 55265
ScanSnap button client armed
Started scan from scanner button notice from <scanner-ip>
```

If button arming times out, first check that the scanner is powered on and reachable from the container network.

## Blank Page Removal

Blank-page removal is enabled by default for PDF scans.

The detector looks at page image brightness and the ratio of non-white pixels. If it removes too much or too little for your scanner/paper/background, tune or disable it with environment variables:

```yaml
environment:
  SCAN_REMOVE_BLANK_PAGES: "true"
  SCAN_BLANK_WHITE_THRESHOLD: "245"
  SCAN_BLANK_CONTENT_RATIO_THRESHOLD: "0.003"
  SCAN_BLANK_MEAN_THRESHOLD: "248.0"
```

To see per-page detection details:

```yaml
environment:
  SCAN_BLANK_DEBUG: "1"
```

To disable blank-page removal:

```yaml
environment:
  SCAN_REMOVE_BLANK_PAGES: "false"
```

## Configuration

Common environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SCAN_OUTPUT_DIR` | `/scans` | Output directory inside the container |
| `SCAN_BACKEND` | `wifi` | `wifi` for iX500 Wi-Fi protocol, `sane` for SANE fallback |
| `SCAN_LANGUAGE` | `deu+eng` | OCR languages passed to OCRmyPDF/Tesseract |
| `SCAN_RESOLUTION` | `300` | Resolution for SANE backend |
| `SCAN_MODE` | `Color` | Mode for SANE backend |
| `SCAN_SOURCE` | `ADF Duplex` | Source for SANE backend |
| `SCAN_FORMAT` | `pdf` | `pdf`; `images` is available only with the SANE backend |
| `SCANNER_IP` | empty | Scanner IP address |
| `SCANSNAP_PAIRING_KEY` | empty | Required for `SCAN_BACKEND=wifi` |
| `SCANSNAP_CLIENT_IP` | empty | Optional client IP override for macvlan/static-IP deployments |
| `SCAN_SIMPLEX` | `false` | Set `true` to discard back pages with the Wi-Fi backend |
| `SCAN_RAW_PDF_CREATOR` | `ScanSnap` | PDF `/Creator` value for raw PDFs |
| `SCAN_REMOVE_BLANK_PAGES` | `true` | Remove blank pages from raw PDF before OCR |
| `SCAN_BLANK_WHITE_THRESHOLD` | `245` | Pixel threshold used for blank detection |
| `SCAN_BLANK_CONTENT_RATIO_THRESHOLD` | `0.003` | Maximum dark-pixel ratio for a blank page |
| `SCAN_BLANK_MEAN_THRESHOLD` | `248.0` | Minimum average brightness for a blank page |
| `WEB_PORT` | `8080` in app, `80` in Compose | Web UI port |
| `SCANSNAP_BUTTON_SCAN_ENABLED` | `true` | Enable physical scanner button listener |
| `SCANSNAP_BUTTON_PORT` | `55265` | UDP port for ScanSnap button notices |
| `SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS` | `60` | How often to re-arm the button client while idle |
| `SCANSNAP_BUTTON_ARM_TIMEOUT_SECONDS` | `45` | Timeout for one button arming attempt |
| `SCANSNAP_BUTTON_REACHABILITY_INTERVAL_SECONDS` | `3` | How often to probe for the scanner while the button client is not armed |
| `SCANSNAP_BUTTON_REACHABILITY_TIMEOUT_SECONDS` | `1` | Timeout for one scanner reachability probe |
| `SCANSNAP_BUTTON_REACHABILITY_PORT` | `53219` | TCP port used to check whether the scanner is awake before arming |
| `SCANSNAP_BUTTON_DEBOUNCE_SECONDS` | `3` | Collapse repeated button packets into one scan |
| `SCANSNAP_BUTTON_COOLDOWN_SECONDS` | `10` | Ignore button notices shortly after a scan finishes |

## Compose Files

This repository includes two Compose examples:

| File | Use |
| --- | --- |
| `compose.yaml` | Simple host-network setup for a standalone install |
| `deploy/raspberry-pi/compose.yaml` | Example service for a Raspberry Pi macvlan deployment |

Important: `deploy/raspberry-pi/compose.yaml` is a scanner service example, not a replacement for your whole home-lab Compose stack. If you already have another large Compose file, merge the `scansnap` service into it instead of overwriting your existing file.

## Raspberry Pi Macvlan Example

The example Pi deployment uses:

```text
scanner IP:       ${SCANNER_IP}
container IP:     ${NETWORK_PREFIX}.10.6
container MAC:    da:e0:c0:24:d4:f8
macvlan network:  aservice1010
```

Set these values in the environment used by Compose, usually `/home/ubuntu/plt/.env` for this example:

```text
NETWORK_PREFIX=10.112
SCANNER_IP=10.112.10.11
SCANSNAP_PAIRING_KEY=your-pairing-key
```

Use this pattern only if you already have the matching macvlan network:

```yaml
networks:
  aservice1010:
    external: true
    name: plt_aservice1010
```

If your Compose file defines the macvlan network itself, do not add the `external: true` block. Attach the service to the existing network name instead.

For an existing stack, copy only the `scansnap` service from `deploy/raspberry-pi/compose.yaml` into your full Compose file, then run:

```bash
cd /home/ubuntu/plt
docker compose config --quiet
docker compose up -d --no-deps scansnap
```

This starts only the scanner service and does not recreate unrelated services.

## Updating

Pull the latest Compose file, pull the latest image from GitHub Container Registry, and recreate only the scanner service:

```bash
git pull
docker compose pull scansnap
docker compose up -d --no-deps scansnap
```

For the simple standalone setup, this is also fine:

```bash
docker compose pull
docker compose up -d
```

## Build From Source

Building locally is only needed if you are changing the application, testing Dockerfile changes, or cannot use the published GHCR image.

Clone the repository and create the same `.env` file described above:

```bash
git clone https://github.com/jollyjinx/scannerserver.git
cd scannerserver
```

Add a small override file so Compose builds from the local checkout instead of pulling the published image:

```yaml
services:
  scansnap:
    build: .
    image: scannerserver:local
```

Save it as `compose.override.yaml`, then run:

```bash
docker compose up -d --build
```

To rebuild after local changes:

```bash
docker compose up -d --build --no-deps scansnap
```

## Troubleshooting

### The web UI does not open

Check whether the container is running:

```bash
docker compose ps
docker compose logs --tail=100 scansnap
```

If using port `80`, make sure nothing else is already bound to that IP/port.

### The scanner cannot be reached

From the Linux host:

```bash
ping SCANNER_IP
```

From inside the container:

```bash
docker compose exec scansnap sh
```

Then inside the shell:

```bash
ip addr
```

For macvlan deployments, confirm the container has the expected IP and MAC, and that the scanner is in the same VLAN/subnet.

### Button press does nothing

Check the logs:

```bash
docker compose logs -f scansnap
```

You want to see:

```text
ScanSnap button client armed
```

If you see arming timeouts, the scanner is usually offline, asleep, on the wrong Wi-Fi/VLAN, or not reachable from the container IP.

### OCR is slow

OCR runs after scanning and can take a while on a Raspberry Pi. This is expected. The raw PDF is available immediately, and the next scan can start while OCR is still running.

### Blank pages are not removed, or nonblank pages are removed

Enable debug logging for one scan:

```yaml
environment:
  SCAN_BLANK_DEBUG: "1"
```

Then inspect the scan log and tune:

- `SCAN_BLANK_CONTENT_RATIO_THRESHOLD`
- `SCAN_BLANK_WHITE_THRESHOLD`
- `SCAN_BLANK_MEAN_THRESHOLD`

Disable the feature if your documents have very light content:

```yaml
environment:
  SCAN_REMOVE_BLANK_PAGES: "false"
```

## Security Notes

- Keep `SCANSNAP_PAIRING_KEY` in `.env`; do not commit it.
- The web UI has no authentication. Run it only on a trusted network or put it behind your own reverse proxy/authentication.
- The container runs as `${UID:-1000}:${GID:-1000}` by default.
- Python is granted `cap_net_bind_service` in the image so the app can bind port `80` without running as root.

## Project Background

This setup was built after testing SANE/AirScan discovery against a real iX500. The scanner did not expose a usable eSCL/AirScan endpoint in this environment. Packet captures showed ScanSnap-specific VENS traffic instead:

```text
UDP discovery/control: 52217
TCP control:           53219
TCP scan data:         53218
```

The final implementation uses `bramheerink/scansnap` for the Wi-Fi protocol and adds the server/web workflow around it.

## References

- [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap) implements the reverse-engineered ScanSnap iX500 Wi-Fi protocol used by this image.
- [OCRmyPDF](https://ocrmypdf.readthedocs.io/) creates searchable PDFs.
- [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) provides OCR language support.
