"""Pin every dependency to the newest release whose SDK constraint allows the
locally installed Dart SDK.

Why this exists
---------------
Developers on different Flutter stable channels ship different Dart versions,
and a `^x.y.z` pin to a release that needs Dart 3.12 makes the project
unresolvable on a machine with 3.9 — `flutter pub get` simply fails, with an
error that reads like a version conflict rather than a toolchain mismatch.

This rewrites each pin to the newest release compatible with the local SDK and
prints what it changed, so the same codebase resolves on more machines.

The `pub.dev` API returns a package's entire version history — hundreds of
entries for popular packages — and is slow enough that fetching them one at a
time dominates the runtime, so the requests are issued concurrently.

Not part of the build. A maintenance helper:

    python3 tool/pin_dependencies.py pubspec.yaml
"""

from __future__ import annotations

import concurrent.futures
import json
import pathlib
import re
import sys
import urllib.request

# The locally installed Dart SDK's major.minor. Raise it when the toolchain is
# upgraded; the pins then move forward on the next run.
MAX_DART = (3, 9)

# Matches "  name: ^1.2.3" and nothing else, so commented-out lines and the
# `environment:` block are untouched.
PIN = re.compile(r"^  ([a-z_0-9]+):\s*\^([\d.]+)\s*$")

# The SDK constraint's first major.minor.
SDK_FLOOR = re.compile(r"[\^~><=]*\s*(\d+)\.(\d+)")


def _sort_key(tag: str) -> tuple[int, ...]:
    """Version parts as a comparable tuple. Build metadata (``2.4.2+1``) sorts
    alongside the release it patches, which is close enough for choosing a pin."""
    parts = tuple(int(p) for p in re.findall(r"\d+", tag)[:3])
    return parts or (0,)


def newest_compatible(name: str) -> str | None:
    """Highest stable release of `name` whose SDK constraint allows [MAX_DART]."""
    with urllib.request.urlopen(
        f"https://pub.dev/api/packages/{name}", timeout=120
    ) as response:
        data = json.load(response)

    for version in sorted(
        data["versions"], key=lambda v: _sort_key(v["version"]), reverse=True
    ):
        tag = version["version"]
        if "-" in tag:  # skip pre-releases
            continue
        sdk = version.get("pubspec", {}).get("environment", {}).get("sdk", "")
        match = SDK_FLOOR.search(sdk)
        if not match:
            continue
        if (int(match.group(1)), int(match.group(2))) > MAX_DART:
            continue
        return tag
    return None


def main() -> int:
    pubspec = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "pubspec.yaml")
    lines = pubspec.read_text().split("\n")

    targets: list[tuple[int, str, str]] = []
    for index, line in enumerate(lines):
        match = PIN.match(line)
        # `meta` is SDK-agnostic and left alone.
        if match and match.group(1) != "meta":
            targets.append((index, match.group(1), match.group(2)))

    if not targets:
        print("no pinned dependencies found")
        return 0

    # Fetch concurrently: the requests are network-bound and independent.
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        futures = {
            pool.submit(newest_compatible, name): (index, name, current)
            for index, name, current in targets
        }
        results: dict[str, str | None] = {}
        for future in concurrent.futures.as_completed(futures):
            index, name, current = futures[future]
            try:
                results[name] = future.result()
            except Exception as error:  # noqa: BLE001 - one bad fetch is not fatal
                print(f"ERR {name}: {error}")
                results[name] = None

    changed = 0
    for index, name, current in targets:
        version = results.get(name)
        marker = "  (unchanged)"
        if version and version != current:
            lines[index] = f"  {name}: ^{version}"
            changed += 1
            marker = ""
        print(f"{name}: ^{current} -> ^{version if version else '?'}{marker}")

    pubspec.write_text("\n".join(lines))
    print(f"\nDONE — {changed} of {len(targets)} pins adjusted")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
