#!/usr/bin/env python3
"""Tiny LAN-only APK server for Android WebViews without a download listener."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


APK = Path(__file__).parents[1] / "app" / "build" / "outputs" / "apk" / "debug" / "app-debug.apk"


class Handler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        if self.path.split("?", 1)[0] in {"/download", "/felicity.apk"}:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="felicity-android.apk"')
            self.send_header("Content-Length", str(APK.stat().st_size))
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()

    def do_GET(self):
        if self.path.split("?", 1)[0] in {"/download", "/felicity.apk"}:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Disposition", 'attachment; filename="felicity-android.apk"')
            self.send_header("Content-Length", str(APK.stat().st_size))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            with APK.open("rb") as source:
                while chunk := source.read(256 * 1024):
                    self.wfile.write(chunk)
            return

        body = b"""<!doctype html><meta name=viewport content='width=device-width'>
<title>Felicity installer</title>
<style>body{font:24px sans-serif;background:#081b18;color:#fff;padding:48px}a{display:inline-block;padding:24px 36px;border-radius:16px;background:#00cdb8;color:#001b17;text-decoration:none;font-weight:bold}</style>
<h1>Felicity Dashboard</h1><p>Dragon Touch bootstrap installer</p>
<a href='/download'>DOWNLOAD APK</a>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8765), Handler).serve_forever()
