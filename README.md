# brother-escl

Makes an older Brother network scanner show up in **Preview** (File → Import from Scanner) and
**Image Capture** on macOS — no Brother drivers, no iPrint&Scan.

Brother stopped shipping macOS scanner drivers for many older multifunction printers, and these
devices predate AirScan (eSCL), the driverless protocol macOS uses for network scanners.
`brother-escl` is a small background service that speaks eSCL to macOS and Brother's native
network scan protocol to the printer:

```
Preview / Image Capture ⇄ eSCL (HTTP :8090, Bonjour _uscan._tcp) ⇄ brother-escl ⇄ TCP :54921 ⇄ printer
```

Tested with a **Brother MFC-9340CDW** on macOS 27 (Apple silicon). Other Brother models from the
same era that answer on port 54921 will likely work too — reports welcome.

## Requirements

- macOS 13 or later
- Swift toolchain (Xcode or the Command Line Tools: `xcode-select --install`)
- The printer on the network (Wi-Fi or Ethernet), reachable from the Mac

## Install

```bash
git clone https://github.com/grk/brother-escl.git
cd brother-escl
./install.sh                  # the printer is located automatically
./install.sh 192.168.1.50     # optional: the printer's address as a starting hint
```

This builds the binary into `~/.local/bin/brother-escl`, installs a per-user launchd agent
(`io.github.grk.brother-escl`) that starts at login, and logs to `~/Library/Logs/brother-escl.log`.

Then open Preview → **File → Import from Scanner → Brother MFC-9340CDW**.

To remove it (also deletes its log and saved printer address):

```bash
./install.sh --uninstall
```

## Features

- Flatbed and automatic document feeder (multi-page jobs)
- 100 / 150 / 200 / 300 / 600 dpi
- Color, grayscale and black & white
- Scan region selection, standard paper sizes (A4, Letter, …)
- Starts without the printer being on; finds it again if its IP address changes

## Locating the printer

No address is hard-coded. Before every scan the service checks that the printer is still at the
remembered address (its web page must mention the model, `MFC-9340CDW` by default). If not, it
searches in this order:

1. **Bonjour** — only works when the Mac and the printer share a subnet (mDNS doesn't cross routers)
2. **Last known address** (`~/Library/Application Support/brother-escl/last-host`) and the
   addresses of printers configured in macOS (`lpstat -v`)
3. **Sweep of those addresses' /24 subnets** — port 80 plus a check of the web page, ~2–5 s

So a DHCP address change within the subnet is handled automatically. If the printer moves to an
entirely different subnet that macOS doesn't know about either, run `./install.sh <new-ip>` once.

`brother-escl --discover` prints the address it finds. Use `--match <text>` to identify a different
model, and `--name <text>` to change the name shown in Preview.

## Limitations

- **The feeder wins.** The printer picks the ADF by itself whenever paper is loaded in it, even if
  the flatbed is selected in Preview.
- **Flatbed length is 291 mm.** The scan head doesn't travel the full A4 length (297 mm). The service
  still offers A4 and Letter (macOS hides paper sizes larger than the advertised area) and pads the
  last few millimetres with white. Pages from the feeder are scanned at full length.
- **Grayscale and black & white are produced on the Mac** from a color scan, so they're no faster.
- **Visible to the local network.** Like a real AirScan scanner, the service is advertised on all
  interfaces, so other Macs on the network can scan through it while your Mac is on. Requests are
  size-limited, connections are capped and time out, and the printer is only ever looked for on
  private (RFC 1918) addresses.
- **Canceling doesn't stop the device.** A canceled scan finishes on the printer and is discarded;
  aborting the transfer midway can leave the scanner's session stuck.
- **Each scan starts after ~4–5 s** — the time the scanner itself takes to answer the first request.

## Troubleshooting

```bash
tail -f ~/Library/Logs/brother-escl.log      # what the service is doing
~/.local/bin/brother-escl --discover          # can it find the printer?
dns-sd -B _uscan._tcp                         # is the scanner advertised to macOS?
```

## Brother scan protocol notes (port 54921)

Reverse-engineered from an MFC-9340CDW; documented here because it isn't documented anywhere else.

- On connect the printer sends `+OK 200\r\n`.
- **Query:** `ESC "I\nR=300,300\nM=CGRAY\n" 0x80` → `0x00 <len u16 LE> "300,300,2,209,2480,291,3437," 0x00`
  — x/y resolution, source (`2` flatbed, `1` ADF), width mm/px, height mm/px.
- **Scan:** `ESC "X\nR=…\nM=CGRAY\nC=JPEG\nJ=MID\nB=50\nN=50\nA=x1,y1,x2,y2\nS=NORMAL_SCAN\nP=0\nG=0\nL=128\n" 0x80`
  — `A=` is a pixel rectangle at the scan resolution.
- **Reply:** a stream of records until `0x80` (end of job):
  - data: `type, 07 00, page u16 LE, 84, lines u32 LE, len u16 LE, <len bytes of JPEG>`;
    `lines` counts the rows delivered so far
  - `0x82` + 9 bytes: end of page
- Only the first `floor(width / 16) * 16` columns of every line are image data; the rest is garbage.
  The service therefore always requests widths that are multiples of 16.
- With paper in the ADF the query reports source `1` and height `0` (e.g. `150,150,1,209,1240,0,0`).
  The scan must then be requested with `y2 = 0` ("until the end of the sheet"); anything else hangs
  the session. Each page's JPEG header then declares a placeholder height of 11000 rows — the real
  height comes from the `lines` counter.
- After many short connections in a row the printer refuses port 54921 for a few seconds, so the
  service identifies the printer via its web page instead and retries scan connections.

## Development

```bash
swift build -c release
.build/release/brother-escl --host 192.168.1.50   # run in the foreground
```

| Path | |
|---|---|
| `Sources/brother-escl/BrotherScanner.swift` | Brother protocol client |
| `Sources/brother-escl/ESCLServer.swift` | eSCL endpoints and scan jobs |
| `Sources/brother-escl/HTTPServer.swift` | minimal HTTP/1.1 server with Bonjour advertising |
| `Sources/brother-escl/PrinterLocator.swift` | printer discovery |
| `Sources/brother-escl/Imaging.swift` | color mode conversion, cropping and padding |
| `proto/raw_scan.py`, `proto/trace_scan.py` | raw scans and record-by-record protocol traces |
| `proto/ic_scan.swift` | end-to-end test through ImageCaptureCore (the framework Preview uses) |
| `proto/list_scanners.swift` | lists the scanners macOS can see |
| `proto/fake_escl.py` | stub eSCL scanner, for testing macOS discovery |
| `proto/testpage.swift` → `testpage.pdf` | A4 test page: rulers, colors, gray ramp, text, line pairs |

The `proto/` tools are standalone scripts from the reverse-engineering work and aren't part of the
build: run them with `python3 proto/<name>.py` or `swift proto/<name>.swift` — the comment at the top of
each file says what it does and how to call it.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with Brother Industries.
