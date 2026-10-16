---
title: Scan Project Comparison
description: Source-based assessment of holgerkrupp/Scan for broader scanner support, multiple devices, protocol validation, and image processing in scannerserver.
type: reference
audience: maintainers and agents
status: current
last_updated: 2026-10-16
---

# Scan Project Comparison

Reviewed on 2026-10-16 against
[`holgerkrupp/Scan` at `5ca3d40`](https://github.com/holgerkrupp/Scan/tree/5ca3d40b6e3d8b949d4c341642771172230410d0)
(upstream commit dated 2026-10-11) and scannerserver at `83ea0d4`.
This is a source review and a set of proposals, not a claim of newly implemented or tested hardware
support. No scanner commands were sent and neither upstream's tests nor hardware tests were run.

## Assessment

Scan is useful primarily as a reference for **USB model support, explicit capabilities and quirks,
and protocol regression testing**. Its native ScanSnap backends use Fujitsu SCSI-over-USB or the
separate epjitsu bulk-USB protocol. Our native backend uses the iX500's VENS Wi-Fi protocol. Scan
does not supply a replacement for our discovery, pairing, retained button session, or heartbeat,
and does not establish Wi-Fi support for newer ScanSnap models.

There are two distinct meanings of multiple-scanner support:

| Goal | What Scan contributes | What scannerserver still needs |
| --- | --- | --- |
| Support more scanner models | USB IDs, model profiles, command details, hardware findings, and tests | Validate our existing SANE path first; optionally implement a Linux native USB backend |
| Select among several installed scanners | Driver registry, identities, per-device profile/destination settings | A persistent device registry and scanner selection throughout setup and scan requests |
| Keep several physical buttons active or scan concurrently | No complete implementation to reuse: Scan monitors the selected scanner and has one active acquisition | Per-device session ownership, shared network event routing, scheduling, and safe output allocation |

The highest-value changes that do not require a new hardware backend are capability descriptions,
stronger protocol fixtures, and an evaluation of adaptive blank-page detection. Multiple active
iX500s is a separate service feature; copying additional USB model profiles would not implement it.

## Upstream Evidence And Limits

The [model profiles](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/FujitsuSCSIOverUSB/FujitsuScanSnapModelProfile.swift)
and [architecture notes](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/ScannerArchitecture.md)
distinguish validated models from profiles inferred from related hardware. Their reported validation
is useful evidence, but must be repeated on our Linux/container path before we advertise support.

| Family | Upstream evidence | Consequence for us |
| --- | --- | --- |
| S1500/S1500M | Validated USB reference flow | A reasonable legacy-model target for SANE validation or a later native USB implementation |
| S510/S510M | S510M hardware validation; optional buffer page can be rejected and BGR interlace is needed | Preserve model quirks rather than treating every legacy scanner like an S1500 |
| iX500/iX500EE | iX500 USB validation; EE identity is an unvalidated variant | USB findings complement our Wi-Fi implementation; they do not validate a Wi-Fi change |
| iX1600 | USB validation including native gray/line-art, JPEG, buffering, and batch completion | Most informative newer-model reference; still a USB path |
| iX1300/iX1400/iX1500 | Profiles inherit iX1600 behavior without their own hardware validation | Candidate support, not confirmed compatibility; iX1300 return-path scanning is not implemented |
| S1300i | Separate epjitsu acquisition validated with AC power | Separate driver family and firmware handling; do not route through the SCSI-over-USB engine |
| S300/S300M/S1300 and older fi-series variants | Experimental, preliminary, or protocol-backed support with differing validation gaps | Do not copy the advertised model list as a production compatibility promise |

For S1300i, the current
[epjitsu implementation](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/EpjitsuUSB/ScanSnapS300Driver.swift)
and README are more specific than some older passages in the architecture notes. Use code, the
hardware harness, and per-model evidence together when these descriptions disagree.

## Multiple Devices: Useful Patterns, But No Ready-Made Solution

Scan's
[driver interfaces and registry](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/ScannerCore/ScannerDriver.swift)
separate discovery, acquisition, USB transport, and optional button events. Its
[settings model](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/ScannerCore/ScannerModels.swift)
can assign profiles and destinations per identity. These are useful design references.

However, `HardwareScanCoordinator` owns one task and one device, and
`restartHardwareMonitoring()` chooses `selectedIdentity ?? discoveredIdentities.first`. The
[workspace](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/ViewModels/ScannerWorkspaceViewModel.swift)
also owns one `activeDevice` and an `isScanning` flag. A list of discovered devices does not mean
simultaneous acquisition or button observation for all devices.

There is also a specific selection limitation to avoid copying: `openWithVendorID` receives a
`locationID`, but first calls a libusb helper that accepts only vendor/product IDs and uses
`libusb_open_device_with_vid_pid`. That preferred path does not select by serial or USB location.
Consequently, selecting between two identical models is not reliably tied to the chosen identity
by that path. This is a static finding, not a reproduced hardware failure. See
[`ScanUSBHostTransport.m`, lines 58–65 and 439–456](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/USBTransport/ScanUSBHostTransport.m#L439-L456).

Our current constraints are explicit in the implementation:

- [Discovery](../Sources/ScannerServerCore/ScanSnap/Network/ScanSnapDiscoveryActor.swift) already
  returns multiple devices; [setup](../Sources/ScannerServerCore/ScanSnap/Setup/ScanSnapSetupService.swift)
  supports choosing one.
- [ScannerConfigStore](../Sources/ScannerServerCore/Settings/SettingsStores.swift) persists one
  [ScannerConfig](../Sources/ScannerServerCore/Settings/ScannerConfig.swift).
- [ScanJobActor](../Sources/ScannerServerCore/ScanPipeline/ScanJobActor.swift) provides one global
  acquisition slot.
- The [button runtime](../Sources/ScannerServerCore/Runtime/Button/ScanSnapButtonRuntimeController.swift)
  owns one lifecycle; that
  [lifecycle](../Sources/ScannerServerCore/ScanSnap/Button/ScanSnapButtonLifecycleActor.swift)
  accepts notices only from the configured IP.

A proposed staged implementation would:

1. Add a registry with stable device identities and a default device, preserving existing single
   scanner JSON and environment behavior through a compatible migration or an additional registry
   file. Treat an IP as an address, not the permanent identity; use known serial/MAC information.
2. Carry a selected scanner explicitly through the web request, acquisition configuration, status,
   and cancellation. Keep acquisition globally serialized initially, and define what happens to a
   button press while another scanner is busy rather than silently losing it.
3. Give each enabled Wi-Fi scanner its own heartbeat, reachability, debounce, recovery, and session
   handoff state. Use shared UDP receivers for `55265` button events and `53220` startup events,
   dispatching validated datagrams to the right device. Define ownership/demultiplexing for source
   port `55264` registration traffic as well. Instantiating the present socket-owning lifecycle
   several times is insufficient.
4. Add parallel acquisition only after device isolation and output allocation are proven. Existing
   second-resolution names need an atomic reservation policy within the accepted filename format,
   or an explicitly agreed naming extension. Keep the shared OCR queue and its global resource
   budget; cancellation or reboot of one scanner must not affect another.

Use a registry actor and per-device session actors under our Swift 6 strict-concurrency contract;
Scan's UI-oriented ownership model is not a substitute for that service boundary. Test two
same-model identities, event routing, simultaneous button presses, individual cancellation,
disconnect/reconnect, and two acquisitions that request the same timestamp before enabling it.

## Protocol Knowledge Worth Retaining

### Explicit Capabilities And Quirks

Scan isolates such decisions as pre-read diagnostics, JPEG quantization-table setup, hopper checks,
color interlace, native versus emulated monochrome, read size, gamma behavior, and closing commands
in model profiles. Its VPD
[parser](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/FujitsuSCSIOverUSB/FujitsuVitalProductData.swift)
also records device-reported capabilities for diagnostics; it does not dynamically replace the
profiles with those flags.

Concrete USB examples include 256 KiB image reads for iX500/iX1600 versus 32 KiB for S1500, and an
iX1600 batch-closing cancel needed to avoid a reported firmware lock-up. These are valuable for a
USB backend. They do not justify changing our TCP read sizes or D6 retained-session behavior.
Likewise, USB `GET HW STATUS` button polling is separate from our UDP button notices.

Our current Wi-Fi path deliberately uses a fixed acquisition setup. The
[request](../Sources/ScannerServerCore/ScanSnap/Acquisition/ScanSnapAcquisitionModels.swift) carries
no DPI or color-mode selection, the
[setup commands](../Sources/ScannerServerCore/ScanSnap/Acquisition/ScanSnapAcquisitionPacketBuilder.swift)
are fixed, and the [PDF writer](../Sources/ScannerServerCore/ScanSnap/Acquisition/ScanSnapPDFWriter.swift)
assumes 300 DPI and RGB. This is already documented in [configuration.md](configuration.md).

Scan's USB window descriptors are useful investigative references for eventually exposing Wi-Fi
DPI, compression, or color controls, but the USB `SET WINDOW` flow and our Wi-Fi setup differ.
They are not interchangeable commands. Such work needs Wi-Fi captures for each changed setting,
byte-level fixtures, actual page measurements, and matching PDF metadata. Do not expose these
settings merely because the physical model supports them over USB.

### JPEG Handling And Tests

The Foundation-based
[JPEG splitter](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/FujitsuSCSIOverUSB/FujitsuJPEGStreamSplitter.swift)
handles USB interlaced duplex streams, missing JFIF headers, and iX1600 JPEGs whose declared height
must be corrected using restart intervals. Those are useful future USB fixtures, not established
faults in our iX500 Wi-Fi output. Our
[JPEG buffer](../Sources/ScannerServerCore/ScanSnap/Acquisition/ScanSnapJPEGBuffer.swift) currently
extracts separate images by SOI/EOI markers and enforces a byte limit. Its framing could be hardened
with segment-aware tests before supporting other image formats or scanners, without importing
USB-specific rewriting into the existing Wi-Fi path.

Scan's
[transcript tests](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/ScanTests/FujitsuCommandTranscriptTests.swift)
use a scripted transport to pin complete command sequences. Many fixtures were generated against
that simulator from a previously validated implementation; they are regression baselines, not raw
hardware captures. We already have injected transports and Wi-Fi acquisition/session tests, so we
can extend that approach with sanitized Wi-Fi sequences covering retained-session handoff,
transfer-batch continuation, errors, and recovery. Keep pairing identities and document contents
out of committed traces. Also retain the
[real-hardware checklist](swift-hardware-validation.md): a scripted sequence alone does not prove
compatibility.

## Image Processing Opportunities

Scan's [blank-page analysis](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/OutputPipeline/ScanImageProcessor.swift)
judges ink relative to the page's median luminance, excludes the outer 3%, and rejects dark pages
as blank candidates. Our
[analysis](../Sources/ScannerServerCore/Documents/NativeTools/NativeDocumentToolExecutor+PageProcessing.swift)
already excludes the outer 3%, but uses an absolute white threshold plus a mean-luminance guard.
Adaptive paper estimation is therefore a concrete experiment for gray paper and scanner gamma
variation. Compare false removals on faint text, pencil, receipts, tinted paper, photos, and
bleed-through before changing defaults; upstream's contrast threshold must not become an
unvalidated deletion rule. Preserve current persisted settings and the keep-one-page safeguard.

Its paper whitening and distinction between straightening the sheet and cropping to printed content
are also useful product ideas. However,
[page alignment](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/Scan/OutputPipeline/PageAlignment.swift)
depends on Apple Vision, and rendering uses AppKit/CoreGraphics. A Linux implementation would need
different primitives and independent image-quality validation. Apple Intelligence document naming
is similarly not a portable dependency for this service.

## Practical Adoption Order

1. **Record capabilities and strengthen protocol tests.** Describe the current Wi-Fi backend
   honestly, keep existing wire behavior, and capture reproducible regression fixtures. This also
   establishes the boundary needed for additional backends.
2. **Choose the hardware expansion goal.** For several existing iX500s, implement the staged
   registry/session work above. For new USB models, exercise `SCAN_BACKEND=sane` and `SCAN_DEVICE`
   through our existing acquisition path first, using the target image's actual SANE version and
   device permissions. The image already includes `sane-utils`; Scan's compatibility table does not
   establish what Ubuntu's packaged backend supports. USB access and non-root permissions need
   explicit container validation. Our current Wi-Fi physical-button runtime does not add USB button
   support to SANE acquisitions.
3. **Evaluate adaptive blank detection independently.** Use a labeled page corpus and compare it
   with current behavior before adding an opt-in setting or changing any default.
4. **Port native USB code only for a demonstrated need.** Extract profiles, protocol codecs, and
   tests; provide a Linux libusb transport, stable selection by serial/port path, and Linux image
   conversion. Wire results into our existing processing/OCR pipeline. Defer epjitsu firmware and
   calibration work until a specific target model requires it.
5. **Investigate new Wi-Fi controls separately.** Use USB findings as hypotheses and validate them
   on the actual Wi-Fi transport. Newer-model Wi-Fi support remains a distinct reverse-engineering
   effort.

The native port is more than adding a dependency: Scan is an Xcode application, the shared USB
device/command-engine file imports AppKit, discovery imports IOKit, and its Objective-C transport
mixes libusb with Apple USB APIs. Its app target also uses Swift 5 language mode with default
MainActor isolation; extracted code must be checked under our Swift 6.3 complete concurrency
settings, with mutable device state isolated explicitly.

Both projects carry MIT licenses. Preserve upstream's copyright and license notice if code or
substantial test fixtures are imported; no upstream implementation was copied by this review.
See [upstream LICENSE](https://github.com/holgerkrupp/Scan/blob/5ca3d40b6e3d8b949d4c341642771172230410d0/LICENSE).
The epjitsu path expects user-supplied model firmware; this review does not propose distributing it.

## First Adoption: Capabilities And Regression Tests

The first follow-up adds
[`ScanSnapWiFiCapabilities.ix500`](../Sources/ScannerServerCore/ScanSnap/ScanSnapWiFiCapabilities.swift)
and [hardware-free protocol transcripts](protocol.md#hardware-free-protocol-regression-transcripts).
The descriptor explains the existing fixed acquisition quality and simplex filtering in the preset
UI. Stored settings and the acquisition, pairing, and button-session wire implementation are
unchanged. Full-frame synthetic fixtures frozen from `83ea0d4` pin the current protocol sequences.
This follow-up does not introduce another scanner model or multiple active devices.

## Validation Scope

The original comparison changed documentation only. The capability and transcript follow-up also
requires `swift build` and `swift test`, plus YAML/front-matter, local-link, and `git diff --check`
validation. Container files and wire/session behavior are unchanged. The transcripts are regression
evidence; future hardware-support or protocol changes still require opt-in real-hardware checks.
The remaining adoption steps above are proposals.
