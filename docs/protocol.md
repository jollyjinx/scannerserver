---
title: ScanSnap Protocol Notes
description: Reverse-engineered ScanSnap iX500 Wi-Fi protocol details used by scannerserver.
type: reference
audience: maintainers
status: current
---

# ScanSnap Protocol Notes

## Why This Uses The ScanSnap Wi-Fi Protocol

The iX500 does not behave like a normal eSCL/AirScan scanner in this setup. This project uses the reverse-engineered ScanSnap Wi-Fi protocol implemented by [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap), built into the image as `scansnap-wifi`.

Important ports and packet directions:

| Port | Direction | Purpose |
| --- | --- | --- |
| UDP `52217` | service → scanner | ScanSnap discovery, registration, and armed-session heartbeat |
| UDP `53220` | scanner → service | Scanner startup/power-on advertisement |
| TCP `53219` | service → scanner | Pairing/control handshake and reachability check |
| TCP `53218` | service → scanner | Scan control/data and D6 command-sequence finalization |
| UDP `55264` | service-side source port | Registration and heartbeat socket; may fall back to an ephemeral port when explicitly allowed |
| UDP `55265` | scanner → service | Physical-button notice |

`53220` is the startup-advertisement destination port. `52217` is the scanner's registration and
heartbeat destination; the similar numbers represent different directions and responsibilities.

## First-Run Discovery

The iX500 exposes a 132-byte VENS UDP device-info response before TCP pairing. That response is unauthenticated and includes:

```text
offset 28..33    scanner MAC address
offset 40..103   scanner serial number
offset 104..119  display name
```

The web setup flow:

1. Repeatedly sends VENS discovery/registration packets to LAN broadcast addresses and ARP neighbors with known ScanSnap/Silex MAC prefixes while setup remains unresolved.
2. Automatically selects a sole discovered ScanSnap, or lists multiple devices for user selection, without interrupting manual form input.
3. Lets the user enter an IPv4 address or host name and one credential value containing either the scanner password or product serial number. Host names are resolved to IPv4 before protocol traffic begins.
4. Attempts targeted discovery at that address so the scanner can supply its serial number directly.
5. Tests the discovered serial-derived default, or the entered value's last four characters as a possible serial-derived default, against TCP `53219`.
6. Falls back to testing the complete entered value as the scanner password. Failed manual values remain in the browser's tab-scoped session storage for correction.
7. Saves the working scanner IP and pairing identity in `/scans/.scannerserver-scanner.json`.

Discovery intentionally does not sweep every IP address in the subnet.

## Scanner On Another Network

Layer-2 broadcast discovery and ARP Ethernet addresses do not normally cross a router. To configure
a scanner on another routed network, enter its routable IPv4 address or a host name that resolves
to one, plus either its product serial number or its scanner password in the unified credential
field.

When targeted UDP discovery reaches the scanner, the app reads the serial number automatically and
tries its factory-default password first. If that lookup is blocked, the app tries the last four
characters of the entered value as a possible serial-derived default and then tries the complete
value as the scanner password. The manual web flow does not accept an Ethernet/MAC address or a
generated pairing identity.

The routed path and its firewall must still permit UDP `52217` for discovery/registration and TCP
`53218`/`53219` for scanner control and data. Physical-button delivery additionally requires the
scanner to reach the service on UDP `55265`; power-on detection requires its UDP `53220` startup
advertisement to reach the service.

## Pairing Key From Serial Number

For a factory-default iX500 password, you do not need to packet-capture ScanSnap software.

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

Quick calculator:

```bash
swift - <<'SWIFT'
import Foundation

let serial = "AWRHC08122"
let password = String(
    serial.reversed().drop(while: \.isWhitespace).prefix(4).reversed()
)
let key = Array("pFusCANsNapFiPfu".unicodeScalars)
let pairingKey = password.unicodeScalars.enumerated().map { index, character in
    String(character.value + key[index].value + 11)
}.joined()

print(pairingKey)
SWIFT
```

If the scanner password was changed in ScanSnap Wireless Setup Tool, use that password instead of the serial suffix. If you do not know the changed password, reset/reconfigure the scanner wireless settings or capture the key from an already configured official ScanSnap client.

