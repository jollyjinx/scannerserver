# ScanSnap Linux

Containerized scanning workflow for a Fujitsu/Ricoh ScanSnap iX500 on a Raspberry Pi 4 running Ubuntu 24.04 LTS.

The container uses the ScanSnap iX500 Wi-Fi protocol for scanner access and OCRmyPDF/Tesseract for searchable PDFs. OCR defaults to German plus English (`deu+eng`). Scans are written to `./scans`.

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

The iX500 does not expose a normal eSCL/AirScan endpoint in this setup. This project uses the reverse-engineered ScanSnap Wi-Fi protocol from [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap), built into the image as `scansnap-wifi`.

For the iX500, make sure the Wi-Fi switch on the back of the scanner is on and that the scanner is already joined to the same network/VLAN as the Raspberry Pi container. The pairing key authorizes scanner access; keep it out of git.

## How this setup was found

This project started with the assumption that the iX500 might work through SANE using eSCL/AirScan or WSD. That did not match the real scanner behavior:

1. `scanimage -L` and `airscan-discover` did not find a usable eSCL/AirScan/WSD scanner.
2. Port checks showed the scanner at `10.112.10.11` had ScanSnap-specific ports open, notably TCP `53218` and `53219`.
3. Packet captures showed VENS/ScanSnap traffic, not eSCL. The useful protocol ports were:

```text
UDP discovery/control: 52217
TCP control:           53219
TCP scan data:         53218
```

4. The reverse-engineered [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap) tool matched that protocol.
5. A real capture between the working ScanSnap client and the scanner exposed the values needed by the tool:

```text
Scanner IP:   10.112.10.11
Scanner name: iX500-AWRHC08122
Scanner MAC:  84:25:3f:16:6e:a0
Client IP:    10.112.10.6
Client MAC:   da:e0:c0:24:d4:f8
Protocol:     ScanSnap/VENS Wi-Fi protocol
```

The pairing key was recovered from the TCP `53219` handshake. Treat that key as a secret and store it only in the Pi's local `.env` file as `SCANSNAP_PAIRING_KEY`; do not commit it.

The final deployment therefore uses the iX500 Wi-Fi protocol directly instead of SANE discovery. SANE and `sane-airscan` remain in the image only as an optional fallback path for other setups.

## Raspberry Pi setup

Install the container runtime and compose plugin on Ubuntu 24.04, then clone this repository.

```bash
git clone https://github.com/YOUR_USER/scansnap-linux.git
cd scansnap-linux
mkdir -p scans
printf 'SCANSNAP_PAIRING_KEY=YOUR_PAIRING_KEY\n' > .env
container compose up -d --build
```

Open:

```text
http://RASPBERRY_PI_IP/
```

Start a scan from the web page. Finished searchable PDFs appear in `./scans`. The web page also lets you download or delete files already on the server.

The scanner's physical scan button is also supported. The container actively arms itself with the scanner by registering over UDP `52217`, completing the TCP `53219` pairing handshake, and running the short TCP `53218` init sequence observed in the working macOS client. It then listens for ScanSnap button notices on UDP `55265`; when a notice arrives from `SCANNER_IP`, it starts the same `scan-once` workflow used by the web button.

For the installed Pi layout where this repo is in `/home/ubuntu/plt/scansnap` and the compose file is `/home/ubuntu/plt/docker-compose.yaml`, use [deploy/raspberry-pi/docker-compose.yaml](deploy/raspberry-pi/docker-compose.yaml) as the compose file. It pins the scanner to:

```text
10.112.10.11
```

and stores scans in:

```text
/home/ubuntu/plt/scans
```

The `scansnap` service should be attached to the existing `aservice1010` macvlan network so the web frontend is reachable at:

```text
http://10.112.10.6/
```

Install/update it on the Pi with:

```bash
printf 'SCANSNAP_PAIRING_KEY=YOUR_PAIRING_KEY\n' >> /home/ubuntu/plt/.env
cp /home/ubuntu/plt/scansnap/deploy/raspberry-pi/docker-compose.yaml /home/ubuntu/plt/docker-compose.yaml
mkdir -p /home/ubuntu/plt/scans
cd /home/ubuntu/plt
container compose up -d --build
```

The container runs as `${UID:-1000}:${GID:-1000}`. On the Pi this matches the `ubuntu` user, so PDFs written to `/home/ubuntu/plt/scans` are not owned by root.

The web app listens on port `80` through `WEB_PORT=80`. The image grants Python only `cap_net_bind_service`, so the app can bind port 80 while still running as the unprivileged `1000:1000` user.

