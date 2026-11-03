import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import Vision
import XCTest
@testable import StudyReader

final class OCRTextSelectionTests: XCTestCase {
    private func rect(_ x: Double, _ y: Double = 0.2,
                      _ width: Double = 0.15) throws -> UnitRect {
        try UnitRect(x: x, y: y, width: width, height: 0.05)
    }

    func testWordBoxesAreMergedWithoutInventingCharacterWidths() throws {
        let first = try rect(0.1), second = try rect(0.4)
        let regions = try OCRTextSelection.coalescedRegions(
            text: "read now", characterRects: [first, first, first, first,
                                               nil, second, second, second])
        XCTAssertEqual(regions.map(\.range), [0..<4, 5..<8])
        XCTAssertEqual(regions.map(\.rect), [first, second])
        let line = OCRCandidate(documentID: UUID(), pageIndex: 0, text: "read now",
            rect: try rect(0.1, 0.2, 0.45), confidence: 0.95, regions: regions)
        let selected = try OCRTextSelection.slices(in: [line], regionIDs: [regions[0].id])
        XCTAssertEqual(selected.map(\.text), ["read"])
        XCTAssertEqual(selected.map(\.rect), [first])
        let together = try OCRTextSelection.slices(in: [line], regionIDs: Set(regions.map(\.id)))
        XCTAssertEqual(together.map(\.text), ["read now"])
        let source = try OCRService.sourceSelection(from: together, correctedText: "read now")
        XCTAssertEqual(source.fragments[0].rects, [first, second])
    }

    func testUnicodeRangesPreserveWholeGraphemesAndSplitMissingGeometry() throws {
        let chars = "中👩🏽‍🔬e\u{301}文"
        XCTAssertEqual(chars.count, 4)
        let regions = try OCRTextSelection.coalescedRegions(text: chars,
            characterRects: [try rect(0.1), try rect(0.3), nil, try rect(0.7)])
        let candidate = OCRCandidate(documentID: UUID(), pageIndex: 2, text: chars,
            rect: try rect(0.1, 0.2, 0.75), confidence: 0.8, regions: regions)
        let slices = try OCRTextSelection.slices(in: [candidate], regionIDs: Set(regions.map(\.id)))
        XCTAssertEqual(slices.map(\.text), ["中👩🏽‍🔬", "文"])
        XCTAssertFalse(slices.map(\.text).joined().contains("e"))
        XCTAssertThrowsError(try OCRTextSelection.coalescedRegions(
            text: chars, characterRects: [try rect(0.1)]))
    }

    func testNewlinesKeepSeparateGeometryAndExcerptRuns() throws {
        let boxes: [UnitRect?] = [try rect(0.1), nil, try rect(0.5, 0.6)]
        let regions = try OCRTextSelection.coalescedRegions(text: "A\nB", characterRects: boxes)
        let candidate = OCRCandidate(documentID: UUID(), pageIndex: 0, text: "A\nB",
            rect: try UnitRect(x: 0.1, y: 0.2, width: 0.55, height: 0.45),
            confidence: 1, regions: regions)
        let slices = try OCRTextSelection.slices(in: [candidate], regionIDs: Set(regions.map(\.id)))
        XCTAssertEqual(slices.map(\.text), ["A", "B"])
        let source = try OCRService.sourceSelection(from: slices, correctedText: "A\nB")
        XCTAssertEqual(source.fragments[0].rects, boxes.compactMap { $0 })
    }

    func testUnselectedCharactersAndUnknownRegionsCannotEnterExcerpt() throws {
        let regions = try (0..<3).map { index in
            OCRTextRegion(range: index..<(index + 1), rect: try rect(0.1 + Double(index) * 0.2))
        }
        let candidate = OCRCandidate(documentID: UUID(), pageIndex: 0, text: "甲乙丙",
            rect: try rect(0.1, 0.2, 0.55), confidence: 1, regions: regions)
        let slices = try OCRTextSelection.slices(in: [candidate], regionIDs: [regions[0].id, regions[2].id])
        XCTAssertEqual(slices.map(\.text), ["甲", "丙"])
        XCTAssertThrowsError(try OCRTextSelection.slices(in: [candidate], regionIDs: [UUID()]))
        XCTAssertThrowsError(try OCRTextSelection.slices(in: [candidate], regionIDs: []))
        let invalid = OCRTextRegion(range: 0..<4, rect: try rect(0.1))
        let broken = OCRCandidate(documentID: UUID(), pageIndex: 0, text: "短",
            rect: try rect(0.1), confidence: 1, regions: [invalid])
        XCTAssertThrowsError(try OCRTextSelection.slices(in: [broken], regionIDs: [invalid.id]))
    }

