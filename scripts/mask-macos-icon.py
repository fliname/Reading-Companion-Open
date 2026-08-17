#!/usr/bin/env python3
"""Apply an antialiased macOS-style rounded mask to an icon image."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--size", type=int, default=1024)
    parser.add_argument("--inset", type=int, default=12)
    parser.add_argument("--radius", type=int, default=190)
    parser.add_argument(
        "--content-size",
        type=int,
        default=None,
        help="Visible icon size inside the transparent output canvas.",
    )
    args = parser.parse_args()

    with Image.open(args.source) as opened:
        source = opened.convert("RGBA")
    crop_size = min(source.size)
    left = (source.width - crop_size) // 2
    top = (source.height - crop_size) // 2
    source = source.crop((left, top, left + crop_size, top + crop_size))
    source = source.resize((args.size, args.size), Image.Resampling.LANCZOS)

    scale = 4
    high_size = args.size * scale
    mask = Image.new("L", (high_size, high_size), 0)
    draw = ImageDraw.Draw(mask)
    inset = args.inset * scale
    draw.rounded_rectangle(
        (inset, inset, high_size - inset - 1, high_size - inset - 1),
        radius=args.radius * scale,
        fill=255,
    )
    mask = mask.resize((args.size, args.size), Image.Resampling.LANCZOS)
    source.putalpha(ImageChops.multiply(source.getchannel("A"), mask))

    content_size = args.content_size or args.size
    if not 1 <= content_size <= args.size:
        raise SystemExit("--content-size must be between 1 and --size.")
    if content_size != args.size:
        source = source.resize((content_size, content_size), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (args.size, args.size), (0, 0, 0, 0))
        offset = (args.size - content_size) // 2
        canvas.alpha_composite(source, (offset, offset))
        source = canvas

    args.output.parent.mkdir(parents=True, exist_ok=True)
    source.save(args.output, "PNG")


if __name__ == "__main__":
    main()
