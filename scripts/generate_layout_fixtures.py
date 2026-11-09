"""Generate self-authored complex layout fixtures, never ingest private documents.

Requires the already available PyMuPDF. Coordinates in layout_expected.json are
designed top-left PDF points and normalized rectangles, not detector output.
The two PDFs have identical visible pages: native text/vector Forms versus scans.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

import fitz

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
PREVIEWS = ROOT / "private" / "layout"
W, H = 600, 800
INK = (0.15, 0.18, 0.21)
BLUE = (0.15, 0.40, 0.56)
TEAL = (0.16, 0.52, 0.48)
ORANGE = (0.78, 0.40, 0.20)
EXPECTED: list[dict] = []


def record(page: int, name: str, kind: str, box, probes=()):
    x0, y0, x1, y1 = map(float, box)
    EXPECTED.append({
        "page_index": page, "id": name, "kind": kind,
        "rect_points": [x0, y0, x1 - x0, y1 - y0],
        "rect_normalized": [x0 / W, y0 / H, (x1 - x0) / W, (y1 - y0) / H],
        "hit_points_normalized": [[x / W, y / H] for x, y in probes],
    })


def label(page, x, y, text, size=9, color=INK, font="helv"):
    page.insert_text((x, y), text, fontsize=size, fontname=font, color=color)


def paragraph(page, index, name, x, y, lines, width=240, size=9,
              leading=11, indent=11, kind="text"):
    # Baseline y is explicit; content never depends on a layout detector.
    extent = 0.0
    for i, line in enumerate(lines):
        shift = indent if i == 0 else 0
        measured = fitz.get_text_length(line, fontname="tiro", fontsize=size)
        assert shift + measured <= width, (name, line, shift + measured, width)
        label(page, x + shift, y + i * leading, line, size, font="tiro")
        extent = max(extent, shift + measured)
    box = (x, y - size, x + extent, y + (len(lines) - 1) * leading + 2)
    record(index, name, kind, box, [(x + 30, y - 3)])
    return box[3]


def furniture(page, index):
    label(page, 48, 31, "RESEARCH METHODS  |  Independent layout benchmark", 8, BLUE)
    label(page, 440, 31, "Article  /  2026", 8)
    page.draw_line((48, 42), (552, 42), color=(0.7, 0.73, 0.75), width=0.6)
    record(index, "header", "header", (48, 22, 552, 33), [(70, 28)])
    page.draw_line((48, 748), (552, 748), color=INK, width=0.6)
    label(page, 48, 765, "Synthetic Learning Review", 8, BLUE)
    label(page, 491, 765, f"Page {index + 1} of 2", 8)
    record(index, "footer", "footer", (48, 756, 552, 767), [(80, 761)])


def arrow(page, start, end, color=BLUE):
    page.draw_line(start, end, color=color, width=1.4)
    ex, ey = end
    sx, sy = start
    if abs(ex - sx) >= abs(ey - sy):
        delta = -5 if ex > sx else 5
        page.draw_polyline([(ex + delta, ey - 3), (ex, ey), (ex + delta, ey + 3)], color=color)
    else:
        delta = -5 if ey > sy else 5
        page.draw_polyline([(ex - 3, ey + delta), (ex, ey), (ex + 3, ey + delta)], color=color)


def figure(width=504, height=316):
    """A genuine Form with labels and vector artwork, no enclosing border."""
    doc = fitz.open()
    p = doc.new_page(width=width, height=height)
    label(p, 4, 14, "a   Observed system", 11, BLUE, "hebo")
    label(p, 270, 14, "b   Computational model", 11, BLUE, "hebo")
    for x, title, color in [(6, "Inputs", BLUE), (90, "Memory", TEAL), (174, "Output", ORANGE)]:
        p.draw_rect((x, 37, x + 66, 101), color=color, fill=(0.94, 0.96, 0.96), width=1)
        label(p, x + 8, 58, title, 9, color)
        for k in range(3):
            p.draw_circle((x + 15 + k * 18, 81), 5, color=color, fill=(0.8, 0.88, 0.90))
    arrow(p, (73, 68), (88, 68)); arrow(p, (157, 68), (172, 68))
    for k, title in enumerate(["Encoding", "State update", "Decision"]):
        x = 276 + k * 76
        p.draw_rect((x, 37, x + 64, 101), color=TEAL, width=1)
        label(p, x + 5, 58, title, 8)
        label(p, x + 9, 82, "h(t + 1)", 8, BLUE)
        if k < 2:
            arrow(p, (x + 65, 70), (x + 74, 70), TEAL)
    label(p, 45, 121, "Learning from repeated observations", 9)
    label(p, 280, 121, "Internal text belongs to the whole figure", 8)
    arrow(p, (115, 132), (115, 157), TEAL)
    arrow(p, (377, 132), (377, 157), TEAL)
    label(p, 4, 177, "c   Training response", 10, BLUE, "hebo")
    label(p, 270, 177, "d   Comparison across conditions", 10, BLUE, "hebo")
    for origin, color in [(28, BLUE), (290, TEAL)]:
        p.draw_line((origin, 195), (origin, 286), color=INK, width=0.8)
        p.draw_line((origin, 286), (origin + 190, 286), color=INK, width=0.8)
        for k in range(4):
            yy = 266 - k * 23
            label(p, origin - 18, yy + 3, str(20 + k * 20), 7)
            p.draw_line((origin, yy), (origin + 190, yy), color=(0.84, 0.86, 0.87), width=0.4)
        for k in range(7):
            x = origin + 16 + k * 24
            y = 271 - k * 9 + (k % 2) * 7
            p.draw_circle((x, y), 3.3, color=color, fill=color)
            if k:
                prev = (origin + 16 + (k - 1) * 24, 271 - (k - 1) * 9 + ((k - 1) % 2) * 7)
                p.draw_line(prev, (x, y), color=color, width=1)
        label(p, origin + 23, 303, "Session 1     Session 2     Session 3", 8)
    return doc


P1 = [
    "A learning system can connect observations to a useful",
    "internal representation. We study the visible structure of",
    "a document before interpreting the words on the page.",
    "This preserves illustrations with many small labels and",
    "keeps those labels attached to their original diagram.",
    "The boundary is a separate result.",
]
P2 = [
    "The next paragraph begins with an indentation rather",
    "than a large blank line. Its final line is intentionally short.",
    "A reliable layout should not combine neighboring columns",
    "or extend a paragraph through the central gutter.",
]
R1 = [
    "Text and drawings provide different kinds of evidence.",
    "An exported page may contain a reusable vector group,",
    "while a scanned page contains only one raster image.",
    "The visible organization is the same in both examples.",
    "Selection should follow content boundaries and should",
    "not depend on an incidental label.",
]
R2 = [
    "The complete figure below contains four labeled panels.",
    "The panel letters, axes and labels are internal content.",
    "Its caption is ordinary prose placed below the artwork.",
    "The running title and page number are page furniture.",
]


def build_native():
    doc = fitz.open()
    p = doc.new_page(width=W, height=H)
    furniture(p, 0)
    paragraph(p, 0, "body_left_1", 48, 72, P1)
    paragraph(p, 0, "body_left_2", 48, 145, P2)
    paragraph(p, 0, "body_right_1", 312, 72, R1)
    paragraph(p, 0, "body_right_2", 312, 145, R2)
    artwork = figure()
    placement = fitz.Rect(48, 223, 552, 539)
    p.show_pdf_page(placement, artwork, 0)
    record(0, "whole_figure", "graphic", placement,
           [(64, 237), (84, 280), (372, 305), (164, 475), (411, 515)])
    paragraph(p, 0, "caption_left", 48, 562, [
        "Fig. 1 | An independent diagram for layout validation.",
        "The upper panels show a chain of observed states and",
        "a computational counterpart. Small labels remain part",
        "of the complete illustration. No scientific result is",
        "claimed by this synthetic example.",
    ], size=8.5, leading=10.5, indent=0, kind="caption")
    paragraph(p, 0, "caption_right", 312, 562, [
        "The lower panels contain a deliberately simple series",
        "of points. Axes and session labels must not become",
        "individual selectable paragraphs. This column is the",
        "continuation of the caption and is outside the figure.",
        "All content on this page was written for testing.",
    ], size=8.5, leading=10.5, indent=0, kind="caption")
    paragraph(p, 0, "body_below_caption", 48, 660, [
        "The body resumes after the figure and its caption.",
        "This short paragraph provides a distinct lower block.",
        "A footer rule separates the page furniture below.",
    ])
    p = doc.new_page(width=W, height=H)
    furniture(p, 1)
    label(p, 48, 72, "Results", 12, INK, "hebo")
    record(1, "heading", "text", (48, 60, 93, 75), [(64, 68)])
    paragraph(p, 1, "body_left_top", 48, 95, P1 + P2[:2])
    paragraph(p, 1, "body_right_top", 312, 72, R1 + R2)
    p.show_pdf_page(fitz.Rect(48, 213, 288, 363), artwork, 0)
    record(1, "column_figure", "graphic", (48, 213, 288, 363),
           [(65, 224), (89, 241), (200, 300)])
    paragraph(p, 1, "column_caption", 48, 381, [
        "Fig. 2 | A smaller diagram in the left column.",
        "Adjacent body text belongs to a separate region.",
    ], indent=0, size=8.5, leading=10.5, kind="caption")
    paragraph(p, 1, "body_right_beside_figure", 312, 213, R1 + P2 + [
        "This paragraph stands beside a compact illustration.",
        "Its column must remain separate from the diagram.",
    ])
    paragraph(p, 1, "body_left_below", 48, 420, P2)
    paragraph(p, 1, "body_right_below", 312, 370, P2)
    label(p, 343, 446, "s(t + 1) = a s(t) + b u(t)", 12, INK, "tiit")
    label(p, 535, 446, "(1)", 9)
    record(1, "equation", "text", (343, 433, 548, 450), [(405, 442)])
    paragraph(p, 1, "equation_description", 312, 470, [
        "Here s is a state and u is a measured input. This",
        "equation is included only to test spatial grouping.",
        "A formula is not a figure simply because it is short.",
    ])
    # Two unconnected images with captions are intentionally aligned at the
    # same height. They must not be merged across the column gutter.
    for x, name, fig_no, color in [(48, "left_small_figure", 3, BLUE),
                                  (332, "right_small_figure", 4, ORANGE)]:
        small = fitz.open()
        s = small.new_page(width=220, height=125)
        label(s, 7, 14, "Independent observation", 10, color, "hebo")
        s.draw_line((24, 99), (201, 99), color=INK)
        s.draw_line((24, 30), (24, 99), color=INK)
        for k in range(5):
            xx = 42 + k * 32
            yy = 86 - k * (8 if fig_no == 3 else 4)
            s.draw_rect((xx, yy, xx + 15, 99), color=color, fill=color)
        label(s, 28, 116, "A       B       C       D       E", 8)
        placement = fitz.Rect(x, 554, x + 220, 679)
        p.show_pdf_page(placement, small, 0)
        record(1, name, "graphic", placement, [(x + 37, 564), (x + 95, 641)])
        paragraph(p, 1, name + "_caption", x, 696, [
            f"Fig. {fig_no} | A separate synthetic bar chart.",
            "This caption defines a distinct local block.",
        ], width=220, size=8.5, leading=10.5, indent=0, kind="caption")
    artwork.close()
    return doc


def main():
    FIXTURES.mkdir(parents=True, exist_ok=True)
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    native = build_native()
    native_path = FIXTURES / "F5_layout_native.pdf"
    native.save(native_path, garbage=4, deflate=True, no_new_id=True)
    scan = fitz.open()
    for index, page in enumerate(native):
        pix = page.get_pixmap(matrix=fitz.Matrix(2, 2), alpha=False)
        pix.save(PREVIEWS / f"layout-page-{index + 1}.png")
        out = scan.new_page(width=W, height=H)
        out.insert_image(out.rect, stream=pix.tobytes("jpeg", jpg_quality=80))
    scan_path = FIXTURES / "F6_layout_scanned.pdf"
    scan.save(scan_path, garbage=4, deflate=True, no_new_id=True)
    outputs = []
    for path, expected_text in [(native_path, True), (scan_path, False)]:
        with fitz.open(path) as check:
            assert len(check) == 2
            assert all(bool(p.get_text().strip()) == expected_text for p in check)
        data = path.read_bytes()
        assert len(data) < 1_000_000
        outputs.append({"file": path.name, "bytes": len(data),
                        "sha256": hashlib.sha256(data).hexdigest()})
    metadata = {
        "origin": "Self-authored diagram and prose, no external resources",
        "source_script": "scripts/generate_layout_fixtures.py",
        "coordinate_convention": "top-left, rect = [x, y, width, height]",
        "page_size_points": [W, H],
        "expectation_method": "Manual layout specification, independent of detector outputs",
        "acceptance": {
            "graphic_iou_minimum": 0.85,
            "graphic_label_hits": "All probes in one graphic select that whole graphic",
            "separation": "No graphic contains a caption, header, footer, or adjacent body probe",
            "paragraphs": "Separate indented paragraphs and columns",
            "limitations": "Synthetic fixture coverage is not a real-document equivalence claim",
        },
        "files": outputs, "regions": EXPECTED,
    }
    (FIXTURES / "layout_expected.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"files": outputs, "expected_regions": len(EXPECTED)}, indent=2))


if __name__ == "__main__":
    main()
