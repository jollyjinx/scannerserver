---
title: Configuration and Scan Behavior
description: Environment variables, output naming, scan modes, and post-processing behavior.
type: reference
audience: operators
status: current
---

# Configuration and Scan Behavior

## Output Files

PDF scans produce a source PDF immediately and an OCR PDF later if OCR is enabled:

```text
YYYY-MM-DD.HHMMSS.pdf
YYYY-MM-DD.HHMMSS.ocr.pdf
```

Deleting a source scan while OCR is active cancels that document's OCR process before removing
the file. Matching queued OCR work is removed as well, while OCR jobs for other scans continue.

Single-page PDF modes use:

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

On first start, the web UI creates `/scans/.scanner-settings.json` with default modes:

- `Duplex PDF + OCR`
- `Simplex PDF + OCR`
- `Photo PNG`
- `Duplex PDF`
- `Single Page PDFs + OCR`

Use **Advanced settings** in the web UI to add, edit, delete, or choose the mode used by the physical scanner button.

With the ScanSnap Wi-Fi backend, modes control simplex/duplex, output conversion, OCR, blank-page removal, autocrop, and the extra margin kept around cropped content. The reverse-engineered Wi-Fi scanner command does not expose resolution or color controls. `SCAN_RESOLUTION`, `SCAN_MODE`, and `SCAN_SOURCE` are mainly for the SANE fallback backend. The web UI shows a short explanation beneath every mode setting.

## Common Environment Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `SCAN_OUTPUT_DIR` | `/scans` | Output directory inside the container |
| `SCAN_SETTINGS_PATH` | `/scans/.scanner-settings.json` | Saved scan modes and button-default mode |
| `SCANNER_CONFIG_PATH` | `/scans/.scannerserver-scanner.json` | Saved Wi-Fi scanner IP and derived pairing identity |
| `SCAN_BACKEND` | `wifi` | `wifi` for iX500 Wi-Fi protocol, `sane` for SANE fallback |
| `SCAN_LANGUAGE` | `deu+eng` | OCR languages passed to OCRmyPDF/Tesseract |
| `SCAN_FORMAT` | `pdf` | `pdf` or `png` |
| `SCAN_PAGE_MODE` | `multi` | `multi` for one multipage PDF, `single` for one PDF per page |
| `SCAN_OCR_ENABLED` | `true` | Queue OCR for PDF output after scanning |
| `SCAN_CROP_PAGES` | `true` | Crop PDF pages to the detected paper or content bounds before OCR |
| `SCAN_CROP_MARGIN_POINTS` | `1` | Extra margin around content-classified autocrops, in PDF points (1 point = 1/72 inch) |
| `SCANNER_IP` | empty | Optional scanner IP override; web setup can persist this instead |
| `SCANSNAP_PAIRING_KEY` | empty | Optional pairing identity override; web setup can derive and persist this instead |
| `SCANSNAP_CLIENT_IP` | empty | Optional client IP override for macvlan/static-IP deployments |
| `SCANSNAP_MAC_PREFIXES` | `84:25:3f,00:80:92,00:40:17` | MAC prefixes sorted first in Wi-Fi discovery |
| `SCANSNAP_DISCOVERY_TARGETS` | empty | Comma-separated explicit IP/broadcast targets to probe during setup |
| `SCANSNAP_DISCOVERY_ARP_ALL` | `false` | Probe all ARP neighbors, not only neighbors matching known ScanSnap/Silex MAC prefixes |
| `SCANSNAP_DISCOVERY_TIMEOUT_SECONDS` | `4` | First-run scanner discovery timeout |
| `SCANSNAP_DISCOVERY_ROUNDS` | `2` | Number of discovery packet send rounds per target |
| `WEB_PORT` | `8080` in app, `80` in Compose | Web UI port |
| `SCANSNAP_BUTTON_SCAN_ENABLED` | `true` | Enable physical scanner button listener |
| `SCANSNAP_BUTTON_PORT` | `55265` | UDP port for ScanSnap button notices |
| `SCANSNAP_STARTUP_ADVERTISEMENT_PORT` | `53220` | UDP port on which the scanner announces startup/power-on |
| `SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS` | `300` | Slow safety-net interval for a full button-session re-arm while idle |
| `SCANSNAP_BUTTON_ARM_TIMEOUT_SECONDS` | `45` | Timeout for one button arming attempt |
| `SCANSNAP_BUTTON_HEARTBEAT_INTERVAL_SECONDS` | `0.5` | Interval for retaining an armed scanner session over UDP `52217`; `0` disables the heartbeat |
| `SCANSNAP_BUTTON_HEALTH_INTERVAL_SECONDS` | `10` | TCP reachability check interval while the button session is armed |
| `SCANSNAP_BUTTON_STARTUP_REARM_DEBOUNCE_SECONDS` | `3` | Quiet gap that separates repeated startup packets into distinct power-on advertisement bursts |
| `SCANSNAP_BUTTON_REACHABILITY_PORT` | `53219` | TCP port used to check whether the scanner is awake before arming |
| `SCANSNAP_BUTTON_REACHABILITY_TIMEOUT_SECONDS` | `1` | Timeout for one scanner reachability check |
| `SCANSNAP_BUTTON_REACHABILITY_INTERVAL_SECONDS` | `3` | Retry interval while the scanner is offline or the session is unarmed |
| `SCANSNAP_BUTTON_DEBOUNCE_SECONDS` | `3` | Collapse repeated button packets into one scan |
| `SCANSNAP_BUTTON_COOLDOWN_SECONDS` | `1` | Ignore duplicate button notices shortly after a scan finishes |
| `SCANSNAP_REGISTRATION_SOURCE_PORT` | `55264` | Preferred local UDP source port for registration and heartbeat traffic |
| `SCANSNAP_REGISTRATION_PORT` | `52217` | Scanner UDP destination port for registration and heartbeat traffic |

