import Foundation
import XCTest
@testable import StudyCore

final class StudyModelsTests: XCTestCase {
    func testOCRCorrectionKeepsOriginalAndLegacyFilesRemainReadable() throws {
        let fragment = try PageSelectionFragment(pageIndex: 0,
            rects: [try UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)], origin: .ocr)
        let selection = try SourceSelection(documentID: UUID(), fragments: [fragment],
                                            text: "corrected", ocrOriginalText: "raw OCR")
        let data = try JSONEncoder().encode(selection)
        let decoded = try JSONDecoder().decode(SourceSelection.self, from: data)
        XCTAssertEqual(decoded, selection)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "ocrOriginalText")
        let old = try JSONDecoder().decode(SourceSelection.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.ocrOriginalText)
        XCTAssertEqual(old.text, "corrected")
        XCTAssertEqual(old.fragments, selection.fragments)
    }

    private func selection(origin: TextOrigin = .pdfText) throws -> SourceSelection {
        try SourceSelection(
            documentID: UUID(uuidString: "A3E86FDB-010B-46A2-B215-98D7D62127DA")!,
            fragments: [
                try PageSelectionFragment(pageIndex: 2, rects: [
                    try UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
                    try UnitRect(x: 0.1, y: 0.32, width: 0.2, height: 0.1)
                ], origin: origin)
            ],
            text: "Selected text"
        )
    }

    func testExcerptRetainsPagePositionAndOriginAfterNoteEdit() throws {
        let source = try selection(origin: .ocr)
        let created = Date(timeIntervalSince1970: 1_000)
        let excerpt = StudyExcerpt(selection: source, createdAt: created)
        let edited = try excerpt.updatingNote("My note", at: Date(timeIntervalSince1970: 1_100))

        XCTAssertEqual(edited.id, excerpt.id)
        XCTAssertEqual(edited.selection, source)
        XCTAssertEqual(edited.selection.fragments[0].pageIndex, 2)
        XCTAssertEqual(edited.selection.fragments[0].rects.count, 2)
        XCTAssertEqual(edited.selection.fragments[0].origin, .ocr)
        XCTAssertEqual(edited.note, "My note")
        XCTAssertEqual(edited.createdAt, created)
        XCTAssertThrowsError(try edited.updatingNote("Older edit", at: created))
    }

    func testCodableRoundTripPreservesSourceAnchor() throws {
        let first = try PageSelectionFragment(pageIndex: 2,
                                              rects: [try UnitRect(x: 0.1, y: 0.2,
                                                                   width: 0.3, height: 0.1)],
                                              origin: .ocr)
        let second = try PageSelectionFragment(pageIndex: 3,
                                               rects: [try UnitRect(x: 0.1, y: 0.1,
                                                                    width: 0.4, height: 0.1)],
                                               origin: .pdfText)
        let source = try SourceSelection(documentID: UUID(),
                                         fragments: [first, second],
                                         text: "Selected across pages")
        let excerpt = StudyExcerpt(selection: source)
        let decoded = try JSONDecoder().decode(StudyExcerpt.self,
                                                from: JSONEncoder().encode(excerpt))
        XCTAssertEqual(decoded, excerpt)
        XCTAssertEqual(decoded.selection.fragments.map(\.pageIndex), [2, 3])
        XCTAssertEqual(decoded.selection.fragments.map(\.origin), [.ocr, .pdfText])
    }

    func testInvalidPageAndGeometryAreRejected() throws {
        XCTAssertThrowsError(try UnitRect(x: 0.9, y: 0, width: 0.2, height: 0.2))
        let rect = try UnitRect(x: 0, y: 0, width: 0.2, height: 0.2)
        XCTAssertThrowsError(try PageSelectionFragment(pageIndex: -1,
                                                        rects: [rect], origin: .pdfText))
        XCTAssertThrowsError(try PageSelectionFragment(pageIndex: 0,
                                                        rects: [], origin: .pdfText))
        let pageTwo = try PageSelectionFragment(pageIndex: 2, rects: [rect], origin: .pdfText)
        let pageThree = try PageSelectionFragment(pageIndex: 3, rects: [rect], origin: .ocr)
        XCTAssertThrowsError(try SourceSelection(documentID: UUID(),
                                                 fragments: [], text: "text"))
        XCTAssertThrowsError(try SourceSelection(documentID: UUID(),
                                                 fragments: [pageTwo], text: "  "))
        XCTAssertThrowsError(try SourceSelection(documentID: UUID(),
                                                 fragments: [pageThree, pageTwo], text: "text"))
        let malformedRect = Data("{\"x\":0.9,\"y\":0,\"width\":0.2,\"height\":0.2}".utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(UnitRect.self, from: malformedRect))
        let emptyGeometry = Data(#"{"pageIndex":0,"rects":[],"origin":"pdfText"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PageSelectionFragment.self,
                                                       from: emptyGeometry))
    }
}
