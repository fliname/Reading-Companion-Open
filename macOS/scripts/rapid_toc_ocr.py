#!/usr/bin/env python3
"""Offline RapidOCR/PaddleOCR-family recognition for selected TOC pages.

The Swift app supplies a temporary PDF containing only directory pages. This
helper preserves one OCR block per line, reconstructs multi-column order from
coordinates, and writes a tiny JSON payload for EnhancedTOCService.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import pypdfium2 as pdfium
from rapidocr import RapidOCR


PAGE_AT_END = re.compile(
    r"(?:[/／]|\.{1,}|…+|·{2,}|\s)\s*[\(（\[【{]?\s*(\d{1,4})\s*[\)）\]】}]?\s*$"
)
STANDALONE_NUMBER = re.compile(r"^(?:\d+(?:\.\d+)*|[ivxlcdm]+)$", re.I)
DETACHED_CHAPTER = re.compile(r"^(?:chapter\s+[0-9ivxlcdm]+|第\s*[0-9一二三四五六七八九十百千零〇两]+\s*章)$", re.I)


def rect(box):
    xs = [float(point[0]) for point in box]
    ys = [float(point[1]) for point in box]
    return min(xs), min(ys), max(xs), max(ys)


def top_down(lines):
    return sorted(lines, key=lambda item: (item["rect"][1], item["rect"][0]))


def merge_row_fragments(lines, page_width):
    rows = []
    for item in top_down(lines):
        height = max(item["rect"][3] - item["rect"][1], 1.0)
        matching = None
        for row in rows:
            top = max(row["top"], item["rect"][1])
            bottom = min(row["bottom"], item["rect"][3])
            overlap = max(bottom - top, 0.0) / max(min(row["height"], height), 1.0)
            if overlap >= 0.52:
                matching = row
                break
        if matching is None:
            rows.append(
                {
                    "top": item["rect"][1],
                    "bottom": item["rect"][3],
                    "height": height,
                    "items": [item],
                }
            )
        else:
            matching["top"] = min(matching["top"], item["rect"][1])
            matching["bottom"] = max(matching["bottom"], item["rect"][3])
            matching["height"] = max(matching["height"], height)
            matching["items"].append(item)

    merged = []
    for row in rows:
        ordered = sorted(row["items"], key=lambda item: item["rect"][0])
        current = None
        for item in ordered:
            if current is None:
                current = dict(item)
                continue
            gap = item["rect"][0] - current["rect"][2]
            current_complete = PAGE_AT_END.search(current["text"]) is not None and not STANDALONE_NUMBER.fullmatch(current["text"])
            next_is_number = STANDALONE_NUMBER.fullmatch(item["text"]) is not None
            close_enough = gap <= page_width * 0.22
            if close_enough and not (current_complete and not next_is_number):
                current["text"] = f'{current["text"]} {item["text"]}'
                current["rect"] = (
                    min(current["rect"][0], item["rect"][0]),
                    min(current["rect"][1], item["rect"][1]),
                    max(current["rect"][2], item["rect"][2]),
                    max(current["rect"][3], item["rect"][3]),
                )
                current["confidence"] = max(current["confidence"], item["confidence"])
            else:
                merged.append(current)
                current = dict(item)
        if current is not None:
            merged.append(current)
    return merged


def column_order(lines, page_width):
    ordinary = [
        item
        for item in lines
        if (item["rect"][2] - item["rect"][0]) < page_width * 0.72
        and (item["rect"][3] - item["rect"][1]) < (item["rect"][2] - item["rect"][0]) * 1.45
    ]
    if len(ordinary) < 4:
        return None
    centers = sorted((item["rect"][0] + item["rect"][2]) / 2 for item in ordinary)
    gaps = [(centers[index + 1] - centers[index], index) for index in range(len(centers) - 1)]
    gap, split_index = max(gaps, default=(0, 0))
    if gap < page_width * 0.10 or split_index + 1 < 2 or len(centers) - split_index - 1 < 2:
        return None
    split_x = (centers[split_index] + centers[split_index + 1]) / 2
    spanning = [
        item
        for item in lines
        if item not in ordinary
        or (item["rect"][0] < split_x < item["rect"][2])
    ]
    column_body = [item for item in ordinary if item not in spanning]
    left = [item for item in column_body if (item["rect"][0] + item["rect"][2]) / 2 < split_x]
    right = [item for item in column_body if item not in left]
    return top_down(spanning) + top_down(left) + top_down(right)


def vertical_order(lines):
    vertical = [
        item
        for item in lines
        if (item["rect"][3] - item["rect"][1]) > (item["rect"][2] - item["rect"][0]) * 1.35
    ]
    if len(vertical) < max(3, len(lines) // 3):
        return None
    horizontal = [item for item in lines if item not in vertical]
    vertical = sorted(
        vertical,
        key=lambda item: (-(item["rect"][0] + item["rect"][2]) / 2, item["rect"][1]),
    )
    return top_down(horizontal) + vertical


def toc_score(lines):
    pages = []
    for item in lines:
        match = PAGE_AT_END.search(item["text"])
        if match:
            pages.append(int(match.group(1)))
    if not pages:
        return 0.0
    monotonic = sum(current >= previous for previous, current in zip(pages, pages[1:]))
    ratio = monotonic / max(len(pages) - 1, 1)
    return len(pages) * 5 + ratio * 10


def reading_order(lines, width):
    candidates = [top_down(lines)]
    columns = column_order(lines, width)
    if columns:
        candidates.append(columns)
    vertical = vertical_order(lines)
    if vertical:
        candidates.append(vertical)
    return max(candidates, key=toc_score)


def attach_detached_chapter_labels(lines):
    """Rejoin chapter labels printed beside, but detected below, a TOC row.

    Some contents pages use a narrow chapter-number column followed by a title
    and page column.  OCR boxes can have slightly different baselines, causing
    top-down sorting to emit ``title 003`` followed by ``CHAPTER 01``.  The
    completed previous row is unambiguous: the next completed title begins the
    following chapter.  Rejoining here preserves both hierarchy and pagination.
    """
    result = []
    index = 0
    while index < len(lines):
        item = dict(lines[index])
        if DETACHED_CHAPTER.fullmatch(item["text"]):
            if result and PAGE_AT_END.search(result[-1]["text"]):
                previous = result[-1]
                previous["text"] = f'{item["text"]} {previous["text"]}'
                previous["rect"] = (
                    min(previous["rect"][0], item["rect"][0]),
                    min(previous["rect"][1], item["rect"][1]),
                    max(previous["rect"][2], item["rect"][2]),
                    max(previous["rect"][3], item["rect"][3]),
                )
                previous["confidence"] = max(previous["confidence"], item["confidence"])
                index += 1
                continue
            if index + 1 < len(lines) and not DETACHED_CHAPTER.fullmatch(lines[index + 1]["text"]):
                following = dict(lines[index + 1])
                item["text"] = f'{item["text"]} {following["text"]}'
                item["rect"] = (
                    min(item["rect"][0], following["rect"][0]),
                    min(item["rect"][1], following["rect"][1]),
                    max(item["rect"][2], following["rect"][2]),
                    max(item["rect"][3], following["rect"][3]),
                )
                item["confidence"] = max(item["confidence"], following["confidence"])
                index += 1
        result.append(item)
        index += 1
    return result


def normalize_line(text):
    # A thin printed slash before a page number is often read as i/l/|. Only
    # repair it at the end of an otherwise textual TOC row.
    return re.sub(r"(?<=[^0-9\s])[iIlL|](?=\s*\d{1,4}\s*$)", " / ", text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input_pdf")
    parser.add_argument("output_json")
    parser.add_argument("model_root")
    args = parser.parse_args()

    model_root = Path(args.model_root)
    engine = RapidOCR(
        params={
            "Det.model_path": str(model_root / "PP-OCRv6_det_small.onnx"),
            "Cls.model_path": str(model_root / "ch_ppocr_mobile_v2.0_cls_mobile.onnx"),
            "Rec.model_path": str(model_root / "PP-OCRv6_rec_small.onnx"),
        }
    )
    document = pdfium.PdfDocument(args.input_pdf)
    pages = []
    for page_number in range(len(document)):
        page = document[page_number]
        image = page.render(scale=3.0).to_pil()
        result = engine(image)
        texts = tuple(result.txts or ())
        boxes = result.boxes if result.boxes is not None else []
        scores = tuple(result.scores or ())
        lines = []
        for index, (text, box) in enumerate(zip(texts, boxes)):
            clean = normalize_line(str(text).strip())
            confidence = float(scores[index]) if index < len(scores) else 1.0
            if not clean or confidence < 0.45:
                continue
            lines.append({"text": clean, "rect": rect(box), "confidence": confidence})
        ordered = attach_detached_chapter_labels(
            reading_order(merge_row_fragments(lines, image.width), image.width)
        )
        # Keep the original geometry as well as the legacy flattened text.
        # Swift rebuilds rows after detecting physical columns, preventing a
        # left-column title and a right-column title on the same baseline from
        # being fused before the layout is known.
        observations = []
        for item in lines:
            left, top, right, bottom = item["rect"]
            observations.append(
                {
                    "text": item["text"],
                    "rect": [
                        left / image.width,
                        1.0 - bottom / image.height,
                        (right - left) / image.width,
                        (bottom - top) / image.height,
                    ],
                    "confidence": item["confidence"],
                }
            )
        pages.append(
            {
                "page_position": page_number,
                "text": "\n".join(item["text"] for item in ordered),
                "lines": observations,
                "confidence": sum(item["confidence"] for item in ordered) / max(len(ordered), 1),
            }
        )
    Path(args.output_json).write_text(json.dumps(pages, ensure_ascii=False), encoding="utf-8")


if __name__ == "__main__":
    main()