`SCANSNAP_BUTTON_REGISTRATION_INTERVAL_SECONDS` remains accepted as a compatibility alias for
`SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS` when the current variable is absent.

## Scan Directory Access Check

At startup, scannerserver verifies that `SCAN_OUTPUT_DIR` exists and that the service user can
list it and create, read, update, and delete a temporary access-check file. The check does not
modify any scan or settings file.

If the check fails, the HTTP service remains available but the main page returns a dedicated
configuration error page instead of a generic HTTP 500 response. The page shows the configured
path and the filesystem error. Every main-page request repeats the access check, so correct the
bind mount, directory path, or host UID/GID permissions and refresh the page; restarting the
service is not required. Physical-button handling keeps retrying its configuration independently,
and `/health` remains available while the scan directory is inaccessible.

## Blank Page Removal

Blank-page removal is enabled by default for PDF scans. Analysis ignores the outer three percent
of the embedded page image so the scanner border and edge shadows are not mistaken for content.

Useful settings:

```yaml
environment:
  SCAN_REMOVE_BLANK_PAGES: "true"
  SCAN_BLANK_WHITE_THRESHOLD: "230"
  SCAN_BLANK_CONTENT_RATIO_THRESHOLD: "0.003"
  SCAN_BLANK_MEAN_THRESHOLD: "248.0"
```

Enable debug logging for one scan:

```yaml
environment:
  SCAN_BLANK_DEBUG: "1"
```

Disable the feature:

```yaml
environment:
  SCAN_REMOVE_BLANK_PAGES: "false"
```

## Automatic Page Cropping

Automatic page cropping is enabled by default for PDF scans. It detects smaller documents, such
as receipts, on a larger scanner page and crops the PDF page boxes around the detected document
before OCR runs. For a full sheet whose shadows or paper texture reach every image edge, a
physical-page fallback uses median row and column transitions to remove the scanner border
without trimming the paper itself.

Useful settings:

```yaml
environment:
  SCAN_CROP_PAGES: "true"
  SCAN_CROP_BACKGROUND_DELTA: "8"
  SCAN_CROP_MARGIN_POINTS: "1"
```

`SCAN_CROP_MARGIN_POINTS` is stored separately for each scan mode in the web UI. Set it to `0`
for the tightest detected crop or increase it when irregular paper edges need more protection. The
physical-page fallback used for full sheets does not add this margin because it already detects
the paper edge directly.

Enable crop debug logging:

```yaml
environment:
  SCAN_CROP_DEBUG: "1"
```

Disable cropping:

```yaml
environment:
  SCAN_CROP_PAGES: "false"
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

Check the scanner from the host:

```bash
ping SCANNER_IP
```

Check the container network view:

```bash
docker compose exec scansnap ip addr
docker compose exec scansnap ip neigh show
```

## Physical Button Troubleshooting

If button presses do nothing, first look for:

```text
ScanSnap button client armed
```

After that line, the service sends the session heartbeat every 500 ms. A scanner power-on should
also produce `ScanSnap startup advertisement received from <scanner-ip>` followed by a fresh arm.
If you see arming timeouts, the scanner is usually offline, asleep, on the wrong Wi-Fi/VLAN, or
not reachable from the container IP. The host-network firewall must allow inbound UDP `53220` and
`55265`, and traffic to the scanner on UDP `52217` and TCP `53218`/`53219`.

Packet direction summary:

```text
scanner  -> service UDP 53220   startup advertisement
service  -> scanner UDP 52217   registration and 500 ms heartbeat
scanner  -> service UDP 55265   physical-button notice
service  -> scanner TCP 53219   reachability and pairing/control
service  -> scanner TCP 53218   scan acquisition
```

On the Linux host, an optional packet capture can distinguish missing advertisements, heartbeats,
and button notices:

```bash
sudo tcpdump -ni any 'udp port 52217 or udp port 53220 or udp port 55265'
```

Expected recovery behavior:

1. Power-on advertisement: re-arm immediately after the first valid packet in the boot burst.
2. Any web or physical-button scan: stop the heartbeat before acquisition and re-arm immediately
   after completion.
3. Failed or cancelled scan: release potentially stale state, then perform a recovery arm.
4. Failed health check: mark the scanner offline and retry every three seconds.
5. Missed event: perform a full safety re-arm after five idle minutes.
