# iX500 scannerserver

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

The web page header shows the running release version. Published images derive it from the Git
commit date in `YYYY.MM.DD.HHMMSS` format; `/version` returns the same value for scripts and
deployment checks.

On first start, the web UI shows scanner setup. Discovery keeps running in the background while the manual fields remain usable. When exactly one ScanSnap is found, setup automatically derives and tests its factory-default password from the scanner serial number. Multiple scanners are listed for manual selection.

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

1. Continuously discovers scanners on the local network using broadcast and ARP/neighbor entries while setup is open.
2. Automatically chooses the scanner when exactly one iX500 is found; with multiple scanners, it shows them for manual selection.
3. Keeps manual IPv4-address/host-name, serial-number, and Ethernet-address setup available while discovery runs.
4. Reads the scanner serial number before pairing when the network permits it.
5. Tries the factory-default password derived from the serial number.
6. Stops discovery and asks for the scanner security key/password only when the default password is rejected or the serial number is unavailable.
7. Saves the working scanner config in `/scans/.scannerserver-scanner.json`.

It does not sweep every IP address in your subnet.

For a scanner on another routed network, enter its IPv4 address or host name manually and provide
its product serial number when available. Setup resolves host names to IPv4, tries the derived
default first, then asks for the scanner security key/password if necessary. An Ethernet/MAC
address cannot be used to calculate the security key and normally does not cross routers; it only
helps discovery when the scanner is on the same local network.

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

If discovery still fails but you know the scanner IPv4 address or host name, enter it manually on
the setup page.

If the web UI reports **Scan directory is not accessible**, verify that the `SCAN_OUTPUT_DIR`
bind mount exists and that the container user can list it and create, read, and delete files in
it. Correct the directory or host UID/GID permissions, then refresh the page; restarting the
container is not required.

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
