#!/usr/bin/env python3
"""Build a modern macOS ICNS file from a square 1024px PNG source."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    with Image.open(args.source) as opened:
        source = opened.convert("RGBA")
    if source.width != source.height or source.width < 1024:
        raise SystemExit("The source icon must be square and at least 1024×1024 pixels.")

    sizes = (32, 64, 128, 256, 512, 1024)
    rendered = [
        source.resize((size, size), Image.Resampling.LANCZOS)
        for size in sizes
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    rendered[-1].save(args.output, format="ICNS", append_images=rendered)


if __name__ == "__main__":
    main()
