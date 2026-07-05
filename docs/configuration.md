# Configuration and Scan Behavior

## Output Files

PDF scans produce a source PDF immediately and an OCR PDF later if OCR is enabled:

```text
YYYY-MM-DD.HHMMSS.pdf
YYYY-MM-DD.HHMMSS.ocr.pdf
```

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

With the ScanSnap Wi-Fi backend, modes control simplex/duplex, output conversion, OCR, blank-page removal, and autocrop. The reverse-engineered Wi-Fi scanner command does not expose resolution or color controls. `SCAN_RESOLUTION`, `SCAN_MODE`, and `SCAN_SOURCE` are mainly for the SANE fallback backend.

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
| `SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS` | `60` | How often to re-arm the button client while idle |
| `SCANSNAP_BUTTON_ARM_TIMEOUT_SECONDS` | `45` | Timeout for one button arming attempt |
| `SCANSNAP_BUTTON_REACHABILITY_PORT` | `53219` | TCP port used to check whether the scanner is awake before arming |
| `SCANSNAP_BUTTON_DEBOUNCE_SECONDS` | `3` | Collapse repeated button packets into one scan |
| `SCANSNAP_BUTTON_COOLDOWN_SECONDS` | `10` | Ignore button notices shortly after a scan finishes |

## Blank Page Removal

Blank-page removal is enabled by default for PDF scans.

Useful settings:

```yaml
environment:
  SCAN_REMOVE_BLANK_PAGES: "true"
  SCAN_BLANK_WHITE_THRESHOLD: "245"
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

## Receipt / Small Page Cropping

Automatic page cropping is enabled by default for PDF scans. It detects smaller documents, such as receipts, on a larger scanner page and crops the PDF page boxes around the detected document before OCR runs.

Useful settings:

```yaml
environment:
  SCAN_CROP_PAGES: "true"
  SCAN_CROP_BACKGROUND_DELTA: "8"
  SCAN_CROP_MARGIN_POINTS: "12"
```

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

If button presses do nothing, look for:

```text
ScanSnap button client armed
```

If you see arming timeouts, the scanner is usually offline, asleep, on the wrong Wi-Fi/VLAN, or not reachable from the container IP.
