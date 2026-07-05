#!/usr/bin/env python3
import json
import os
import socket
import sys
import threading
import time
from datetime import datetime
from pathlib import Path


INIT_COMMANDS = [
    "0000000600000060000000000000000012000000600000000000000000000000",
    "0000000a0000000c0000000000000000e70001000000000c0000000000000000",
    "0000000a000000200000000000000000c2000000000000002000000000000000",
    "00000008000000040000000000000000e6000100000000040000000000000000",
    "00000008000000000000000400000000e6000000000400000000000000000000101e0000",
    "00000006000000080000000800000000d50000000808000000000000000000000000000000000000",
    "00000006000000000000000000000000d6000000000000000000000000000000",
]


def be32(value):
    return int(value & 0xFFFFFFFF).to_bytes(4, "big")


def configured_scanner_settings():
    scanner_ip = os.environ.get("SCANNER_IP", "")
    pairing_key = os.environ.get("SCANSNAP_PAIRING_KEY") or os.environ.get("SCAN_PAIRING_KEY", "")
    if scanner_ip and pairing_key:
        return scanner_ip, pairing_key

    config_path = Path(
        os.environ.get(
            "SCANNER_CONFIG_PATH",
            str(Path(os.environ.get("SCAN_OUTPUT_DIR", "/scans")) / ".scannerserver-scanner.json"),
        )
    )
    if not config_path.is_file():
        return scanner_ip, pairing_key

    try:
        data = json.loads(config_path.read_text())
    except Exception:
        return scanner_ip, pairing_key

    if data.get("status") == "configured":
        scanner_ip = scanner_ip or str(data.get("scanner_ip") or "")
        pairing_key = pairing_key or str(data.get("pairing_key") or "")
    return scanner_ip, pairing_key


def read_exact(sock, length):
    chunks = []
    remaining = length
    while remaining:
        data = sock.recv(remaining)
        if not data:
            raise RuntimeError("connection closed")
        chunks.append(data)
        remaining -= len(data)
    return b"".join(chunks)


def recv_vens(sock, timeout=5.0):
    sock.settimeout(timeout)
    header = read_exact(sock, 16)
    packet_len = int.from_bytes(header[:4], "big")
    if packet_len < 16 or packet_len > 1024 * 1024:
        raise RuntimeError(f"invalid VENS packet length {packet_len}")
    return header + read_exact(sock, packet_len - 16)


