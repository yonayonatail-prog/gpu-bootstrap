#!/usr/bin/env python3
"""
Watch RunPod Community Cloud GPU availability from a local machine.

No third-party dependencies are required.
Set RUNPOD_API_KEY in the environment before running.

Repeat --gpu to watch multiple GPU types with a single API request, for example:
  python watch_runpod.py --gpu "RTX 3090" --gpu "RTX 4090"
  python watch_runpod.py --gpu "RTX 4090" --gpu "RTX 5090" --open-browser
Comma-separated values are also accepted.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser
from datetime import datetime
from typing import Any

API_URL = "https://api.runpod.io/graphql"
RUNPOD_CONSOLE_URL = "https://www.runpod.io/console/gpu-cloud"

QUERY = """
query WatchGpu($priceInput: GpuLowestPriceInput) {
  gpuTypes {
    id
    displayName
    communityCloud
    communityPrice
    lowestPrice(input: $priceInput) {
      uninterruptablePrice
      stockStatus
      maxUnreservedGpuCount
      availableGpuCounts
      countryCode
      minMemory
      minVcpu
    }
  }
}
"""


def now() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %z")


def log(message: str) -> None:
    print(f"[{now()}] {message}", flush=True)


def graphql(api_key: str, timeout: float) -> list[dict[str, Any]]:
    body = json.dumps(
        {
            "query": QUERY,
            "variables": {
                "priceInput": {
                    "gpuCount": 1,
                    "secureCloud": False,
                }
            },
        }
    ).encode("utf-8")

    request = urllib.request.Request(
        API_URL,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
            "User-Agent": "gpu-bootstrap-runpod-watcher/1.0",
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")[:500]
        raise RuntimeError(f"RunPod API HTTP {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"RunPod API connection failed: {exc.reason}") from exc

    if payload.get("errors"):
        raise RuntimeError(f"RunPod GraphQL error: {payload['errors']}")

    gpu_types = payload.get("data", {}).get("gpuTypes")
    if not isinstance(gpu_types, list):
        raise RuntimeError("RunPod API returned no gpuTypes list.")
    return gpu_types


def find_gpu(gpu_types: list[dict[str, Any]], needle: str) -> dict[str, Any] | None:
    target = needle.casefold()
    candidates = [
        gpu
        for gpu in gpu_types
        if target in str(gpu.get("displayName", "")).casefold()
        and gpu.get("communityCloud") is True
    ]
    if not candidates:
        return None

    return sorted(candidates, key=lambda item: len(str(item.get("displayName", ""))))[0]


def availability(gpu: dict[str, Any]) -> tuple[bool, str]:
    lowest = gpu.get("lowestPrice")
    if not isinstance(lowest, dict):
        return False, "no Community offer"

    unreserved = lowest.get("maxUnreservedGpuCount")
    counts = lowest.get("availableGpuCounts") or []
    available = (
        isinstance(unreserved, int)
        and unreserved >= 1
    ) or (
        isinstance(counts, list)
        and any(isinstance(count, int) and count >= 1 for count in counts)
    )

    price = lowest.get("uninterruptablePrice")
    if price is None:
        price = gpu.get("communityPrice")

    pieces = [
        f"stock={lowest.get('stockStatus') or 'unknown'}",
        f"unreserved={unreserved if unreserved is not None else 'unknown'}",
        f"gpu_counts={counts or 'none'}",
    ]
    if isinstance(price, (int, float)):
        pieces.append(f"price=${price:.3f}/h")
    if lowest.get("countryCode"):
        pieces.append(f"country={lowest['countryCode']}")

    return available, " ".join(pieces)


def windows_toast(title: str, message: str) -> bool:
    if platform.system() != "Windows":
        return False

    title_json = json.dumps(title)
    message_json = json.dumps(message)
    script = f"""
