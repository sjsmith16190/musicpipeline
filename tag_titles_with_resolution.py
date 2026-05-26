#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from musicpipeline.title_resolution import apply_resolution_titles, ensure_title_resolution_tools


def main() -> int:
    args = parse_args()
    missing = ensure_title_resolution_tools()
    if missing:
        print(f"Missing required tool(s): {', '.join(missing)}", file=sys.stderr)
        return 2
    summary = apply_resolution_titles(args.root.resolve(), dry_run=args.dry_run)
    return 0 if summary.failed == 0 else 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Recursively append [bit-sample] to audio title tags, like 'My Baby [24-192]'."
    )
    parser.add_argument(
        "root",
        nargs="?",
        default=".",
        type=Path,
        help="Directory to scan recursively. Defaults to the current directory.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would change without writing tags.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    raise SystemExit(main())
