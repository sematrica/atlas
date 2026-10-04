#!/usr/bin/env python3
"""Local, throttled HTTP range fixture. No external network calls."""
import http.server, json, pathlib, time
root=pathlib.Path('/tmp/AtlasStage2LiveLibrary')
record=next(json.loads(p.read_text()) for p in (root/'metadata').glob('package-*.json'))
archive=root/record['relativePath']
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        size=archive.stat().st_size
        start=int(self.headers.get('Range','bytes=0-').split('=')[1].split('-')[0])
        status=206 if 'Range' in self.headers else 200
        if self.path == '/ignore-range': start=0;status=200
        self.send_response(status)
        self.send_header('Content-Length',str(size-start))
        self.send_header('ETag','"atlas-fixture-v1"')
        if status == 206: self.send_header('Content-Range',f'bytes {start}-{size-1}/{size}')
        self.end_headers()
        try:
            with archive.open('rb') as file:
                file.seek(start)
                while data:=file.read(32768):
                    self.wfile.write(data); self.wfile.flush(); time.sleep(.025)
        except (BrokenPipeError,ConnectionResetError): pass
    def log_message(self,*args): pass
http.server.ThreadingHTTPServer(('127.0.0.1',8917),Handler).serve_forever()
