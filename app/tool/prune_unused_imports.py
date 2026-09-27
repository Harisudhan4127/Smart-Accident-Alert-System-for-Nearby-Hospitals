"""Remove the imports `flutter analyze` reports as unused.

`dart fix --apply` does this, but it needs a clean package config and will also
apply unrelated quick-fixes. This does the one thing, deterministically, and
re-analyses until it converges so a removal that reveals another unused import
is caught too.

    python3 tool/prune_unused_imports.py
"""

from __future__ import annotations

import re
import subprocess
import sys

ANALYZE = ["flutter", "analyze", "--no-fatal-infos"]
UNUSED = re.compile(r"^\s*(?:error|warning)\s+•\s+Unused import:\s+'([^']+)'")
LOCATION = re.compile(r"•\s+(\S+\.dart):(\d+):(\d+)")


def analyze() -> list[tuple[str, int, str]]:
    """(file, line, import-path) for every unused import reported."""
    result = subprocess.run(
        ANALYZE, capture_output=True, text=True, check=False
    )
    found: list[tuple[str, int, str]] = []
    for line in result.stdout.splitlines():
        match = UNUSED.search(line)
        if not match:
            continue
        where = LOCATION.search(line)
        if not where:
            continue
        found.append((where.group(1), int(where.group(2)), match.group(1)))
    return found


def main() -> int:
    total_removed = 0
    # Each pass can expose another unused import, so iterate to a fixed point.
    for _ in range(10):
        issues = analyze()
        if not issues:
            break

        # Group by file so each file is rewritten once.
        by_file: dict[str, list[tuple[int, str]]] = {}
        for path, line, target in issues:
            by_file.setdefault(path, []).append((line, target))

        for path, entries in by_file.items():
            with open(path, encoding="utf-8") as handle:
                lines = handle.readlines()
            # Delete from the bottom so earlier indices stay valid.
            for line_no, target in sorted(entries, reverse=True):
                index = line_no - 1
                if 0 <= index < len(lines) and target in lines[index]:
                    del lines[index]
            with open(path, "w", encoding="utf-8") as handle:
                handle.writelines(lines)
            total_removed += len(entries)

    print(f"removed {total_removed} unused imports")
    remaining = analyze()
    if remaining:
        print(f"WARNING: {len(remaining)} still reported")
        for path, line, target in remaining[:10]:
            print(f"  {path}:{line} {target}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
