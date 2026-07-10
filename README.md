---
title: scannerserver
description: Web scanner service for Fujitsu/Ricoh ScanSnap iX500 devices on Linux.
type: overview
audience: users
status: current
---

# scannerserver

`scannerserver` is a containerized web scanner service for the Fujitsu/Ricoh ScanSnap iX500.

It runs on a Raspberry Pi or other Linux host, finds the iX500 on your local network, and lets you scan from a web page or by pressing the scanner's physical button. Scans are written to a host directory as PDFs, with OCR running in the background.

## Quick Start

On the Linux host that can reach the scanner, create a scan directory and start the container:

```bash
mkdir -p scans
container run -d \
  --name scannerserver \
  --restart unless-stopped \
  --network host \
  --user "$(id -u):$(id -g)" \
  -e TZ=Europe/Berlin \
  -e WEB_PORT=80 \
  -v "$PWD/scans:/scans" \
  ghcr.io/jollyjinx/scannerserver:latest
```

Open:

```text
http://YOUR_LINUX_HOST/
```

On first start, the web UI shows scanner setup. It looks for ScanSnap devices on the local network, lists the scanners it finds, and lets you choose one. If your scanner still uses its default password, setup derives the pairing key automatically from the scanner serial number.

After setup, scan either way:

- Press **Start scan** in the web UI.
- Press the physical scan button on the iX500.

Raw PDFs appear immediately in `./scans`. Searchable OCR PDFs appear shortly after OCR finishes.

## Compose

Compose is optional. If you prefer it, clone the repo and use the included host-network compose file:

```bash
git clone https://github.com/jollyjinx/scannerserver.git
cd scannerserver
mkdir -p scans
container compose up -d
```

Then open:

```text
http://YOUR_LINUX_HOST/
```

## What The Setup Does

The setup flow:

1. Discovers scanners on the local network using broadcast and ARP/neighbor entries.
2. Shows the discovered iX500 devices in the web UI.
3. Lets you choose the scanner, or enter its IP address manually.
4. Reads the scanner serial number before pairing.
5. Tries the factory-default password derived from the serial number.
6. Asks for the scanner password only if the default one was changed.
7. Saves the working scanner config in `/scans/.scannerserver-scanner.json`.

It does not sweep every IP address in your subnet.

## Features

- First-run ScanSnap Wi-Fi setup in the browser.
- Web scan button and physical iX500 button support.
- Saved scan modes for duplex/simplex, PDF/PNG, OCR, autocrop, and blank-page removal.
- Scan list grouped by day with previews and download/delete controls.
- Background OCR with OCRmyPDF and Tesseract.
- Runs as a non-root user while still binding the web UI to port `80`.

## Updating

For `container run`:

```bash
container pull ghcr.io/jollyjinx/scannerserver:latest
container stop scannerserver
container rm scannerserver
# rerun the container run command from Quick Start
```

For Compose:

```bash
git pull
container compose pull
container compose up -d
```

## Troubleshooting

Check logs:

```bash
container logs -f scannerserver
```

For Compose:

```bash
container compose logs -f scansnap
```

If setup finds no scanner, make sure:

- The scanner is powered on and Wi-Fi is enabled.
- The Linux host can reach the scanner network.
- The container uses host networking or a macvlan/static IP on the scanner VLAN.
- The scanner appears in the host/container ARP table.

With Compose:

```bash
container compose exec scansnap ip neigh show
```

If discovery still fails but you know the scanner IP, enter the IP address manually on the setup page.

## More Documentation

- [Deployment and builds](docs/deployment.md)
- [Configuration and scan behavior](docs/configuration.md)
- [ScanSnap protocol notes](docs/protocol.md)
- [Swift hardware validation](docs/swift-hardware-validation.md)

## Documentation Front Matter

All Markdown documentation in this repository starts with YAML front matter so agents and documentation tooling can classify files before reading the full body.

Required fields:

| Field | Purpose |
| --- | --- |
| `title` | Human-readable page title |
| `description` | One-sentence summary of the page |
| `type` | Document category, such as `overview`, `guide`, or `reference` |
| `audience` | Primary reader, such as `users`, `operators`, or `maintainers` |
| `status` | Lifecycle state, currently `current` for maintained docs |

## References

- [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap) implements the reverse-engineered ScanSnap iX500 Wi-Fi protocol used by this image.
- [OCRmyPDF](https://ocrmypdf.readthedocs.io/) creates searchable PDFs.
- [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) provides OCR language support.
