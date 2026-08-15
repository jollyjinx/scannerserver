---
title: Configuration and Scan Behavior
description: Environment variables, output naming, scan modes, and post-processing behavior.
type: reference
audience: operators
status: current
---

# Configuration and Scan Behavior

## Output Files

Multipage PDF scans produce a source PDF immediately and an OCR PDF later if OCR is enabled:

```text
YYYY-MM-DD.HHMMSS.pdf
YYYY-MM-DD.HHMMSS.ocr.pdf
```

The date and time prefix uses the service's `TZ` setting, including daylight-saving changes. The
web status timestamps and file-list day headings use the same time zone.

For multipage PDF mode, the acquisition lifecycle finishes as soon as the source PDF is published.
For single-page PDF and PNG modes, it finishes after the captured raw document is handed to the
background queue; blank removal and crop still run across the complete document before the queue
publishes individual files. The web scan control and physical button can therefore accept another
scan while blank-page removal, crop, final-output conversion, or OCR is still running. Without OCR,
the background queue processes an isolated multipage copy and atomically replaces the source PDF.
With OCR, it leaves the source unchanged and publishes the processed `.ocr.pdf`.

For OCR-enabled multipage ScanSnap Wi-Fi scans, each page is OCRed and autocropped before ordered
assembly. A capable remote worker performs both operations; local fallback preserves the same
crop settings. Document-wide blank-page removal, metadata, and atomic publication still happen on
scannerserver. Other backends and output modes retain their established whole-document processing
order.

Deleting a source scan while processing is active cancels that document's work before removing the
file. Matching queued work is removed as well, while jobs for other scans continue.

Single-page PDF modes use:

```text
YYYY-MM-DD.HHMMSS-page-0001.pdf
YYYY-MM-DD.HHMMSS-page-0001.ocr.pdf
```

These individual files appear after background blank removal, crop, metadata, and splitting finish.
OCR variants then appear beside them as their queued jobs complete. PNG exports follow the same
deferred final-output lifecycle.

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

Use **Presets** in the web UI to add, edit, delete, or choose the mode used by the physical scanner button. The **Scanner** page only selects a preset and starts a scan; **Settings** contains scanner connection management.

With the ScanSnap Wi-Fi backend, modes control simplex/duplex, output conversion, OCR, the background CPU limit and post-scan process priority, blank-page removal, autocrop, and the extra margin kept around cropped content. The OCR card offers a **Processing CPUs** dropdown: **Automatic** uses the container-aware background allowance, while a number lowers the limit for that mode. **Post-scan priority** selects normal or reduced (`nice`) priority for every external tool launched by background processing. The reverse-engineered Wi-Fi scanner command does not expose resolution or color controls. `SCAN_RESOLUTION`, `SCAN_MODE`, and `SCAN_SOURCE` are mainly for the SANE fallback backend. The web UI shows a short explanation beneath every mode setting.

## Common Environment Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `TZ` | `Europe/Berlin` | Local IANA time zone used for scan filenames, file grouping, and status timestamps |
| `SCAN_OUTPUT_DIR` | `/scans` | Output directory inside the container |
| `TMPDIR` | `<SCAN_OUTPUT_DIR>/.ocr-tmp` | Writable temporary directory created at startup and used by OCRmyPDF, Ghostscript, Tesseract, and other document tools |
| `SCAN_SETTINGS_PATH` | `/scans/.scanner-settings.json` | Saved scan modes and button-default mode |
| `SCANNER_CONFIG_PATH` | `/scans/.scannerserver-scanner.json` | Saved Wi-Fi scanner IP and derived pairing identity |
| `SCAN_BACKEND` | `wifi` | `wifi` for iX500 Wi-Fi protocol, `sane` for SANE fallback |
| `SCAN_LANGUAGE` | `deu+eng` | OCR languages passed to OCRmyPDF/Tesseract |
| `SCAN_FORMAT` | `pdf` | `pdf` or `png` |
| `SCAN_PAGE_MODE` | `multi` | `multi` for one multipage PDF, `single` for one PDF per page |
| `SCAN_OCR_ENABLED` | `true` | Queue OCR for PDF output after scanning |
| `SCAN_OCR_CPU_LIMIT` | detected CPUs minus one | Optional positive cap on CPUs used by background page processing and OCR; values above the background allowance are clamped |
| `SCAN_OCR_NICE` | `false` | Run post-scan document-processing subprocesses with reduced CPU scheduling priority |
| `SCAN_OCR_NICE_LEVEL` | `10` | Nice increment from `1` through `19` when `SCAN_OCR_NICE` is enabled |
| `SCAN_OCR_WORKERS_PATH` | `<SCAN_OUTPUT_DIR>/.scannerserver-ocr-workers.json` | Registered OCR worker identities, approvals, and last-known state |
| `SCAN_OCR_WORKER_JOBS_PATH` | `<SCAN_OUTPUT_DIR>/.scannerserver-ocr-jobs.json` | Durable remote OCR job manifests, lease state, and terminal results |
| `SCAN_INTERNAL_OCR_WORKER_PATH` | `<SCAN_OUTPUT_DIR>/.scannerserver-internal-ocr-worker.json` | Persisted pause state for scannerserver's internal OCR fallback worker |
| `SCAN_OCR_REMOTE_ENABLED` | `true` | Dispatch OCRmyPDF work to approved compatible workers when available; local OCR remains the fallback |
| `SCAN_OCR_REMOTE_ASSIGNMENT_WAIT_SECONDS` | `30` | Time an eligible remote job may remain unclaimed (including after lease expiry) before local fallback |
| `SCAN_OCR_REMOTE_COMPLETION_TIMEOUT_SECONDS` | `3600` | Maximum total remote job duration before cancellation and local fallback |
| `SCAN_OCR_WORKER_MAX_RESULT_BYTES` | `1073741824` | Maximum PDF upload size accepted from an authenticated worker |
| `SCAN_OCR_WORKER_BONJOUR_ENABLED` | `false` | Publish `_scannerserver._tcp` for OCR worker discovery through `avahi-publish-service` |
| `SCANNERSERVER_BONJOUR_NAME` | `scannerserver` | Bonjour service instance name |
| `SCANNERSERVER_BONJOUR_HOST` | process hostname | Host used to derive the advertised URL when no complete URL is configured |
| `SCANNERSERVER_BONJOUR_URL` | derived HTTP URL | Complete LAN-reachable HTTP(S) URL placed in the Bonjour TXT record |
| `SCAN_CROP_PAGES` | `true` | Crop PDF pages to the detected paper or content bounds in background processing |
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
| `SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS` | `0` | Optional interval for replacing a healthy button session; `0` disables periodic replacement |
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

