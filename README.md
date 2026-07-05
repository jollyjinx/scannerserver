# scannerserver

`scannerserver` is a containerized web scanner service for the Fujitsu/Ricoh ScanSnap iX500.

It was built for running an iX500 from a Raspberry Pi or other always-on Linux host after the macOS ScanSnap software stopped being a good fit. The scanner is used over Wi-Fi, scanned PDFs are stored in a host directory, and OCR runs in the background so the next scan can start while the previous scan is still being processed.

## Features

- Web UI for starting scans, downloading files, and deleting one or many files at once.
- Saved scan modes for duplex/simplex, PDF/PNG output, OCR, autocrop, blank-page removal, and page splitting.
- A configurable default scan mode for the physical scanner button.
- Scan list grouped by day with first-page preview thumbnails.
- Physical iX500 scan button support over the ScanSnap Wi-Fi protocol.
- PDF modes publish the source PDF immediately after the scan.
- OCR PDF is created asynchronously with OCRmyPDF and Tesseract when the selected mode enables OCR.
- Default OCR languages: German and English (`deu+eng`).
- Optional blank-page removal and autocrop before output/OCR.
- Raw PDFs are marked with PDF creator metadata `ScanSnap` for tools that expect ScanSnap-created documents.
- Runs as a non-root user while still binding the web UI to port `80`.

## Output Files

PDF scans produce one source PDF by default, plus an OCR PDF when OCR is enabled:

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

Modes can also save one PDF per page:

```text
YYYY-MM-DD.HHMMSS-page-0001.pdf
YYYY-MM-DD.HHMMSS-page-0001.ocr.pdf
```

PNG modes save one image per page:

```text
YYYY-MM-DD.HHMMSS-page-0001.png
YYYY-MM-DD.HHMMSS-page-0002.png
```

## Scan Modes

On first start, the web UI creates `/scans/.scanner-settings.json` with a few default modes:

- `Duplex PDF + OCR`: matches the previous default behavior.
- `Simplex PDF + OCR`: discards back pages with the Wi-Fi backend and uses a simplex source for SANE.
- `Photo PNG`: color, higher-resolution PNG page output with OCR and document cleanup disabled.
- `Duplex PDF`: multipage PDF with OCR disabled.
- `Single Page PDFs + OCR`: one PDF per page, each queued for OCR.

Use **Advanced settings** in the web UI to add, edit, delete, or choose the mode used by the physical scanner button. Settings are persisted in the scan output volume, so they survive container rebuilds and image updates.

`SCAN_RESOLUTION` and `SCAN_MODE` are passed to the SANE backend. The UI derives the SANE source from the Sides setting as `ADF Duplex` or `ADF Simplex`. With the ScanSnap Wi-Fi backend, modes control simplex/duplex, output format conversion, OCR, blank-page removal, and autocrop; the reverse-engineered Wi-Fi scanner command does not expose resolution or color controls.

## Hardware And Network Requirements

You need:

- A ScanSnap iX500 with Wi-Fi enabled.
- A Linux host that can reach the scanner on the network.
- A container runtime with the Compose-compatible `container compose` command.
- The iX500 product serial/password only if the web setup cannot use the default password automatically.

The iX500 does not behave like a normal eSCL/AirScan scanner in this setup. This project uses the reverse-engineered ScanSnap Wi-Fi protocol implemented by [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap), built into the image as `scansnap-wifi`.

The important scanner ports are:

| Port | Purpose |
| --- | --- |
| UDP `52217` | ScanSnap discovery/registration |
| TCP `53219` | Pairing/control handshake |
| TCP `53218` | Scan control/data |
| UDP `55265` | Button notice listener in this app |

Keep your `SCANSNAP_PAIRING_KEY` out of git. Put it in `.env` only when configuring the scanner manually.

### VENS Serial Discovery

The iX500 exposes a 132-byte VENS UDP device-info response before the TCP pairing step. That response is unauthenticated and includes:

