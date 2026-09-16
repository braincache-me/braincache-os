#!/usr/bin/env python3

"""Overlay activity-log click markers onto a screenshot as an SVG."""

from __future__ import annotations

import argparse
import base64
import json
import struct
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
JPEG_SIGNATURE = b"\xff\xd8"
JPEG_SOF_MARKERS = {
    0xC0,
    0xC1,
    0xC2,
    0xC3,
    0xC5,
    0xC6,
    0xC7,
    0xC9,
    0xCA,
    0xCB,
    0xCD,
    0xCE,
    0xCF,
}
PALETTE = [
    "#ff4d4f",
    "#40a9ff",
    "#73d13d",
    "#faad14",
    "#9254de",
    "#13c2c2",
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render click markers from a JSONL activity log onto an image."
    )
    parser.add_argument("--log-file", required=True, type=Path)
    parser.add_argument("--image-file", required=True, type=Path)
    parser.add_argument("--output-file", required=True, type=Path)
    parser.add_argument("--start-line", required=True, type=int)
    parser.add_argument("--end-line", required=True, type=int)
    parser.add_argument(
        "--window-filter",
        default="",
        help="Only include entries whose windowTitle contains this substring.",
    )
    return parser.parse_args()


def read_image_info(path: Path) -> tuple[str, int, int]:
    data = path.read_bytes()

    if data.startswith(PNG_SIGNATURE):
        if len(data) < 24:
            raise ValueError(f"{path} is not a valid PNG file")
        width, height = struct.unpack(">II", data[16:24])
        return "image/png", width, height

    if data.startswith(JPEG_SIGNATURE):
        offset = 2
        while offset < len(data):
            while offset < len(data) and data[offset] == 0xFF:
                offset += 1
            if offset >= len(data):
                break

            marker = data[offset]
            offset += 1

            if marker in {0xD8, 0xD9}:
                continue
            if marker == 0xDA:
                break
            if offset + 2 > len(data):
                break

            segment_length = struct.unpack(">H", data[offset : offset + 2])[0]
            if segment_length < 2:
                break

            if marker in JPEG_SOF_MARKERS:
                if offset + 7 > len(data):
                    break
                height, width = struct.unpack(">HH", data[offset + 3 : offset + 7])
                return "image/jpeg", width, height

            offset += segment_length

        raise ValueError(f"{path} is not a valid JPEG file")

    raise ValueError(f"Unsupported image type for {path}")


def load_events(
    log_path: Path, start_line: int, end_line: int, window_filter: str
) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []

    with log_path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            if line_number < start_line:
                continue
            if line_number > end_line:
                break

            raw_line = raw_line.strip()
            if not raw_line:
                continue

            entry = json.loads(raw_line)
            title = entry.get("windowTitle", "")
            if window_filter and window_filter not in title:
                continue

            x = entry.get("windowClickX")
            y = entry.get("windowClickY")
            coordinate_source = "windowClick"
            if x is None or y is None:
                x = entry.get("clickX")
                y = entry.get("clickY")
                coordinate_source = "click"

            if x is None or y is None:
                continue

            events.append(
                {
                    "line_number": line_number,
                    "timestamp": entry.get("timestamp", ""),
                    "window_title": title,
                    "x": float(x),
                    "y": float(y),
                    "coordinate_source": coordinate_source,
                }
            )

    if not events:
        raise ValueError("No matching click events found in the selected line range")

    return events


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(value, high))


def build_svg(
    image_path: Path,
    mime_type: str,
    width: int,
    height: int,
    events: list[dict[str, Any]],
) -> str:
    image_data = base64.b64encode(image_path.read_bytes()).decode("ascii")
    legend_height = 48 + len(events) * 24
    canvas_height = height + legend_height

    elements: list[str] = [
        (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" '
            f'height="{canvas_height}" viewBox="0 0 {width} {canvas_height}">'
        ),
        '<rect x="0" y="0" width="100%" height="100%" fill="#111827"/>',
        (
            f'<image x="0" y="0" width="{width}" height="{height}" '
            f'href="data:{mime_type};base64,{image_data}"/>'
        ),
    ]

    for index, event in enumerate(events, start=1):
        color = PALETTE[(index - 1) % len(PALETTE)]
        x = event["x"]
        y = event["y"]
        label_x = clamp(x + 14, 12, width - 30)
        label_y = clamp(y - 14, 18, height - 12)

        elements.extend(
            [
                f'<line x1="{x - 10:.2f}" y1="{y:.2f}" x2="{x + 10:.2f}" y2="{y:.2f}" stroke="{color}" stroke-width="3"/>',
                f'<line x1="{x:.2f}" y1="{y - 10:.2f}" x2="{x:.2f}" y2="{y + 10:.2f}" stroke="{color}" stroke-width="3"/>',
                f'<circle cx="{x:.2f}" cy="{y:.2f}" r="6" fill="{color}" stroke="white" stroke-width="2"/>',
                (
                    f'<rect x="{label_x - 8:.2f}" y="{label_y - 16:.2f}" width="22" height="18" '
                    f'rx="6" fill="{color}" stroke="white" stroke-width="1"/>'
                ),
                (
                    f'<text x="{label_x + 3:.2f}" y="{label_y - 3:.2f}" '
                    'font-family="Menlo, monospace" font-size="12" font-weight="700" '
                    'text-anchor="middle" fill="white">'
                    f"{index}</text>"
                ),
            ]
        )

    legend_top = height + 18
    elements.append(
        (
            f'<text x="16" y="{legend_top}" font-family="Menlo, monospace" '
            'font-size="14" font-weight="700" fill="#f9fafb">'
            "Activity markers (windowClickX/Y, fallback: clickX/Y)</text>"
        )
    )

    for index, event in enumerate(events, start=1):
        color = PALETTE[(index - 1) % len(PALETTE)]
        row_y = legend_top + 24 + (index - 1) * 24
        title = escape(event["window_title"] or "(no title)")
        label = (
            f"{index}. L{event['line_number']}  "
            f"{event['x']:.2f}, {event['y']:.2f}  "
            f"[{event['coordinate_source']}]  {title}"
        )
        elements.extend(
            [
                f'<circle cx="22" cy="{row_y - 4}" r="6" fill="{color}" stroke="white" stroke-width="1.5"/>',
                (
                    f'<text x="38" y="{row_y}" font-family="Menlo, monospace" '
                    'font-size="12" fill="#e5e7eb">'
                    f"{label}</text>"
                ),
            ]
        )

    elements.append("</svg>")
    return "\n".join(elements)


def main() -> None:
    args = parse_args()
    mime_type, width, height = read_image_info(args.image_file)
    events = load_events(
        args.log_file,
        args.start_line,
        args.end_line,
        args.window_filter,
    )
    svg = build_svg(args.image_file, mime_type, width, height, events)
    args.output_file.write_text(svg, encoding="utf-8")

    print(f"Wrote {args.output_file}")
    for index, event in enumerate(events, start=1):
        print(
            f"{index}. line {event['line_number']}: "
            f"{event['x']:.2f}, {event['y']:.2f} "
            f"[{event['coordinate_source']}] "
            f"{event['window_title']}"
        )


if __name__ == "__main__":
    main()
