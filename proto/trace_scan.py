#!/usr/bin/env python3
"""Prototype: run a scan and print every protocol record with timestamps (to debug ADF flow).
Pages are saved as trace_p<N>.jpg in the current directory.
Usage: trace_scan.py <printer-ip> [dpi]"""
import socket, struct, sys, time

if len(sys.argv) < 2:
    sys.exit(__doc__)
HOST = sys.argv[1]
RES = int(sys.argv[2]) if len(sys.argv) > 2 else 150
s = socket.create_connection((HOST, 54921), timeout=10)
print("greet", s.recv(64))
s.sendall(f"\x1bI\nR={RES},{RES}\nM=CGRAY\n\x80".encode())
info = s.recv(512)
f = info[3:].split(b",")
w, h = int(f[4]), int(f[6])
w -= w % 16
print("info", info)
s.sendall(f"\x1bX\nR={RES},{RES}\nM=CGRAY\nC=JPEG\nJ=MID\nB=50\nN=50\nA=0,0,{w},{h}\nS=NORMAL_SCAN\nP=0\nG=0\nL=128\n\x80".encode())
s.settimeout(40)
buf, t0, page = bytearray(), time.time(), 0
pages = [bytearray()]
try:
    while True:
        d = s.recv(65536)
        if not d:
            print(f"{time.time()-t0:6.1f}s EOF"); break
        buf += d
        while buf:
            t = buf[0]
            if t == 0x80:
                print(f"{time.time()-t0:6.1f}s END JOB"); buf = buf[1:]; raise StopIteration
            if t == 0x82:
                if len(buf) < 10: break
                print(f"{time.time()-t0:6.1f}s END PAGE {bytes(buf[:10]).hex(' ')}"); buf = buf[10:]
                pages.append(bytearray()); continue
            if t > 0x80:
                print(f"{time.time()-t0:6.1f}s STATUS 0x{t:02x} next={bytes(buf[:16]).hex(' ')}"); buf = buf[1:]; continue
            if len(buf) < 12: break
            ln = struct.unpack("<H", buf[10:12])[0]
            if len(buf) < 12 + ln: break
            print(f"{time.time()-t0:6.1f}s DATA {bytes(buf[:10]).hex(' ')} len={ln}")
            pages[-1] += buf[12:12+ln]; buf = buf[12+ln:]
except StopIteration:
    pass
except socket.timeout:
    print(f"{time.time()-t0:6.1f}s TIMEOUT, leftover={bytes(buf[:32]).hex(' ')}")
s.close()
for i, p in enumerate(pages):
    if p:
        open(f"trace_p{i+1}.jpg", "wb").write(p); print("saved", f"trace_p{i+1}.jpg", len(p))
