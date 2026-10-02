#!/usr/bin/env python3
"""Prototype: a fake eSCL scanner to verify macOS discovers a locally advertised one."""
import http.server, subprocess, uuid, sys

PORT = 8090
UUID = "6b1e3c7a-3f1d-4c2b-9a51-0b7e5ca9e001"

CAPS = f"""<?xml version="1.0" encoding="UTF-8"?>
<scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.63</pwg:Version>
  <pwg:MakeAndModel>Brother MFC-9340CDW (eSCL proto)</pwg:MakeAndModel>
  <pwg:SerialNumber>PROTO</pwg:SerialNumber>
  <scan:UUID>{UUID}</scan:UUID>
  <scan:Platen>
    <scan:PlatenInputCaps>
      <scan:MinWidth>16</scan:MinWidth><scan:MaxWidth>2550</scan:MaxWidth>
      <scan:MinHeight>16</scan:MinHeight><scan:MaxHeight>3508</scan:MaxHeight>
      <scan:MaxScanRegions>1</scan:MaxScanRegions>
      <scan:SettingProfiles><scan:SettingProfile>
        <scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode><scan:ColorMode>Grayscale8</scan:ColorMode></scan:ColorModes>
        <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat><scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt></scan:DocumentFormats>
        <scan:SupportedResolutions><scan:DiscreteResolutions>
          <scan:DiscreteResolution><scan:XResolution>100</scan:XResolution><scan:YResolution>100</scan:YResolution></scan:DiscreteResolution>
          <scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
        </scan:DiscreteResolutions></scan:SupportedResolutions>
      </scan:SettingProfile></scan:SettingProfiles>
      <scan:SupportedIntents><scan:Intent>Document</scan:Intent><scan:Intent>Photo</scan:Intent></scan:SupportedIntents>
      <scan:MaxOpticalXResolution>300</scan:MaxOpticalXResolution>
      <scan:MaxOpticalYResolution>300</scan:MaxOpticalYResolution>
    </scan:PlatenInputCaps>
  </scan:Platen>
</scan:ScannerCapabilities>
"""

STATUS = """<?xml version="1.0" encoding="UTF-8"?>
<scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
  <pwg:Version>2.63</pwg:Version><pwg:State>Idle</pwg:State>
</scan:ScannerStatus>
"""

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *a):
        print("REQ", self.command, self.path, file=sys.stderr, flush=True)
        super().log_message(fmt, *a)
    def _xml(self, body):
        b = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/xml")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
    def do_GET(self):
        if self.path.endswith("/ScannerCapabilities"): return self._xml(CAPS)
        if self.path.endswith("/ScannerStatus"): return self._xml(STATUS)
        self.send_error(404)
    def do_POST(self):
        self.send_error(503)

reg = subprocess.Popen(["dns-sd", "-R", "Brother MFC-9340CDW (eSCL)", "_uscan._tcp", "local", str(PORT),
    "txtvers=1", "vers=2.63", "rs=eSCL", "ty=Brother MFC-9340CDW", "uuid=" + UUID,
    "pdl=image/jpeg", "cs=color,grayscale", "is=platen", "duplex=F",
    "representation=/icon.png", "note="])
try:
    http.server.ThreadingHTTPServer(("", PORT), H).serve_forever()
finally:
    reg.terminate()
