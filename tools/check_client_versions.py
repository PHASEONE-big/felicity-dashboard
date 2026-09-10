#!/usr/bin/env python3
"""Check the recorded client baselines against sources and bundled firmware."""
import hashlib
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def check():
    clients = json.loads((ROOT / "clients.json").read_text())["clients"]
    errors = []

    def expect(condition, message):
        if not condition:
            errors.append(message)

    ios = clients["ios"]
    source = (ROOT / ios["source"]).read_text()
    for key, expected in [("MARKETING_VERSION", ios["version"]),
                          ("CURRENT_PROJECT_VERSION", str(ios["build"]))]:
        values = re.findall(r"\b" + key + r"\s*=\s*([^;]+);", source)
        expect(bool(values) and all(v.strip() == expected for v in values),
               f"iOS {key} differs from clients.json")

    android = clients["android"]
    source = (ROOT / android["source"]).read_text()
    version = re.search(r"\bversionName\s+['\"]([^'\"]+)['\"]", source)
    build = re.search(r"\bversionCode\s+(\d+)", source)
    expect(version is not None and version[1] == android["version"],
           "Android versionName differs from clients.json")
    expect(build is not None and int(build[1]) == android["build"],
           "Android versionCode differs from clients.json")

    hardware = clients["esp32-nextion"]
    source = (ROOT / hardware["source"]).read_text()
    version = re.search(r'set\(PROJECT_VER\s+"([^"]+)"\)', source)
    expect(version is not None and version[1] == hardware["version"],
           "ESP32 PROJECT_VER differs from clients.json")
    for path, expected in hardware["artifacts"].items():
        expect(hashlib.sha256((ROOT / path).read_bytes()).hexdigest() == expected,
               f"Artifact changed: {path}; update the hardware baseline")
    firmware = (ROOT / "firmware/felicity-esp32.bin").read_bytes()
    # esp_app_desc_t follows the image and first segment headers (24 + 8 bytes).
    expect(firmware[32:36] == bytes.fromhex("3254cdab"),
           "ESP32 app descriptor missing")
    embedded = firmware[48:80].split(b"\0", 1)[0].decode("ascii", errors="replace")
    expect(embedded == hardware["version"], "ESP32 binary version differs from sources")
    for name in ["felicity-esp32.bin", "felicity-nextion.tft"]:
        expect((ROOT / "firmware" / name).read_bytes() ==
               (ROOT / "felicity_dashboard_addon/app/firmware" / name).read_bytes(),
               f"Home Assistant firmware copy differs: {name}")
    expect((ROOT / "firmware/felicity-nextion.tft").read_bytes() ==
           (ROOT / "nextion/felicity-dashboard.tft").read_bytes(),
           "Nextion TFT differs from distributed firmware")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    for name, client in clients.items():
        suffix = f" (build {client['build']})" if "build" in client else ""
        print(f"OK: {name} {client['version']}{suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(check())