The button listener also runs in the same non-root app process. UDP `55265` is above the privileged port range, so it does not require extra capabilities.

## Check scanner access

```bash
container compose run --rm scansnap scan-once
```

If scanning fails:

1. Confirm the Pi container and scanner are on the same subnet.
2. Confirm the iX500 Wi-Fi switch is on.
3. Give the scanner a fixed DHCP lease in the router.
4. Confirm `SCANSNAP_PAIRING_KEY` is present in `.env`.
5. Restart:

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
| `SCAN_BACKEND` | `wifi` | `wifi` for the iX500 protocol or `sane` for SANE |
| `SCAN_LANGUAGE` | `deu+eng` | Tesseract OCR languages |
| `SCAN_RESOLUTION` | `300` | Scan resolution in DPI |
| `SCAN_MODE` | `Color` | SANE scan mode |
| `SCAN_SOURCE` | `ADF Duplex` | SANE source name |
| `SCANNER_IP` | `10.112.10.11` | Scanner IP for `SCAN_BACKEND=wifi` |
| `SCANSNAP_PAIRING_KEY` | empty | Required secret for `SCAN_BACKEND=wifi` |
| `SCANSNAP_CLIENT_IP` | empty | Optional client IP override, useful with macvlan |
| `SCANSNAP_BUTTON_SCAN_ENABLED` | `true` | Listen for physical scanner button notices |
| `SCANSNAP_BUTTON_PORT` | `55265` | UDP port used by ScanSnap button notices |
| `SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS` | `60` | How often to repeat the active button arming sequence while idle |
| `SCANSNAP_BUTTON_ARM_TIMEOUT_SECONDS` | `45` | Timeout for one button arming attempt |
| `SCANSNAP_BUTTON_REGISTRATION_INTERVAL_SECONDS` | empty | Legacy fallback for `SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS` |
| `SCANSNAP_REGISTRATION_SOURCE_PORT` | `55264` | UDP source port used for client registration |
| `SCANSNAP_REGISTRATION_PORT` | `52217` | Scanner UDP registration port |
| `SCANSNAP_BUTTON_DEBOUNCE_SECONDS` | `3` | Collapse repeated button packets into one scan |
| `SCANSNAP_BUTTON_COOLDOWN_SECONDS` | `10` | Ignore button notices shortly after a scan finishes |
| `SCAN_SIMPLEX` | `false` | Set `true` to discard back pages with the Wi-Fi backend |
| `SCAN_DEVICE` | empty | Optional exact SANE device name |
| `SCAN_FORMAT` | `pdf` | `pdf` or `images` |
| `SCAN_TOPIC` | empty | Optional manual topic override |
| `SCAN_FALLBACK_TOPIC` | `Unsortiert Scan` | Topic when no rule matches |
| `SCAN_TOPIC_RULES` | `/app/config/topics.json` | JSON classifier rules |

If `SCAN_BACKEND=sane` and `ADF Duplex` is not accepted, inspect the scanner options:

```bash
container compose run --rm scansnap scanimage --help -d 'DEVICE_NAME_FROM_SCANIMAGE_L'
```

Then update `SCAN_SOURCE` in `compose.yaml`.

## Network mode

The Raspberry Pi deployment uses the existing `aservice1010` macvlan network and assigns the container `10.112.10.6`. The scanner is fixed at `10.112.10.11`. The Pi compose file also pins the container MAC to `da:e0:c0:24:d4:f8`, which is the client MAC observed in the known-good ScanSnap capture.

The first ScanSnap button notice capture showed the client registering from UDP `55264` to scanner UDP `52217`, then the scanner sending three identical UDP packets to `10.112.10.6:55265` about half a second apart. A later working macOS capture showed the missing step: after registration, the client opens TCP `53219` for the pairing handshake and TCP `53218` for the init sequence before the hardware button is accepted. The app repeats that full arming sequence periodically while idle, filters notices by `SCANNER_IP`, checks for the VENS packet signature, and debounces/cools down events before starting a scan. If pressing the physical button does nothing, verify that the container keeps MAC `da:e0:c0:24:d4:f8`, remains attached to the `aservice1010` macvlan network, and can receive UDP packets on `10.112.10.6:55265`.

## References

- [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap) implements the ScanSnap iX500 Wi-Fi protocol used by this image.
- [`sane-airscan`](https://github.com/alexpevzner/sane-airscan) is still installed for optional `SCAN_BACKEND=sane` setups.
- OCRmyPDF uses Tesseract language packs; this image installs German, English, and orientation/script detection.