The Ethernet/MAC address is not part of this calculation. This derivation is also documented by [`mzyy94/AirScap`](https://github.com/mzyy94/AirScap/blob/master/protocol.en.md).

### Long Password Hardware Validation

The Wireless Setup Tool permits scanner passwords up to 16 characters. For printable ASCII,
the derived decimal pairing identity normally uses three bytes per password character and can
therefore require up to 48 bytes.

Real-iX500 validation confirmed that the existing 128-byte VENS `0x11` reservation frame accepts
the complete identity in bytes `52..<100`. A scanner configured with a six-character password
rejected the identity truncated to 16 bytes with status `-1` and accepted the complete 18-byte
identity with status `0`. The larger 384-byte reservation variant was consequently not required
for that scanner.

Both the Swift VENS packet builder and the container's patched `scansnap-wifi` binary populate
the complete 48-byte identity field. The `scansnap-wifi --getkey` capture path also reads all 48
bytes so identities captured from official software are not truncated.

Run the opt-in diagnostic with credentials supplied only through the process environment:

```bash
SCANNERSERVER_RUN_SCANSNAP_HARDWARE_TESTS=1 \
SCANSNAP_TEST_IP=SCANNER_IP \
SCANSNAP_TEST_PASSWORD=SCANNER_PASSWORD \
swift test --filter ScanSnapLongPasswordHardwareTests
```

The test first verifies that the legacy 16-byte truncation is rejected, then tries the complete
identity in the 128-byte frame. It tries the 384-byte official-password reservation frame only if
the full-width 128-byte frame is rejected. Successful probes finish their temporary command
sequence with D6 before returning; the scanner may retain that client's ownership claim briefly.
Never commit the hardware password or a generated pairing identity.

## Wi-Fi Image Transfer Batches

The iX500 can finish one Wi-Fi image-transfer connection while sheets still remain in the feeder.
In real-hardware validation with duplex documents, one transfer ended after 18 physical sheets (36
JPEG sides and approximately 23 MB of image data). The scanner accepted a fresh protocol session
immediately and delivered the remaining sheets. This is a transfer boundary, not the scanner's
document or PDF page limit; the exact boundary can depend on the captured image data.

The patched `scansnap-wifi` client therefore retains the sides already received, finalizes the
current command sequence, establishes a fresh registration/handshake/init sequence, and appends the
next transfer batch to a dynamically growing page collection. Each protocol transfer remains
bounded to 256 captured sides because its page number is one byte, but the complete scan no longer
has that limit. In simplex mode, backsides are released as each transfer batch arrives instead of
counting toward the final document. Transfers repeat until the iX500 reports the terminal
feeder-empty status observed on the wire:

```text
00 0a 00 00 00 00 80 03 00 00 00 00
```

Do not infer end-of-document merely because one of the final status bytes is non-zero. That former
heuristic could stop a scan at an ordinary intermediate response. An all-zero status after a sheet
also does not mean the feeder is empty. Debug logging prints the final 12 response bytes so new
firmware behavior can be compared without logging pairing credentials or document data.

## Physical Button Support

Button "arming" is a volatile client registration inside the scanner; it is not a local boolean
or a permanent configuration setting. Power loss or another client claiming the scanner can
discard that registration. The app establishes it by:

1. Registering over UDP `52217`.
2. Completing the TCP `53219` pairing handshake.
3. Running the TCP `53218` init sequence.
4. Listening for button notices on UDP `55265`.
5. Retaining the session with a VENS heartbeat to UDP `52217` every 500 ms while armed.

The scanner sends a 48-byte VENS command `0x21` startup advertisement to UDP `53220`. The app
validates the advertised scanner IP, folds repeated packets into one boot burst, marks the scanner
online, and immediately establishes a fresh button session. A 10-second TCP health check tracks
offline state. Healthy sessions are not periodically replaced by default; the heartbeat retains
them until a real lifecycle event requires a fresh arm.

The startup packet fields currently used are:

```text
offset 0..3     declared packet length: 48
offset 4..7     signature: VENS
offset 8..11    command: 0x21
offset 20..23   scanner IPv4 address
offset 24..29   scanner MAC address
```

Packets with the wrong length, signature, command, or configured scanner IP are ignored.

The final command in the normal button initialization sequence is D6. Hardware captures initially
made it look like a logout, but the scanner continues to reserve the registered client after D6.
Trying to start acquisition with another full UDP registration and TCP pairing sequence therefore
duplicates the existing ownership claim and the iX500 rejects it with status `-7`
(`pairedToDifferentClientIP`)—even when both attempts use the same IP and MAC address.

Every scan start now performs an explicit one-shot session handoff:

1. Stop the 500 ms heartbeat while acquisition owns the scanner.
2. Send D6 on TCP `53218`, consume the complete 40-byte VENS acknowledgement, half-close the client
   write side, and wait for the scanner to close its side.
3. Launch `scansnap-wifi --reuse-session`. This skips its UDP registration, first pairing handshake,
   and initialization sequence, then continues with the acquisition re-registration and scan
   commands using the same client IP and MAC.
4. After successful acquisition and source publication, resume the heartbeat for the retained
   session without registering again. Blank removal, crop, and OCR continue independently in the
   background queue.

The native client's scan cleanup also finishes its TCP command sequence with D6. D6 should
therefore be understood as command-sequence finalization, not proof that scanner-side ownership has
been cleared. An opt-in periodic safety refresh still finalizes the retained command sequence before
attempting a genuinely fresh arm, but `SCANSNAP_BUTTON_ARM_INTERVAL_SECONDS` defaults to `0` because
hardware testing showed that replacing a healthy session can itself create a temporary `-7` loop.

The native Wi-Fi client may write a failed-registration diagnostic to stdout instead of stderr.
Acquisition failures therefore retain both streams as job diagnostics; the current failure appears
in the web status and the service log rather than only as a generic exit status.

Successful scans from either the physical button or web UI resume the handed-off notification
session. They do not immediately perform a fresh arm. Failed and cancelled scans cannot safely
assume that the borrowed session remains usable, so they finalize stale protocol state and use the
recovery-arm path. Startup advertisements, scanner changes, failed health checks, and an explicitly
configured safety refresh also remain valid reasons to establish a fresh session.

A valid physical-button notice is itself positive evidence that the scanner still routes the
session to this client. If one arrives while failed-scan recovery registration is in progress, the
lifecycle cancels and drains that recovery attempt, reclaims the scanner-confirmed session, and
hands it to acquisition. Without this rule, the notice could race recovery, run as a fresh session,
and leave the button unavailable during another 40–60 second registration cycle.

Draining a cancelled recovery depends on unrelated native document tools not blocking Swift's
cooperative executor. Their pipe reads and process waits run on a dedicated blocking queue so a
long `pdfimages` or OCR operation cannot postpone this handoff or stall HTTP requests.

If scanner setup has not been completed yet, the listener waits and starts arming after setup saves a scanner. When a notice arrives from the configured scanner IP, the app starts a scan with the saved button-default mode.

Successful first-run setup does not return control to the browser until the button lifecycle has
received the new scanner configuration and completed its first arming attempt. This closes the
otherwise unarmed interval between the setup pairing test—which finalizes its temporary command
sequence—and the persistent physical-button session.

Useful log lines:

```text
ScanSnap button client armed
ScanSnap button client resumed after scan
Scanner button notice reclaimed the session during recovery
ScanSnap startup advertisement received from <scanner-ip>
Started scan from scanner button notice from <scanner-ip>
```

The expected idle traffic after `ScanSnap button client armed` is one heartbeat approximately
every 500 ms from the configured client address/UDP `55264` to the scanner on UDP `52217`.

## Security Notes

- The web UI has no authentication. Run it only on a trusted network or behind your own reverse proxy/authentication.
- If you set `SCANSNAP_PAIRING_KEY` manually, keep it out of git.
- If you use web setup, the derived pairing identity is stored in `/scans/.scannerserver-scanner.json`.
- The iX500 default password is derived from the product serial number and is only used for local pairing with the scanner.
