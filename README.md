# scannerserver

`scannerserver` is a containerized web scanner service for the Fujitsu/Ricoh ScanSnap iX500.

It runs on a Raspberry Pi or other Linux host, finds the iX500 on your local network, and lets you scan from a web page or by pressing the scanner's physical button. Scans are written to a host directory as PDFs, with OCR running in the background.

The service is implemented as a Swift 6.3 package. Its long-running process is native Swift; OCRmyPDF, Tesseract, qpdf, Poppler, libvips, ExifTool, SANE, and the ScanSnap acquisition utility remain external command-line tools invoked only for scan processing.

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

Raw PDFs appear immediately in `./scans` after acquisition. For OCR-enabled multipage scans,
blank-page removal and autocrop run on an isolated copy before the searchable `.ocr.pdf` is
published; the original PDF remains unchanged and available throughout processing.

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

If discovery still fails but you know the scanner IP, enter the IP address manually on the setup page.

## More Documentation

- [Documentation index](docs/index.md)
- [Deployment and builds](docs/deployment.md)
- [Configuration and scan behavior](docs/configuration.md)
- [ScanSnap protocol notes](docs/protocol.md)
- [Swift hardware validation](docs/swift-hardware-validation.md)

## References

- [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap) implements the reverse-engineered ScanSnap iX500 Wi-Fi protocol used by this image.
- [OCRmyPDF](https://ocrmypdf.readthedocs.io/) creates searchable PDFs.
- [Tesseract OCR](https://github.com/tesseract-ocr/tesseract) provides OCR language support.