```text
offset 28..33    scanner MAC address
offset 40..103   scanner serial number
offset 104..119  display name
```

The web app uses this first-run flow for the Wi-Fi backend:

1. Send VENS discovery/registration packets on the local network.
2. List discovered ScanSnap devices, sorted with known Silex MAC prefixes first.
3. Let you choose the scanner.
4. If discovery does not find the scanner, let you enter its scanner IP address or Ethernet/MAC address manually.
5. Derive the default pairing identity from the discovered serial number.
6. Test the pairing identity against TCP `53219`.
7. Save the working scanner IP and pairing identity in `/scans/.scannerserver-scanner.json`.

If the default password was changed, the test fails and the web UI asks for the scanner password. The app derives the pairing identity from that password and stores only the derived identity.

### Pairing Key From Serial Number

For a factory-default iX500 password, you do not need to packet-capture ScanSnap software to get `SCANSNAP_PAIRING_KEY`.

The password/security key defaults to the last four characters of the ScanSnap product serial number. The value this project calls `SCANSNAP_PAIRING_KEY` is the VENS pairing identity derived from that password:

```text
KEY = "pFusCANsNapFiPfu"
SHIFT = 11
identity[i] = ord(password[i]) + ord(KEY[i]) + SHIFT
SCANSNAP_PAIRING_KEY = each identity value concatenated as decimal text
```

Example:

```text
serial:                 AWRHC08122
default password:       8122
derived pairing key:    179130178176
```

Calculation:

```text
'8' + 'p' + 11 = 56 + 112 + 11 = 179
'1' + 'F' + 11 = 49 +  70 + 11 = 130
'2' + 'u' + 11 = 50 + 117 + 11 = 178
'2' + 's' + 11 = 50 + 115 + 11 = 176
```

A quick local calculator:

```bash
python3 - <<'PY'
serial = "AWRHC08122"
password = serial.rstrip()[-4:]
key = "pFusCANsNapFiPfu"
print("".join(str(ord(char) + ord(key[index]) + 11) for index, char in enumerate(password)))
PY
```

If you changed the scanner password in ScanSnap Wireless Setup Tool, use that password instead of the serial suffix. If you do not know the changed password, capture the key from an already configured official ScanSnap client or reset/reconfigure the scanner wireless settings.

