#!/usr/bin/env python3
"""Reconnect the locally configured tablet by its advertised ADB serial."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

CONFIG = Path(__file__).resolve().parents[1] / "local-device.json"


def main():
    if not CONFIG.is_file():
        sys.exit("Configure android/local-device.json as described in android/DEVICE_ACCESS.md")
    config = json.loads(CONFIG.read_text())
    serial = config.get("serial", "").strip()
    if not serial:
        sys.exit("local-device.json must identify the tablet's serial")
    sdk = Path(os.environ.get("ANDROID_HOME", Path.home() / "Library/Android/sdk"))
    adb = shutil.which("adb") or str(sdk / "platform-tools/adb")

    def run(*args):
        result = subprocess.run([adb, *args], capture_output=True, text=True, timeout=12)
        if result.returncode:
            raise RuntimeError((result.stderr or result.stdout).strip())
        return result.stdout.strip()

    candidates = []
    try:
        for line in run("mdns", "services").splitlines():
            fields = line.split()
            if len(fields) == 3 and fields[0] == "adb-" + serial and fields[1] == "_adb._tcp.":
                candidates.append(fields[2])
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"mDNS unavailable: {error}", file=sys.stderr)
    if config.get("last_endpoint"):
        candidates.append(config["last_endpoint"])
    for endpoint in dict.fromkeys(candidates):
        try:
            run("connect", endpoint)
            actual = run("-s", endpoint, "shell", "getprop", "ro.serialno")
            if actual != serial:
                print(f"Skipping {endpoint}: different device", file=sys.stderr)
                run("disconnect", endpoint)
                continue
            model = run("-s", endpoint, "shell", "getprop", "ro.product.model")
            config["last_endpoint"] = endpoint
            CONFIG.write_text(json.dumps(config, indent=2) + "\n")
            print(f"Connected: {model} at {endpoint}")
            print(f"adb -s {endpoint} ...")
            return
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            print(f"{endpoint}: {error}", file=sys.stderr)
    sys.exit("Tablet not connected. Check Wi-Fi and ADB debugging; see android/DEVICE_ACCESS.md")


if __name__ == "__main__":
    main()
