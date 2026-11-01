"""Select an available iPhone simulator compatible with the app deployment target."""

import json
import re
import sys


MINIMUM_IOS_MAJOR = 18
IOS_RUNTIME = re.compile(r"(?:^|\.)iOS-(\d+)(?:-(\d+))?(?:$|\.)")


def choose_device(payload, minimum_major=MINIMUM_IOS_MAJOR):
    devices_by_runtime = payload.get("devices")
    if not isinstance(devices_by_runtime, dict):
        raise ValueError("simctl JSON has no devices object")
    candidates = []
    for runtime, devices in devices_by_runtime.items():
        match = IOS_RUNTIME.search(runtime)
        if match is None or not isinstance(devices, list):
            continue
        version = (int(match.group(1)), int(match.group(2) or 0))
        if version[0] < minimum_major:
            continue
        for device in devices:
            if (not isinstance(device, dict)
                    or device.get("isAvailable") is False
                    or not str(device.get("name", "")).startswith("iPhone")
                    or not isinstance(device.get("udid"), str)
                    or not device["udid"]):
                continue
            candidates.append((version, runtime, device))
    if not candidates:
        raise ValueError(f"no available iPhone simulator with iOS {minimum_major}+")
    newest = max(version for version, _, _ in candidates)
    return next((runtime, device) for version, runtime, device in candidates
                if version == newest)


def main():
    try:
        runtime, device = choose_device(json.load(sys.stdin))
    except (ValueError, json.JSONDecodeError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"Selected {device['name']} on {runtime}", file=sys.stderr)
    print(device["udid"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
