# ScanSnap Linux

Containerized scanning workflow for a Fujitsu/Ricoh ScanSnap iX500 on a Raspberry Pi 4 running Ubuntu 24.04 LTS.

The container uses SANE with `sane-airscan` for Wi-Fi scanner access and OCRmyPDF/Tesseract for searchable PDFs. OCR defaults to German plus English (`deu+eng`). Scans are written to `./scans`.

PDF filenames use:

```text
YYYY--MM--DD.<TOPIC>.pdf
```

`TOPIC` is detected from OCR text using [config/topics.json](config/topics.json). The initial rules are:

| Detected document | Filename topic |
| --- | --- |
| Gemeinde Taufkirchen Wasserwerk bill | `TfK Rechnung Wasserwerk` |
| Stadtwerke München/SWM electricity bill | `SWM Rechnung Strom` |
| Energiewerke Schönau/EWS electricity bill | `EWS Rechnung Strom` |
| Malermeister Bayer bill | `Bayer Rechnung Malerarbeiten` |
| Platanenverein protocol | `Platanenverein Protokoll` |

If no rule matches, the topic is `Unsortiert Scan`. If a file with the same name already exists, the scanner app appends `.2`, `.3`, and so on before `.pdf`.

## Important hardware note

The iX500 can scan over Wi-Fi, but Linux support depends on the scanner being visible through the network scanning protocols exposed to SANE (`eSCL`/AirScan or `WSD`). This project is set up for that path. If discovery is unreliable, set `SCANNER_URL` in `compose.yaml` to the scanner's fixed IP eSCL URL.

For the iX500, make sure the Wi-Fi switch on the back of the scanner is on and that the scanner is already joined to the same network as the Raspberry Pi.

## Raspberry Pi setup

Install the container runtime and compose plugin on Ubuntu 24.04, then clone this repository.

```bash
git clone https://github.com/YOUR_USER/scansnap-linux.git
cd scansnap-linux
mkdir -p scans
container compose up -d --build
```

Open:

```text
http://RASPBERRY_PI_IP:8080
```

Start a scan from the web page. Finished searchable PDFs appear in `./scans`.

For the installed Pi layout where this repo is in `/home/ubuntu/plt/scansnap` and the compose file is `/home/ubuntu/plt/docker-compose.yaml`, use [deploy/raspberry-pi/docker-compose.yaml](deploy/raspberry-pi/docker-compose.yaml) as the compose file. It pins the scanner to:

```text
http://10.112.10.11/eSCL
```

and stores scans in:

```text
/home/ubuntu/plt/scans
```

Install/update it on the Pi with:

```bash
cp /home/ubuntu/plt/scansnap/deploy/raspberry-pi/docker-compose.yaml /home/ubuntu/plt/docker-compose.yaml
mkdir -p /home/ubuntu/plt/scans
cd /home/ubuntu/plt
container compose up -d --build
```

## Check scanner discovery

```bash
container compose run --rm scansnap scanimage -L
```

You should see a device reported by `airscan`, `escl`, `wsd`, or a Fujitsu backend. If nothing appears:

1. Confirm the Pi and scanner are on the same subnet.
2. Confirm the iX500 Wi-Fi switch is on.
3. Give the scanner a fixed DHCP lease in the router.
4. Add the scanner URL to `compose.yaml`:

```yaml
environment:
  SCANNER_NAME: ScanSnap iX500
  SCANNER_URL: http://10.112.10.11/eSCL
  SCANNER_PROTOCOL: escl
```

Then restart:

```bash
container compose up -d --build
```

## Command-line scanning

Run one scan without the web UI:

```bash
container compose run --rm scansnap scan-once
```

Common settings are environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `SCAN_OUTPUT_DIR` | `/scans` | Output directory inside the container |
| `SCAN_LANGUAGE` | `deu+eng` | Tesseract OCR languages |
| `SCAN_RESOLUTION` | `300` | Scan resolution in DPI |
| `SCAN_MODE` | `Color` | SANE scan mode |
| `SCAN_SOURCE` | `ADF Duplex` | SANE source name |
| `SCAN_DEVICE` | empty | Optional exact SANE device name |
| `SCAN_FORMAT` | `pdf` | `pdf` or `images` |
| `SCAN_TOPIC` | empty | Optional manual topic override |
| `SCAN_FALLBACK_TOPIC` | `Unsortiert Scan` | Topic when no rule matches |
| `SCAN_TOPIC_RULES` | `/app/config/topics.json` | JSON classifier rules |

If `ADF Duplex` is not accepted, inspect the scanner options:

```bash
container compose run --rm scansnap scanimage --help -d 'DEVICE_NAME_FROM_SCANIMAGE_L'
```

Then update `SCAN_SOURCE` in `compose.yaml`.

## Why host networking?

Scanner discovery uses multicast and service discovery. Host networking gives the container direct access to those packets on the Raspberry Pi network, which is usually required for driverless scanner discovery.

## References

- [`sane-airscan`](https://github.com/alexpevzner/sane-airscan) supports driverless eSCL/AirScan and WSD scanning.
- Ubuntu's `sane-airscan` manual describes eSCL and WSD support.
- OCRmyPDF uses Tesseract language packs; this image installs German, English, and orientation/script detection.
