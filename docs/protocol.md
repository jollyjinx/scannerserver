# ScanSnap Protocol Notes

## Why This Uses The ScanSnap Wi-Fi Protocol

The iX500 does not behave like a normal eSCL/AirScan scanner in this setup. This project uses the reverse-engineered ScanSnap Wi-Fi protocol implemented by [`bramheerink/scansnap`](https://github.com/bramheerink/scansnap), built into the image as `scansnap-wifi`.

Important ports:

| Port | Purpose |
| --- | --- |
| UDP `52217` | ScanSnap discovery/registration |
| TCP `53219` | Pairing/control handshake |
| TCP `53218` | Scan control/data |
| UDP `55265` | Button notice listener in this app |

## First-Run Discovery

The iX500 exposes a 132-byte VENS UDP device-info response before TCP pairing. That response is unauthenticated and includes:

```text
offset 28..33    scanner MAC address
offset 40..103   scanner serial number
offset 104..119  display name
```

The web setup flow:

1. Sends VENS discovery/registration packets to LAN broadcast addresses and ARP neighbors with known ScanSnap/Silex MAC prefixes.
2. Lists discovered ScanSnap devices.
3. Lets the user choose one, or enter an IP address manually.
4. Derives the default pairing identity from the discovered serial number.
5. Tests the pairing identity against TCP `53219`.
6. Saves the working scanner IP and pairing identity in `/scans/.scannerserver-scanner.json`.

Discovery intentionally does not sweep every IP address in the subnet.

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
python3 - <<'PY'
serial = "AWRHC08122"
password = serial.rstrip()[-4:]
key = "pFusCANsNapFiPfu"
print("".join(str(ord(char) + ord(key[index]) + 11) for index, char in enumerate(password)))
PY
```

If the scanner password was changed in ScanSnap Wireless Setup Tool, use that password instead of the serial suffix. If you do not know the changed password, reset/reconfigure the scanner wireless settings or capture the key from an already configured official ScanSnap client.

The Ethernet/MAC address is not part of this calculation. This derivation is also documented by [`mzyy94/AirScap`](https://github.com/mzyy94/AirScap/blob/master/protocol.en.md).

## Physical Button Support

The app periodically arms itself with the scanner by:

1. Registering over UDP `52217`.
2. Completing the TCP `53219` pairing handshake.
3. Running the TCP `53218` init sequence.
4. Listening for button notices on UDP `55265`.

If scanner setup has not been completed yet, the listener waits and starts arming after setup saves a scanner. When a notice arrives from the configured scanner IP, the app starts a scan with the saved button-default mode.

Useful log lines:

```text
ScanSnap button client armed
Started scan from scanner button notice from <scanner-ip>
```

## Security Notes

- The web UI has no authentication. Run it only on a trusted network or behind your own reverse proxy/authentication.
- If you set `SCANSNAP_PAIRING_KEY` manually, keep it out of git.
- If you use web setup, the derived pairing identity is stored in `/scans/.scannerserver-scanner.json`.
- The iX500 default password is derived from the product serial number and is only used for local pairing with the scanner.