## Background Processing CPU Scheduling And Priority

Background page processing and OCR automatically use the CPU allowance visible to the service. The detector considers the
process's active processor count plus Linux cgroup CPU quota and cpuset restrictions, so Docker
CPU limits are honored. One detected processor is reserved for acquisition, button handling, and
HTTP work (a one-CPU container still gets one worker). `SCAN_OCR_CPU_LIMIT` can lower the remaining
allowance but cannot raise it. It can be configured globally in the container environment or per
scan mode with the web UI. A mode set to **Automatic** inherits this container-aware allowance.

The queue treats the resulting value as one shared CPU budget:

- Multipage blank detection and crop analysis process several pages concurrently, bounded by the
  shared budget; operations within each page remain ordered.
- Streaming ScanSnap pages can move OCR and autocrop to capability-compatible remote workers. Local
  fallback consumes the scanner host's shared budget with the same per-page order and settings.

- A multipage PDF reserves the full budget and passes it to OCRmyPDF with `--jobs` so its pages
  are processed in parallel.
- Single-page PDF mode starts one OCRmyPDF process per page, up to the budget, and gives each
  process `--jobs 1`.
- Multipage and single-page work do not oversubscribe each other. FIFO ordering is preserved when
  the next document needs more CPU slots than are currently free.

Post-scan processing runs at normal process priority by default so a busy service host cannot starve
background work. Reduced-priority mode remains available as an explicit opt-in, globally through
the environment or per scan mode through **Post-scan priority** in the web UI. When enabled, the
nice level applies to every external tool launched after scanner acquisition releases its foreground
lifecycle, including blank removal, autocrop, final output conversion, metadata updates, and OCR.
The scannerserver process and scanner acquisition remain at normal priority. The global nice level
controls the increment used by niced modes. To use at most four CPUs and a nice level of `+15`:

```yaml
environment:
  SCAN_OCR_CPU_LIMIT: "4"
  SCAN_OCR_NICE: "true"
  SCAN_OCR_NICE_LEVEL: "15"
```

The status page reports the active CPU budget, process priority, running background job count, and
queued job count.

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
service  -> scanner TCP 53218   D6 command finalization and scan acquisition
```

On the Linux host, an optional packet capture can distinguish missing advertisements, heartbeats,
and button notices:

```bash
sudo tcpdump -ni any 'udp port 52217 or udp port 53220 or udp port 55265'
```

Expected recovery behavior:

1. Power-on advertisement: re-arm immediately after the first valid packet in the boot burst.
2. Any web or physical-button scan: stop the heartbeat, finish the current command sequence with
   D6 on TCP `53218`, and hand the already registered session to native acquisition. On success,
   resume its heartbeat without another registration.
3. Failed or cancelled scan: finalize potentially stale state, then perform a recovery arm. If a
   valid button notice arrives during that recovery, cancel recovery and reuse the session that the
   scanner has just confirmed is still routed to this client.
4. Failed health check: mark the scanner offline and retry every three seconds.
5. Optional diagnostic fallback: when `SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS` is greater than zero,
   finalize and replace a healthy session after that idle interval. This is disabled by default
   because unnecessary fresh registrations can themselves produce `-7` and an unarmed interval.

`scanner rejected registration (error -7)` immediately after a button notice means the scanner
still considers a session owner active. If `ScanSnap button client armed` appeared first, the scan
must reuse that armed session; a second UDP registration is a protocol error, not a recovery step.
Confirm the image includes native session handoff support and that the lifecycle and Swift
acquisition client derive the same client IP and MAC.