$title = ConvertFrom-Json '{title_json.replace("'", "''")}'
$message = ConvertFrom-Json '{message_json.replace("'", "''")}'
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] > $null
[Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime] > $null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime] > $null
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text></text><text></text></binding></visual></toast>')
$text = $xml.GetElementsByTagName('text')
$text.Item(0).AppendChild($xml.CreateTextNode($title)) > $null
$text.Item(1).AppendChild($xml.CreateTextNode($message)) > $null
$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('GPU Bootstrap').Show($toast)
"""
    try:
        completed = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
            check=False,
        )
        return completed.returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def fallback_alert() -> None:
    if platform.system() == "Windows":
        try:
            import winsound

            winsound.MessageBeep(winsound.MB_ICONEXCLAMATION)
            return
        except Exception:
            pass

    print("\a", end="", flush=True)


def notify(gpu_name: str, detail: str, open_browser: bool) -> None:
    title = "RunPod Community GPU available"
    message = f"{gpu_name}: {detail}"
    log(f"AVAILABLE: {message}")

    # Always make an audible alert attempt. The toast is supplemental and may
    # be silent depending on the user's Windows notification settings.
    fallback_alert()
    windows_toast(title, message)

    if open_browser:
        try:
            webbrowser.open(RUNPOD_CONSOLE_URL, new=2)
        except Exception as exc:
            log(f"WARN: could not open browser: {exc}")


def max_one(value: str) -> int:
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be >= 1")
    return number


def normalize_gpu_args(values: list[str] | None) -> list[str]:
    if not values:
        return ["RTX 4090"]

    result: list[str] = []
    seen: set[str] = set()
    for value in values:
        for part in value.split(","):
            gpu = part.strip()
            if not gpu:
                continue
            key = gpu.casefold()
            if key not in seen:
                seen.add(key)
                result.append(gpu)

    if not result:
        raise ValueError("At least one non-empty --gpu value is required.")
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Watch RunPod Community Cloud GPU availability."
    )
    parser.add_argument(
        "--gpu",
        action="append",
        dest="gpus",
        help=(
            'GPU display-name substring to watch. Repeat --gpu for multiple GPUs '
            'or use comma-separated values. Default: "RTX 4090".'
        ),
    )
    parser.add_argument(
        "--interval",
        type=max_one,
        default=60,
        help="Polling interval in seconds (default: 60).",
    )
    parser.add_argument(
        "--timeout",
        type=max_one,
        default=20,
        help="RunPod API request timeout in seconds (default: 20).",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Check once and exit. Success means at least one watched GPU is available.",
    )
    parser.add_argument(
        "--open-browser",
        action="store_true",
        help="Open the RunPod GPU Cloud console when a watched GPU becomes available.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    api_key = os.getenv("RUNPOD_API_KEY", "").strip()
    if not api_key:
        print(
            "ERROR: RUNPOD_API_KEY is not set. "
            "Set it in the local environment; never commit it to Git.",
            file=sys.stderr,
        )
        return 2

    try:
        targets = normalize_gpu_args(args.gpus)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    log(
        f"watch start gpus={targets!r} cloud=COMMUNITY "
        f"interval={args.interval}s"
    )

    previous: dict[str, tuple[bool | None, str | None]] = {
        target: (None, None) for target in targets
    }
    consecutive_errors = 0

    while True:
        try:
            # One GraphQL request returns all GPU types; evaluate every watched
            # target against the same snapshot instead of polling once per GPU.
            gpu_types = graphql(api_key, timeout=args.timeout)
            any_available = False
            browser_opened = False

            for target in targets:
                gpu = find_gpu(gpu_types, target)
                if gpu is None:
                    available = False
                    detail = f"no Community GPU type matched {target!r}"
                    name = target
                else:
                    available, detail = availability(gpu)
                    name = str(gpu.get("displayName") or target)

                previous_available, previous_detail = previous[target]
                if available != previous_available or detail != previous_detail:
                    state = "AVAILABLE" if available else "UNAVAILABLE"
                    log(f"{state}: {name} {detail}")

                if available and previous_available is not True:
                    should_open = args.open_browser and not browser_opened
                    notify(name, detail, open_browser=should_open)
                    browser_opened = browser_opened or should_open

                previous[target] = (available, detail)
                any_available = any_available or available

            consecutive_errors = 0

            if args.once:
                return 0 if any_available else 1

            time.sleep(args.interval)

        except KeyboardInterrupt:
            log("watch stopped by user")
            return 130
        except Exception as exc:
            consecutive_errors += 1
            delay = min(args.interval * (2 ** min(consecutive_errors - 1, 4)), 600)
            log(f"ERROR: {exc}; retry_in={delay}s")
            if args.once:
                return 3
            time.sleep(delay)


if __name__ == "__main__":
    raise SystemExit(main())