The Ethernet/MAC address is not part of this calculation. This derivation is also documented by [`mzyy94/AirScap`](https://github.com/mzyy94/AirScap/blob/master/protocol.en.md).

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

You can leave scanner discovery to the web UI. These values are optional for manual setup:

```text
SCANNER_IP=your-scanner-ip-address
SCANSNAP_PAIRING_KEY=derived-or-captured-pairing-key
```

Start the service:

```bash
container compose up -d
```

The included Compose file pulls `ghcr.io/jollyjinx/scannerserver:latest`. No local image build is needed for normal installation.

Open the web UI:

```text
http://YOUR_LINUX_HOST/
```

On first startup, finish **Scanner setup** before the scan controls are shown. Choose a discovered scanner, or enter the scanner IP address or Ethernet/MAC address manually. If the scanner still uses its default password, the app configures the pairing key automatically from the discovered serial number.

Press **Start scan** or press the scanner's physical scan button.

## First Scan Checklist

Before debugging the app, verify the basics:

```bash
ping SCANNER_IP
```

Check that the container starts:

```bash
container compose ps
container compose logs -f scansnap
```

Run one scan from the command line:

```bash
container compose run --rm scansnap scan-once
```

Expected result: a raw PDF appears in `./scans`, then the web service queues OCR and creates the `.ocr.pdf` file. For Wi-Fi mode, run the web setup first or provide `SCANNER_IP` and `SCANSNAP_PAIRING_KEY` manually.

## Physical Button Support

Button support is active by default.

The app periodically arms itself with the scanner by:

1. Registering over UDP `52217`.
2. Completing the TCP `53219` pairing handshake.
3. Running the TCP `53218` init sequence.
4. Listening for button notices on UDP `55265`.

If scanner setup has not been completed yet, the listener waits and starts arming after the web setup saves a scanner. When a notice arrives from the configured scanner IP, the app starts a scan with the saved button-default mode.

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

## Receipt / Small Page Cropping

Automatic page cropping is enabled by default for PDF scans. It detects smaller documents, such as receipts, that sit on a larger scanner page and crops the PDF page boxes around the detected document before OCR runs.

The detector is conservative: it only crops when the detected object is much narrower or shorter than the full scan page and dense enough to look like a document rather than a few text pixels.

```yaml
environment:
  SCAN_CROP_PAGES: "true"
  SCAN_CROP_BACKGROUND_DELTA: "8"
  SCAN_CROP_MARGIN_POINTS: "12"
```

To see per-page crop decisions:

```yaml
environment:
  SCAN_CROP_DEBUG: "1"
```

To disable automatic cropping:

```yaml
environment:
  SCAN_CROP_PAGES: "false"
```

## Configuration

Common environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SCAN_OUTPUT_DIR` | `/scans` | Output directory inside the container |
| `SCAN_SETTINGS_PATH` | `/scans/.scanner-settings.json` | Saved scan modes and button-default mode |
| `SCANNER_CONFIG_PATH` | `/scans/.scannerserver-scanner.json` | Saved Wi-Fi scanner IP and derived pairing identity |
| `SCAN_BACKEND` | `wifi` | `wifi` for iX500 Wi-Fi protocol, `sane` for SANE fallback |
| `SCAN_LANGUAGE` | `deu+eng` | OCR languages passed to OCRmyPDF/Tesseract |
| `SCAN_RESOLUTION` | `300` | Resolution for SANE backend |
| `SCAN_MODE` | `Color` | Mode for SANE backend |
| `SCAN_SOURCE` | `ADF Duplex` | Advanced source override for SANE backend; the web UI derives this from the Sides setting |
| `SCAN_FORMAT` | `pdf` | `pdf` or `png`; PNG output exports one image per page |
| `SCAN_PAGE_MODE` | `multi` | `multi` for one multipage PDF, `single` for one PDF per page |
| `SCAN_OCR_ENABLED` | `true` | Queue OCR for PDF output after scanning |
| `SCANNER_IP` | empty | Optional scanner IP override; web setup can persist this instead |
| `SCANSNAP_PAIRING_KEY` | empty | Optional pairing identity override; web setup can derive and persist this instead |
| `SCANSNAP_CLIENT_IP` | empty | Optional client IP override for macvlan/static-IP deployments |
| `SCANSNAP_MAC_PREFIXES` | `84:25:3f,00:80:92,00:40:17` | MAC prefixes sorted first in Wi-Fi discovery |
| `SCANSNAP_DISCOVERY_SWEEP` | `true` | Also send discovery packets across the local `/24` |
| `SCANSNAP_DISCOVERY_TIMEOUT_SECONDS` | `4` | First-run scanner discovery timeout |
| `SCAN_SIMPLEX` | `false` | Set `true` to discard back pages with the Wi-Fi backend |
| `SCAN_RAW_PDF_CREATOR` | `ScanSnap` | PDF `/Creator` value for raw PDFs |
| `SCAN_OCR_ROTATE_PAGES_THRESHOLD` | `2.0` | OCRmyPDF rotation confidence threshold; lower values rotate pages more aggressively |
| `SCAN_REMOVE_BLANK_PAGES` | `true` | Remove blank pages from raw PDF before OCR |
| `SCAN_BLANK_WHITE_THRESHOLD` | `245` | Pixel threshold used for blank detection |
| `SCAN_BLANK_CONTENT_RATIO_THRESHOLD` | `0.003` | Maximum dark-pixel ratio for a blank page |
| `SCAN_BLANK_MEAN_THRESHOLD` | `248.0` | Minimum average brightness for a blank page |
| `SCAN_CROP_PAGES` | `true` | Crop smaller scanned documents before OCR |
| `SCAN_CROP_BACKGROUND_DELTA` | `8` | Pixel delta from the page-edge background used for crop detection |
| `SCAN_CROP_BORDER_PX` | `64` | Edge sample size used to estimate scanner background color |
| `SCAN_CROP_MARGIN_POINTS` | `12` | PDF point margin kept around detected crop bounds |
| `SCAN_CROP_MAX_WIDTH_RATIO` | `0.80` | Crop only when detected content is at most this fraction of page width, unless height is smaller |
| `SCAN_CROP_MAX_HEIGHT_RATIO` | `0.80` | Crop only when detected content is at most this fraction of page height, unless width is smaller |
| `SCAN_CROP_MIN_DENSITY` | `0.08` | Minimum detected content density inside the crop bounds |
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

Set the network prefix in the environment used by Compose, usually `/home/ubuntu/plt/.env` for this example. `SCANNER_IP` and `SCANSNAP_PAIRING_KEY` are optional if you use the web setup.

```text
NETWORK_PREFIX=10.112
# Optional manual scanner config:
# SCANNER_IP=10.112.10.11
# SCANSNAP_PAIRING_KEY=derived-or-captured-pairing-key
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
container compose config --quiet
container compose up -d --no-deps scansnap
```

This starts only the scanner service and does not recreate unrelated services.

## Updating

Pull the latest Compose file, pull the latest image from GitHub Container Registry, and recreate only the scanner service:

```bash
git pull
container compose pull scansnap
container compose up -d --no-deps scansnap
```

For the simple standalone setup, this is also fine:

```bash
container compose pull
container compose up -d
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
container compose up -d --build
```

To rebuild after local changes:

```bash
container compose up -d --build --no-deps scansnap
```

## Troubleshooting

### The web UI does not open

Check whether the container is running:

```bash
container compose ps
container compose logs --tail=100 scansnap
```

If using port `80`, make sure nothing else is already bound to that IP/port.

### The scanner cannot be reached

From the Linux host:

```bash
ping SCANNER_IP
```

From inside the container:

```bash
container compose exec scansnap sh
```

Then inside the shell:

```bash
ip addr
```

For macvlan deployments, confirm the container has the expected IP and MAC, and that the scanner is in the same VLAN/subnet.

### Button press does nothing

Check the logs:

```bash
container compose logs -f scansnap
```

You want to see:

```text
ScanSnap button client armed
```

If you see arming timeouts, the scanner is usually offline, asleep, on the wrong Wi-Fi/VLAN, or not reachable from the container IP.

### OCR is slow

OCR runs after scanning and can take a while on a Raspberry Pi. This is expected. The raw PDF is available immediately, and the next scan can start while OCR is still running.

### OCR text is correct, but pages are upside down

OCRmyPDF rotates pages only when its orientation confidence is high enough. This project defaults `SCAN_OCR_ROTATE_PAGES_THRESHOLD` to `2.0` so mixed-orientation scans are rotated more aggressively. Increase it if pages are rotated incorrectly, or decrease it if upside-down pages are still not corrected.

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

### Receipts or smaller pages are not cropped correctly

Enable debug logging for one scan:

```yaml
environment:
  SCAN_CROP_DEBUG: "1"
```

If a receipt is still left on a large page, lower `SCAN_CROP_BACKGROUND_DELTA` slightly. If normal pages are cropped too aggressively, raise `SCAN_CROP_MIN_DENSITY` or disable the feature:

```yaml
environment:
  SCAN_CROP_PAGES: "false"
```

## Security Notes

- Keep `SCANSNAP_PAIRING_KEY` in `.env`; do not commit it. If you use web setup, the derived pairing identity is stored in `/scans/.scannerserver-scanner.json`.
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
