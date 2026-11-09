import Foundation
import PDFKit
import UIKit
import XCTest
@testable import StudyReader

/// Expectations come from the self-authored fixture's drawing specification,
/// not from the implementation's proposals. These tests are a synthetic gate,
/// not evidence of equivalence on a user's paper or of real-device latency.
final class PageLayoutTests: XCTestCase {
    private struct ExpectedBlock {
        let name: String
        let kind: String
        let rect: CGRect
        let probes: [CGPoint]

        init(_ name: String, _ kind: String, _ x: CGFloat, _ y: CGFloat,
             _ width: CGFloat, _ height: CGFloat, _ probes: [(CGFloat, CGFloat)]) {
            self.name = name
            self.kind = kind
            rect = CGRect(x: x / 600, y: y / 800, width: width / 600, height: height / 800)
            self.probes = probes.map { CGPoint(x: $0.0 / 600, y: $0.1 / 800) }
        }
    }

    private struct PageResult {
        let fixture: String
        let pageIndex: Int
        let regions: [PageRegion]
        let expected: [ExpectedBlock]
        let elapsedMilliseconds: Double
        let failure: String?
    }

    @MainActor
    func testNativeAndScannedComplexLayouts() async throws {
        var results: [PageResult] = []
        for fixture in ["F5_layout_native", "F6_layout_scanned"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "pdf"))
            let document = try XCTUnwrap(PDFDocument(url: url))
            XCTAssertEqual(document.pageCount, 2)
            for pageIndex in 0..<2 {
                let started = Date()
                var regions: [PageRegion] = [], failure: String?
                do {
                    print("LAYOUT_START \(fixture) page \(pageIndex + 1)")
                    // Match production: isolate parsing and Vision from the main actor.
                    regions = try await Task.detached {
                        try PageLayoutAnalyzer.analyze(fileURL: url, pageIndex: pageIndex,
                            options: OCRRecognitionOptions(language: .english))
                    }.value
                } catch { failure = String(describing: error) }
                let result = PageResult(fixture: fixture, pageIndex: pageIndex,
                    regions: regions, expected: Self.blocks(pageIndex),
                    elapsedMilliseconds: Date().timeIntervalSince(started) * 1000, failure: failure)
                // Persist all four pages even when earlier page assertions will fail.
                try attach(result, page: XCTUnwrap(document.page(at: pageIndex)))
                results.append(result)
            }
        }
        for result in results { check(result) }
    }

    func testParagraphsRespectIndentationShortTailsAndColumns() {
        func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ text: String) -> LayoutTextLine {
            LayoutTextLine(rect: CGRect(x: x, y: y, width: width, height: 0.012), text: text)
        }
        let lines = [
            line(0.12, 0.100, 0.33, "Indented first line in the left column"),
            line(0.10, 0.115, 0.35, "A full second line of the same paragraph"),
            line(0.10, 0.130, 0.18, "A short final line."),
            line(0.12, 0.145, 0.33, "A newly indented paragraph begins here"),
            line(0.10, 0.160, 0.35, "Its second line returns to the left edge"),
            line(0.54, 0.100, 0.35, "A different column at the same height"),
            line(0.54, 0.115, 0.35, "Its second line remains in this column"),
        ]
        let groups = PageLayoutAnalyzer.paragraphs(Array(lines.reversed()))
        XCTAssertEqual(groups.count, 3)
        let first = groups.first { $0.contains { $0.text == "A short final line." } }
        XCTAssertEqual(first?.count, 3)
        let second = groups.first { $0.contains { $0.text == "A newly indented paragraph begins here" } }
        XCTAssertEqual(second?.count, 2)
        let right = groups.first { $0.contains { $0.text == "A different column at the same height" } }
        XCTAssertEqual(right?.count, 2)
        for group in groups {
            let box = PageLayoutAnalyzer.bounds(group)
            XCTAssertTrue(box.maxX < 0.5 || box.minX > 0.5, "No paragraph may span the gutter")
        }
    }

    @MainActor
    func testBodyContinuingAtPageEdgeIsNotDiscardedAsFurniture() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800))
        let image = try XCTUnwrap(renderer.image { context in
            UIColor.white.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
        }.cgImage)
        let rows = [0.040, 0.058, 0.076, 0.094].map { y in
            LayoutTextLine(rect: CGRect(x: 0.08, y: y, width: 0.38, height: 0.014),
                text: "This continuing line is body text, even near the page edge.")
        }
        let regions = PageLayoutAnalyzer.regions(lines: rows, nativeGraphics: [], image: image)
        let point = CGPoint(x: 0.20, y: 0.047)
        XCTAssertEqual(PageRegionDetector.hit(point, regions: regions)?.kind, .text)
        XCTAssertFalse(regions.contains { $0.kind == .marginal && $0.rect.contains(point) })
    }

    @MainActor
    func testOneCaptionOwnsMultipleIndependentImageObjects() throws {
        // Two PDF image objects can be panels of one figure. Conversely, the
        // two different captions on F5 page 2 must keep its lower figures apart.
        let left = CGRect(x: 0.10, y: 0.25, width: 0.30, height: 0.30)
        let right = CGRect(x: 0.53, y: 0.25, width: 0.30, height: 0.30)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 800))
        let image = try XCTUnwrap(renderer.image { context in
            UIColor.white.setFill(); context.cgContext.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            for (index, rect) in [left, right].enumerated() {
                let box = CGRect(x: rect.minX * 600, y: rect.minY * 800,
                    width: rect.width * 600, height: rect.height * 800)
                (index == 0 ? UIColor.systemBlue : UIColor.systemOrange).setFill()
                context.cgContext.fill(box)
            }
        }.cgImage)
        let lines = [
            LayoutTextLine(rect: CGRect(x: 0.08, y: 0.10, width: 0.80, height: 0.015),
                text: "This full width body paragraph ends above the complete illustration."),
            LayoutTextLine(rect: CGRect(x: 0.08, y: 0.12, width: 0.76, height: 0.015),
                text: "Its prose must remain outside the region selected for the panels."),
            LayoutTextLine(rect: CGRect(x: 0.12, y: 0.29, width: 0.14, height: 0.015), text: "Panel A label"),
            LayoutTextLine(rect: CGRect(x: 0.55, y: 0.29, width: 0.14, height: 0.015), text: "Panel B label"),
            LayoutTextLine(rect: CGRect(x: 0.08, y: 0.65, width: 0.80, height: 0.015),
                text: "Fig. 7 | Two related panels in a single independent illustration."),
            LayoutTextLine(rect: CGRect(x: 0.08, y: 0.67, width: 0.76, height: 0.015),
                text: "The caption refers to both image objects and stays outside their parent."),
        ]
        let regions = PageLayoutAnalyzer.regions(lines: lines, nativeGraphics: [left, right], image: image)
        let points = [CGPoint(x: 0.17, y: 0.297), CGPoint(x: 0.60, y: 0.297),
                      CGPoint(x: 0.465, y: 0.40)] // whitespace between the panels
        let hits = points.compactMap { PageRegionDetector.hit($0, regions: regions) }
        XCTAssertEqual(hits.count, points.count, "The inter-panel whitespace belongs to the complete figure")
        for hit in hits {
            XCTAssertEqual(hit.kind, .graphic)
            XCTAssertGreaterThanOrEqual(Self.area(hit.rect.intersection(left)) / Self.area(left), 0.98)
            XCTAssertGreaterThanOrEqual(Self.area(hit.rect.intersection(right)) / Self.area(right), 0.98)
            XCTAssertFalse(hit.rect.contains(CGPoint(x: 0.25, y: 0.107)), "Do not absorb body prose")
            XCTAssertFalse(hit.rect.contains(CGPoint(x: 0.25, y: 0.657)), "Do not absorb the caption")
        }
        if let first = hits.first { XCTAssertTrue(hits.allSatisfy { $0.rect == first.rect }) }
        XCTAssertEqual(PageRegionDetector.hit(CGPoint(x: 0.25, y: 0.657), regions: regions)?.kind, .caption)
    }

    private func check(_ result: PageResult, file: StaticString = #filePath, line: UInt = #line) {
        let context = "\(result.fixture) page \(result.pageIndex + 1)"
        XCTAssertNil(result.failure, "\(context): \(result.failure ?? "")", file: file, line: line)
        let scanned = result.fixture == "F6_layout_scanned"
        for expected in result.expected {
            if expected.kind == "header" || expected.kind == "footer" {
                for point in expected.probes {
                    XCTAssertNil(PageRegionDetector.hit(point, regions: result.regions),
                        "\(context) \(expected.name) must not become a selectable body block", file: file, line: line)
                }
                continue
            }
            if expected.kind == "graphic" {
                let best = result.regions.filter { $0.kind == .graphic }.max {
                    Self.iou($0.rect, expected.rect) < Self.iou($1.rect, expected.rect)
                }
                guard let best else {
                    XCTFail("\(context): missing \(expected.name)", file: file, line: line)
                    continue
                }
                let intersection = Self.area(best.rect.intersection(expected.rect))
                let coverage = intersection / Self.area(expected.rect)
                let leakage = (Self.area(best.rect) - intersection) / Self.area(best.rect)
                XCTAssertGreaterThanOrEqual(Self.iou(best.rect, expected.rect), scanned ? 0.75 : 0.80,
                    "\(context) \(expected.name): whole-figure IoU", file: file, line: line)
                XCTAssertGreaterThanOrEqual(coverage, 0.90,
                    "\(context) \(expected.name): content cut off", file: file, line: line)
                XCTAssertLessThanOrEqual(leakage, 0.15,
                    "\(context) \(expected.name): surrounding content absorbed", file: file, line: line)
                for point in expected.probes {
                    let hit = PageRegionDetector.hit(point, regions: result.regions)
                    XCTAssertEqual(hit?.kind, .graphic,
                        "\(context) \(expected.name): internal label/blank must select its parent figure", file: file, line: line)
                    if let hit {
                        XCTAssertGreaterThanOrEqual(Self.iou(hit.rect, expected.rect), scanned ? 0.75 : 0.80,
                            "\(context) \(expected.name): a label selected a fragment", file: file, line: line)
                    }
                }
                for other in result.expected where other.kind != "graphic" &&
                    other.kind != "header" && other.kind != "footer" {
                    for point in other.probes {
                        XCTAssertFalse(best.rect.contains(point),
                            "\(context) \(expected.name) swallowed \(other.name)", file: file, line: line)
                    }
                }
            } else {
                for point in expected.probes {
                    let hit = PageRegionDetector.hit(point, regions: result.regions)
                    XCTAssertNotNil(hit, "\(context): missing \(expected.name)", file: file, line: line)
                    guard let hit else { continue }
                    XCTAssertTrue(hit.kind == .text || hit.kind == .caption,
                        "\(context): \(expected.name) became a figure or page furniture", file: file, line: line)
                    // Font bounds and OCR line bounds differ; allow a small 6pt margin.
                    let permitted = expected.rect.insetBy(dx: -0.01, dy: -0.0075)
                    let fractionOutside = 1 - Self.area(hit.rect.intersection(permitted)) / max(Self.area(hit.rect), 0.000001)
                    XCTAssertLessThanOrEqual(fractionOutside, 0.12,
                        "\(context): \(expected.name) crossed its paragraph/column/caption boundary", file: file, line: line)
                }
            }
        }
    }

    @MainActor
    private func attach(_ result: PageResult, page: PDFPage) throws {
        let title = "\(result.fixture)-page-\(result.pageIndex + 1)"
        let size = CGSize(width: 900, height: 1200)
        let pageImage = page.thumbnail(of: size, for: .cropBox)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            pageImage.draw(in: CGRect(origin: .zero, size: size))
            let context = renderer.cgContext
            func scaled(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX * size.width, y: r.minY * size.height,
                    width: r.width * size.width, height: r.height * size.height)
            }
            context.setLineDash(phase: 0, lengths: [5, 4])
            context.setStrokeColor(UIColor.systemGreen.cgColor); context.setLineWidth(1.2)
            for expected in result.expected { context.stroke(scaled(expected.rect)) }
            context.setLineDash(phase: 0, lengths: [])
            for (index, region) in result.regions.enumerated() {
                let color: UIColor
                switch region.kind {
                case .graphic: color = .systemPurple
                case .caption: color = .systemOrange
                case .marginal: color = .systemGray
                case .text: color = .systemBlue
                }
                let box = scaled(region.rect)
                context.setStrokeColor(color.cgColor); context.setLineWidth(1.8); context.stroke(box)
                "\(index):\(Self.kind(region.kind))".draw(at: CGPoint(x: box.minX, y: max(0, box.minY - 11)),
                    withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                                     .foregroundColor: color, .backgroundColor: UIColor.white.withAlphaComponent(0.85)])
            }
        }
        let visual = XCTAttachment(image: image)
        visual.name = title + "-expected-green-actual-colored"
        visual.lifetime = .keepAlways; add(visual)
        let report: [String: Any] = [
            "fixture": result.fixture, "page_index": result.pageIndex,
            "elapsed_ms_simulator_only": result.elapsedMilliseconds,
            "failure": result.failure as Any? ?? NSNull(),
            "actual": result.regions.enumerated().map { index, region in
                ["index": index, "kind": Self.kind(region.kind), "rect": Self.rectArray(region.rect)] as [String: Any]
            },
            "expected": result.expected.map { expected in
                let candidates = result.regions.filter { $0.kind == .graphic }
                let best = candidates.max { Self.iou($0.rect, expected.rect) < Self.iou($1.rect, expected.rect) }
                return ["id": expected.name, "kind": expected.kind, "rect": Self.rectArray(expected.rect),
                    "best_graphic_iou": best.map { Self.iou($0.rect, expected.rect) } ?? 0,
                    "probes": expected.probes.map { point -> [String: Any] in
                        let hit = PageRegionDetector.hit(point, regions: result.regions)
                        return ["point": [point.x, point.y], "kind": hit.map { Self.kind($0.kind) } ?? "none",
                                "rect": hit.map { Self.rectArray($0.rect) } ?? []]
                    }] as [String: Any]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        let numeric = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        numeric.name = title + "-regions.json"; numeric.lifetime = .keepAlways; add(numeric)
        // Small log summary remains available even if an xcresult viewer is unavailable.
        print("LAYOUT_RESULT \(title) regions=\(result.regions.count) elapsed_ms=\(Int(result.elapsedMilliseconds)) failure=\(result.failure ?? "none")")
    }

    private static func area(_ r: CGRect) -> CGFloat {
        r.isNull || r.isEmpty || r.isInfinite ? 0 : r.width * r.height
    }
    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = area(a.intersection(b))
        return intersection / max(0.000001, area(a) + area(b) - intersection)
    }
    private static func rectArray(_ r: CGRect) -> [CGFloat] { [r.minX, r.minY, r.width, r.height] }
    private static func kind(_ kind: PageRegion.Kind) -> String {
        switch kind {
        case .text: "text"
        case .graphic: "graphic"
        case .caption: "caption"
        case .marginal: "marginal"
        }
    }

    private static func blocks(_ page: Int) -> [ExpectedBlock] {
        var common = [
            ExpectedBlock("header", "header", 48, 22, 504, 11, [(70, 28), (467, 28)]),
            ExpectedBlock("footer", "footer", 48, 756, 504, 11, [(80, 761), (510, 761)]),
        ]
        if page == 0 {
            common += [
                ExpectedBlock("body_left_1", "text", 48, 63, 208.964, 66, [(78, 69)]),
                ExpectedBlock("body_left_2", "text", 48, 136, 212.238, 44, [(78, 142)]),
                ExpectedBlock("body_right_1", "text", 312, 63, 208.955, 66, [(342, 69)]),
                ExpectedBlock("body_right_2", "text", 312, 136, 213.455, 44, [(342, 142)]),
                ExpectedBlock("whole_figure", "graphic", 48, 223, 504, 316,
                    [(64, 237), (84, 280), (372, 305), (164, 475), (411, 515), (300, 368)]),
                ExpectedBlock("caption_left", "caption", 48, 553.5, 183.4895, 52.5, [(78, 559)]),
                ExpectedBlock("caption_right", "caption", 312, 553.5, 180.115, 52.5, [(342, 559)]),
                ExpectedBlock("body_below_caption", "text", 48, 651, 189.972, 33, [(78, 657)]),
            ]
        } else {
            common += [
                ExpectedBlock("heading", "text", 48, 60, 45, 15, [(64, 68)]),
                ExpectedBlock("body_left_top", "text", 48, 86, 208.964, 88, [(78, 92)]),
                ExpectedBlock("body_right_top", "text", 312, 63, 208.955, 110, [(342, 69)]),
                ExpectedBlock("column_figure", "graphic", 48, 213, 240, 150,
                    [(65, 224), (89, 241), (200, 300), (170, 281)]),
                ExpectedBlock("column_caption", "caption", 48, 372.5, 163.829, 21, [(78, 378)]),
                ExpectedBlock("body_right_beside_figure", "text", 312, 204, 212.238, 132, [(342, 210)]),
                ExpectedBlock("body_left_below", "text", 48, 411, 212.238, 44, [(78, 417)]),
                ExpectedBlock("body_right_below", "text", 312, 361, 212.238, 44, [(342, 367)]),
                ExpectedBlock("equation", "text", 343, 433, 205, 17, [(405, 442)]),
                ExpectedBlock("equation_description", "text", 312, 461, 184.734, 33, [(342, 467)]),
                ExpectedBlock("left_small_figure", "graphic", 48, 554, 220, 125,
                    [(85, 564), (143, 641), (215, 580)]),
                ExpectedBlock("left_small_figure_caption", "caption", 48, 687.5, 143.7775, 21, [(78, 693)]),
                ExpectedBlock("right_small_figure", "graphic", 332, 554, 220, 125,
                    [(369, 564), (427, 641), (499, 580)]),
                ExpectedBlock("right_small_figure_caption", "caption", 332, 687.5, 143.7775, 21, [(362, 693)]),
            ]
        }
        return common
    }
}
