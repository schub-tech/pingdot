#!/usr/bin/env python3
"""Does this network answer ICMP echo requests with identifier 0?

PingDot < 2026-09-13 sent every echo request with identifier 0. Home routers
(Linux conntrack) forward that fine, but some NATs — iPhone Personal Hotspot,
carrier NAT64 — treat the identifier like a port and drop id 0. Symptom: PingDot
shows 100 % loss while `ping` (which uses its PID as identifier) works.

Run on the affected network, no root needed:

    python3 Scripts/icmp-id-test.py [host]

Expected on a healthy network: replies for every identifier. If only id 0 times
out, the NAT is the culprit and the non-zero identifier fix is what you need.
"""
import os
import socket
import struct
import sys
import time


def checksum(b: bytes) -> int:
    s = 0
    for i in range(0, len(b) - 1, 2):
        s += (b[i] << 8) | b[i + 1]
    if len(b) % 2:
        s += b[-1] << 8
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def probe(ident: int, target: str, n: int = 3) -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_ICMP)
    s.settimeout(2.0)
    ok = 0
    for seq in range(1, n + 1):
        pkt = struct.pack("!BBHHH", 8, 0, 0, ident, seq) + bytes(range(32))
        pkt = pkt[:2] + struct.pack("!H", checksum(pkt)) + pkt[4:]
        t0 = time.time()
        s.sendto(pkt, (target, 0))
        try:
            while True:
                data, _ = s.recvfrom(2048)
                off = (data[0] & 0x0F) * 4 if data[0] >> 4 == 4 else 0
                typ, _, _, rid, rseq = struct.unpack("!BBHHH", data[off:off + 8])
                if typ == 0 and rid == ident and rseq == seq:
                    ok += 1
                    print(f"  id={ident:<5} seq={seq}  reply  {(time.time() - t0) * 1000:6.1f} ms")
                    break
        except socket.timeout:
            print(f"  id={ident:<5} seq={seq}  TIMEOUT")
    s.close()
    return ok


def main() -> int:
    target = sys.argv[1] if len(sys.argv) > 1 else "8.8.8.8"
    print(f"ICMP identifier test → {target}\n")
    results = {}
    for ident in (0, 1, os.getpid() & 0xFFFF or 1):
        results[ident] = probe(ident, target)
    print("\nSummary:")
    for ident, ok in results.items():
        print(f"  identifier {ident:<5} {ok}/3 replies")
    return 0 if any(results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
