#!/usr/bin/env python3
"""Prototype: run one scan over Brother's native protocol (TCP 54921) and dump the raw stream.
Usage: raw_scan.py <printer-ip> [dpi] [mode] [compression] [out]"""
import socket, sys, time

if len(sys.argv) < 2:
    sys.exit(__doc__)
HOST = sys.argv[1]
RES = int(sys.argv[2]) if len(sys.argv) > 2 else 100
MODE = sys.argv[3] if len(sys.argv) > 3 else "CGRAY"
COMP = sys.argv[4] if len(sys.argv) > 4 else "JPEG"
OUT = sys.argv[5] if len(sys.argv) > 5 else "raw.bin"

s = socket.create_connection((HOST, 54921), timeout=60)
print("greet", s.recv(64))
s.sendall(f"\x1bI\nR={RES},{RES}\nM={MODE}\n\x80".encode("latin1"))
info = s.recv(512)
print("info", info)
f = info[3:].split(b",")
xr, yr, w_px, h_px = int(f[0]), int(f[1]), int(f[4]), int(f[6])
cmd = (f"\x1bX\nR={xr},{yr}\nM={MODE}\nC={COMP}\nJ=MID\nB=50\nN=50\n"
       f"A=0,0,{w_px},{h_px}\nS=NORMAL_SCAN\nP=0\nG=0\nL=128\n\x80")
s.sendall(cmd.encode("latin1"))
buf = bytearray()
s.settimeout(15)
t0 = time.time()
try:
    while True:
        d = s.recv(65536)
        if not d:
            break
        buf += d
except socket.timeout:
    print("timeout (no data for 15s)")
s.close()
open(OUT, "wb").write(buf)
print(f"got {len(buf)} bytes in {time.time()-t0:.1f}s -> {OUT}")
print("head", buf[:64].hex(" "))
print("tail", buf[-32:].hex(" "))