    func testMissingRangeBoxesAreExplicitWholeLineFallback() throws {
        let candidate = OCRCandidate(documentID: UUID(), pageIndex: 0, text: "whole line",
            rect: try rect(0.1, 0.2, 0.7), confidence: 0.6)
        XCTAssertTrue(candidate.usesLineFallback)
        XCTAssertEqual(candidate.regions.count, 1)
        let selected = try OCRTextSelection.slices(in: [candidate], regionIDs: [candidate.regions[0].id])
        XCTAssertEqual(selected[0].text, "whole line")
        XCTAssertEqual(selected[0].rect, candidate.rect)
    }

    func testRecognitionOptionsAndInvalidGeometry() throws {
        let accurate = try OCRService.configuredRequest(.init())
        XCTAssertEqual(accurate.recognitionLevel, .accurate)
        XCTAssertFalse(accurate.usesLanguageCorrection)
        XCTAssertTrue(accurate.automaticallyDetectsLanguage)
        let fast = try OCRService.configuredRequest(.init(
            mode: .fast, language: .english, usesLanguageCorrection: true))
        XCTAssertEqual(fast.recognitionLevel, .fast)
        XCTAssertTrue(fast.usesLanguageCorrection)
        XCTAssertFalse(fast.automaticallyDetectsLanguage)
        XCTAssertEqual(fast.recognitionLanguages, ["en-US"])
        XCTAssertThrowsError(try OCRService.unitRect(fromVision: CGRect(
            x: CGFloat.nan, y: 0, width: 0.5, height: 0.1)))
        XCTAssertThrowsError(try OCRService.unitRect(fromVision: .zero))
    }

    func testRealScanWordSelectionCorrectionAndStoreReopen() async throws {
        let image = try await MainActor.run { () throws -> CGImage in
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "F2_image_only", withExtension: "pdf"))
            let pdf = try XCTUnwrap(PDFDocument(url: url))
            let page = try XCTUnwrap(pdf.page(at: 0))
            XCTAssertTrue((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            return try OCRService.render(page)
        }
        let documentID = UUID()
        let candidates = try OCRService.recognize(image, documentID: documentID, pageIndex: 0,
            options: .init(mode: .accurate, language: .chineseEnglish, usesLanguageCorrection: false))
        let allText = candidates.map(\.text).joined(separator: "\n")
        XCTAssertTrue(allText.contains("扫描"), allText)
        let line = try XCTUnwrap(candidates.first { $0.text.lowercased().contains("read this line") })
        XCTAssertFalse(line.usesLineFallback)
        let found = try XCTUnwrap(line.text.range(of: "read", options: .caseInsensitive))
        let start = line.text.distance(from: line.text.startIndex, to: found.lowerBound)
        let end = line.text.distance(from: line.text.startIndex, to: found.upperBound)
        let expected = start..<end
        let wordRegions = line.regions.filter { $0.range.overlaps(expected) }
        let details = line.regions.map {
            "\($0.range): \(OCRTextSelection.text(for: $0, in: line)) -> \($0.rect)"
        }.joined(separator: "\n")
        let attachment = XCTAttachment(string: details)
        attachment.name = "F2-actual-OCR-text-regions"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(wordRegions.flatMap { Array($0.range) }, Array(expected), details)
        let wordBounds = try OCRTextSelection.enclosing(wordRegions.map(\.rect))
        XCTAssertLessThan(wordBounds.width, line.rect.width * 0.5)
        let slices = try OCRTextSelection.slices(in: [line], regionIDs: Set(wordRegions.map(\.id)))
        XCTAssertEqual(slices.map(\.text).joined().lowercased(), "read")
        let selection = try OCRService.sourceSelection(from: slices, correctedText: "READ")
        XCTAssertEqual(selection.ocrOriginalText?.lowercased(), "read")
        XCTAssertEqual(selection.text, "READ")
        XCTAssertEqual(selection.fragments[0].rects, wordRegions.map(\.rect))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("excerpts.json")
        let note = try StudyExcerpt(selection: selection).updatingNote("OCR 范围测试")
        try await ExcerptFileStore(fileURL: file).upsert(note)
        let reopened = try await ExcerptFileStore(fileURL: file).all()
        XCTAssertEqual(reopened, [note])
    }
}
