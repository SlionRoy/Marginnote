import CoreGraphics
import Foundation
import PDFKit
import StudyCore
import XCTest
@testable import StudyReader

final class SelectionMapperTests: XCTestCase {
    func testTextLayerSelectionKeepsPageAndGeometry() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "F1_text_layer", withExtension: "pdf"))
        let document = try XCTUnwrap(PDFDocument(url: fixture))
        let page = try XCTUnwrap(document.page(at: 0))
        let selection = try XCTUnwrap(page.selection(for: page.bounds(for: .cropBox)))
        let documentID = UUID()

        let mapped = try SelectionMapper.map(selection, in: document,
                                             documentID: documentID)

        XCTAssertEqual(mapped.documentID, documentID)
        XCTAssertTrue(mapped.text.contains("English sentence"))
        XCTAssertFalse(mapped.fragments.isEmpty)
        XCTAssertTrue(mapped.fragments.allSatisfy { $0.pageIndex == 0 })
        XCTAssertTrue(mapped.fragments.allSatisfy { $0.origin == .pdfText })
        for fragment in mapped.fragments {
            for unit in fragment.rects {
                let pdfRect = SelectionMapper.pdfRect(unit, on: page)
                let box = page.bounds(for: .cropBox)
                XCTAssertGreaterThanOrEqual(pdfRect.minX, box.minX - 0.01)
                XCTAssertGreaterThanOrEqual(pdfRect.minY, box.minY - 0.01)
                XCTAssertLessThanOrEqual(pdfRect.maxX, box.maxX + 0.01)
                XCTAssertLessThanOrEqual(pdfRect.maxY, box.maxY + 0.01)
            }
        }
    }

    func testImportDetectsChangedStoredCopy() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "F1_text_layer", withExtension: "pdf"))
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: library) }

        let first = try DocumentImport.copyIntoLibrary(fixture,
                                                       libraryDirectory: library)
        XCTAssertTrue(first.wasCopied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.fileURL.path))
        let second = try DocumentImport.copyIntoLibrary(fixture,
                                                        libraryDirectory: library)
        XCTAssertFalse(second.wasCopied)
        XCTAssertEqual(first.id, second.id)

        try Data("changed".utf8).write(to: first.fileURL)
        XCTAssertThrowsError(try DocumentImport.copyIntoLibrary(
            fixture, libraryDirectory: library)) { error in
            guard case DocumentImportError.storedFileChanged = error else {
                return XCTFail("Expected storedFileChanged, got \(error)")
            }
        }
    }

    func testLastDocumentReopensAndReportsMissingCopy() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "F1_text_layer", withExtension: "pdf"))
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suiteName = "StudyReaderTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? FileManager.default.removeItem(at: library)
            preferences.removePersistentDomain(forName: suiteName)
        }
        let imported = try DocumentImport.copyIntoLibrary(
            fixture, libraryDirectory: library)
        DocumentImport.remember(imported, preferences: preferences)
        let reopened = try XCTUnwrap(DocumentImport.lastDocument(
            libraryDirectory: library, preferences: preferences))
        XCTAssertEqual(reopened.id, imported.id)
        XCTAssertEqual(reopened.fileURL, imported.fileURL)

        try Data("changed".utf8).write(to: imported.fileURL)
        XCTAssertThrowsError(try DocumentImport.lastDocument(
            libraryDirectory: library, preferences: preferences)) { error in
            guard case DocumentImportError.storedFileChanged = error else {
                return XCTFail("Expected storedFileChanged, got \(error)")
            }
        }
        try FileManager.default.removeItem(at: imported.fileURL)
        XCTAssertThrowsError(try DocumentImport.lastDocument(
            libraryDirectory: library, preferences: preferences)) { error in
            guard case DocumentImportError.missingStoredFile = error else {
                return XCTFail("Expected missingStoredFile, got \(error)")
            }
        }
    }

    func testVisionCoordinatesUseTopLeftOrigin() throws {
        let rect = try OCRService.unitRect(fromVision: CGRect(
            x: 0.2, y: 0.3, width: 0.4, height: 0.1))
        XCTAssertEqual(rect.x, 0.2, accuracy: 0.000001)
        XCTAssertEqual(rect.y, 0.6, accuracy: 0.000001)
        XCTAssertEqual(rect.width, 0.4, accuracy: 0.000001)
        XCTAssertEqual(rect.height, 0.1, accuracy: 0.000001)
    }

    func testMultipleOCRLinesKeepSeparateSourceRegions() throws {
        let documentID = UUID()
        let first = OCRCandidate(documentID: documentID, pageIndex: 0,
                                 text: "第一行", rect: try UnitRect(
                                    x: 0.1, y: 0.2, width: 0.5, height: 0.05),
                                 confidence: 0.9)
        let second = OCRCandidate(documentID: documentID, pageIndex: 0,
                                  text: "second line", rect: try UnitRect(
                                    x: 0.1, y: 0.3, width: 0.6, height: 0.05),
                                  confidence: 0.8)
        let selection = try OCRService.sourceSelection(
            from: [first, second], correctedText: "第一行\nsecond line")
        XCTAssertEqual(selection.documentID, documentID)
        XCTAssertEqual(selection.text, "第一行\nsecond line")
        XCTAssertEqual(selection.fragments.count, 1)
        XCTAssertEqual(selection.fragments[0].origin, .ocr)
        XCTAssertEqual(selection.fragments[0].rects, [first.rect, second.rect])

        let anotherPage = OCRCandidate(documentID: documentID, pageIndex: 1,
                                       text: "wrong page", rect: second.rect,
                                       confidence: 0.8)
        XCTAssertThrowsError(try OCRService.sourceSelection(
            from: [first, anotherPage], correctedText: "mixed")) { error in
            guard case OCRServiceError.invalidSelection = error else {
                return XCTFail("Expected invalidSelection, got \(error)")
            }
        }
        XCTAssertThrowsError(try OCRService.sourceSelection(
            from: [first, first], correctedText: "duplicate"))
        let anotherDocument = OCRCandidate(documentID: UUID(), pageIndex: 0,
                                           text: "wrong document", rect: second.rect,
                                           confidence: 0.8)
        XCTAssertThrowsError(try OCRService.sourceSelection(
            from: [first, anotherDocument], correctedText: "mixed"))
    }

    func testOCRPreviewRectAccountsForSideMargins() throws {
        let unit = try UnitRect(x: 0.2, y: 0.3, width: 0.4, height: 0.1)
        let image = CGSize(width: 100, height: 200)
        let viewport = CGSize(width: 300, height: 200)
        let page = try XCTUnwrap(OCRService.fittedImageRect(
            imageSize: image, viewport: viewport))
        let rect = try XCTUnwrap(OCRService.previewRect(
            unit, imageSize: image, viewport: viewport))
        XCTAssertEqual(page.minX, 100, accuracy: 0.001)
        XCTAssertEqual(page.width, 100, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 120, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 60, accuracy: 0.001)
        XCTAssertEqual(rect.width, 40, accuracy: 0.001)
        XCTAssertEqual(rect.height, 20, accuracy: 0.001)
        XCTAssertNil(OCRService.previewRect(
            unit, imageSize: .zero, viewport: viewport))
    }

    func testImageOnlyPageProducesOCRCandidates() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "F2_image_only", withExtension: "pdf"))
        let image = try await MainActor.run { () throws -> CGImage in
            let document = try XCTUnwrap(PDFDocument(url: fixture))
            let page = try XCTUnwrap(document.page(at: 0))
            return try OCRService.render(page)
        }
        let documentID = UUID()
        let candidates = try OCRService.recognize(image,
                                                  documentID: documentID, pageIndex: 0)
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertTrue(candidates.allSatisfy {
            $0.documentID == documentID && $0.pageIndex == 0
        })
    }

    func testLibraryDirectoryIsExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try StorageProtection.secureDirectory(directory)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