def connect_tcp(scanner_ip, port, client_ip=None, timeout=5.0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    if client_ip:
        sock.bind((client_ip, 0))
    sock.connect((scanner_ip, port))
    return sock


def client_ip_for_scanner(scanner_ip):
    configured_ip = os.environ.get("SCANSNAP_CLIENT_IP", "")
    if configured_ip:
        return configured_ip

    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect((scanner_ip, 1))
        return probe.getsockname()[0]
    finally:
        probe.close()


def client_mac_bytes():
    configured_mac = os.environ.get("SCANSNAP_CLIENT_MAC", "")
    if configured_mac:
        return bytes.fromhex(configured_mac.replace(":", "").replace("-", ""))

    interface = os.environ.get("SCANSNAP_CLIENT_INTERFACE", "eth0")
    mac_text = Path(f"/sys/class/net/{interface}/address").read_text().strip()
    return bytes.fromhex(mac_text.replace(":", ""))


def vens_packet(mac, command):
    packet_len = 16 + 16 + len(command)
    packet = bytearray(packet_len)
    packet[:4] = be32(packet_len)
    packet[4:8] = b"VENS"
    packet[8:12] = be32(1)
    packet[16:22] = mac
    packet[32:] = command
    return bytes(packet)


def register(scanner_ip, client_ip, mac):
    source_port = int(os.environ.get("SCANSNAP_REGISTRATION_SOURCE_PORT", "55264"))
    scanner_port = int(os.environ.get("SCANSNAP_REGISTRATION_PORT", "52217"))
    magics = [b"VENS", b"ssNR", b"V2ss"]
    flags = [0x0010, 0x0100, 0x1000]
    ip_bytes = socket.inet_aton(client_ip)

    packets = []
    for magic, flag in zip(magics, flags):
        packet = bytearray(32)
        packet[:4] = magic
        if magic == b"V2ss":
            packet[4:8] = be32(1)
        packet[8:12] = ip_bytes
        packet[12:18] = mac
        packet[22] = 0xD7
        packet[23] = 0xE0
        packet[24:26] = flag.to_bytes(2, "big")
        packets.append(bytes(packet))

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.settimeout(3.0)
    sock.bind((client_ip, source_port))
    try:
        for _ in range(4):
            for packet in packets:
                sock.sendto(packet, (scanner_ip, scanner_port))

        response, _ = sock.recvfrom(256)
        if len(response) >= 132 and response[:4] == b"VENS":
            return response[124:132]
        return b"\x00" * 8
    finally:
        sock.close()


def send_d6_release(scanner_ip, mac, client_ip):
    sock = connect_tcp(scanner_ip, 53218, client_ip=client_ip, timeout=5.0)
    try:
        read_exact(sock, 16)
        sock.sendall(vens_packet(mac, bytes.fromhex(INIT_COMMANDS[-1])))
        recv_vens(sock, timeout=3.0)
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass
    finally:
        sock.close()


def handshake(scanner_ip, client_ip, mac, pairing_key, device_tail):
    sock = connect_tcp(scanner_ip, 53219, client_ip=client_ip, timeout=5.0)
    try:
        read_exact(sock, 16)
        packet = bytearray(128)
        packet[:4] = be32(len(packet))
        packet[4:8] = b"VENS"
        packet[8:12] = be32(0x11)
        packet[16:22] = mac
        packet[33] = 0x06
        packet[34] = 0x1E
        packet[40:44] = be32(1)
        packet[44:48] = socket.inet_aton(client_ip)
        packet[50] = 0xD7
        packet[51] = 0xE1
        packet[52:68] = pairing_key.encode("ascii", errors="ignore")[:16].ljust(16, b"\x00")
        now = datetime.now()
        packet[100] = now.year >> 8
        packet[101] = now.year & 0xFF
        packet[102] = now.month
        packet[103] = now.day
        packet[104] = now.hour
        packet[105] = now.minute
        packet[106] = now.second
        packet[108:116] = device_tail[:8].ljust(8, b"\x00")
        packet[116:120] = be32(0xFFFFE3E0)

        sock.sendall(packet)
        response = sock.recv(256)
        if len(response) < 12:
            return -999
        return int.from_bytes(response[8:12], "big", signed=True)
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


def handshake_command(scanner_ip, client_ip, mac, command):
    sock = connect_tcp(scanner_ip, 53219, client_ip=client_ip, timeout=5.0)
    try:
        read_exact(sock, 16)
        packet = bytearray(32)
        packet[:4] = be32(len(packet))
        packet[4:8] = b"VENS"
        packet[8:12] = be32(command)
        packet[16:22] = mac
        sock.sendall(packet)
        sock.recv(256)
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()


def init_session(scanner_ip, client_ip, mac):
    sock = connect_tcp(scanner_ip, 53218, client_ip=client_ip, timeout=10.0)
    threads = []
    try:
        read_exact(sock, 16)
        thread = threading.Thread(target=handshake_command, args=(scanner_ip, client_ip, mac, 0x13))
        thread.start()
        threads.append(thread)

        for index, command_hex in enumerate(INIT_COMMANDS):
            sock.sendall(vens_packet(mac, bytes.fromhex(command_hex)))
            recv_vens(sock, timeout=5.0)
            if index == 0:
                thread = threading.Thread(target=handshake_command, args=(scanner_ip, client_ip, mac, 0x30))
                thread.start()
                threads.append(thread)
    finally:
        try:
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        sock.close()
        for thread in threads:
            thread.join(timeout=5.0)


def arm_button():
    scanner_ip, pairing_key = configured_scanner_settings()
    if not scanner_ip:
        raise RuntimeError("SCANNER_IP or configured scanner setup file is required")
    if not pairing_key:
        raise RuntimeError("SCANSNAP_PAIRING_KEY, SCAN_PAIRING_KEY, or configured scanner setup file is required")

    client_ip = client_ip_for_scanner(scanner_ip)
    mac = client_mac_bytes()

    device_tail = register(scanner_ip, client_ip, mac)
    error = handshake(scanner_ip, client_ip, mac, pairing_key, device_tail)
    for attempt in range(1, 9):
        if error != -4:
            break
        send_d6_release(scanner_ip, mac, client_ip)
        time.sleep(1)
        device_tail = register(scanner_ip, client_ip, mac)
        error = handshake(scanner_ip, client_ip, mac, pairing_key, device_tail)

    if error != 0:
        raise RuntimeError(f"scanner rejected button arming handshake with error {error}")

    init_session(scanner_ip, client_ip, mac)


def main():
    try:
        arm_button()
    except Exception as exc:
        print(f"ScanSnap button arm failed: {exc}", file=sys.stderr)
        return 1

    print("ScanSnap button client armed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
