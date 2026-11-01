import Foundation
import XCTest
@testable import StudyCore

final class ExcerptFileStoreTests: XCTestCase {
    private func fixture() throws -> StudyExcerpt {
        let fragment = try PageSelectionFragment(
            pageIndex: 1,
            rects: [try UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1)],
            origin: .pdfText)
        let selection = try SourceSelection(
            documentID: UUID(uuidString: "A3E86FDB-010B-46A2-B215-98D7D62127DA")!,
            fragments: [fragment], text: "A sentence from page two.")
        return StudyExcerpt(selection: selection, createdAt: Date(timeIntervalSince1970: 1_000))
    }

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("excerpts.json")
    }

    func testReadBackEditAndRemovePreserveSource() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try fixture()
        let first = ExcerptFileStore(fileURL: url)
        try await first.upsert(original)

        let reopened = ExcerptFileStore(fileURL: url)
        let loaded = try await reopened.all()
        XCTAssertEqual(loaded, [original])

        let revised = try original.updatingNote("My own note", at: Date(timeIntervalSince1970: 1_100))
        try await reopened.upsert(revised)
        let afterEdit = try await first.all()
        XCTAssertEqual(afterEdit, [revised])
        XCTAssertEqual(afterEdit[0].selection, original.selection)

        let removed = try await first.remove(id: original.id)
        XCTAssertTrue(removed)
        let afterRemove = try await reopened.all()
        XCTAssertTrue(afterRemove.isEmpty)
    }

    func testCorruptFileIsNotOverwritten() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: url)
        let store = ExcerptFileStore(fileURL: url)

        do {
            try await store.upsert(fixture())
            XCTFail("Corrupt store should reject writes")
        } catch {
            XCTAssertEqual(error as? StudyStoreError, .invalidData)
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
        }
    }

    func testStaleRevisionAndUnsupportedVersionAreRejected() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try fixture()
        let store = ExcerptFileStore(fileURL: url)
        try await store.upsert(original)
        try await store.upsert(original.updatingNote(
            "Latest", at: Date(timeIntervalSince1970: 1_100)))
        do {
            try await store.upsert(original)
            XCTFail("Older revision should be rejected")
        } catch {
            XCTAssertEqual(error as? StudyStoreError, .staleRevision)
        }

        try Data(#"{"schemaVersion":2,"excerpts":[]}"#.utf8).write(to: url)
        do {
            _ = try await store.all()
            XCTFail("Unsupported schema should be rejected")
        } catch {
            XCTAssertEqual(error as? StudyStoreError, .unsupportedVersion(2))
        }
    }

    func testArchiveRoundTripAndNewerRevision() async throws {
        let sourceURL = temporaryFile()
        let targetURL = temporaryFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: targetURL.deletingLastPathComponent())
        }
        let original = try fixture()
        let source = ExcerptFileStore(fileURL: sourceURL)
        let target = ExcerptFileStore(fileURL: targetURL)
        try await source.upsert(original)
        let archive = try await source.exportArchive()

        let firstMerge = try await target.mergeArchive(archive)
        XCTAssertEqual(firstMerge,
                       ArchiveMergeResult(inserted: 1, updated: 0, unchanged: 0))
        let firstRead = try await target.all()
        XCTAssertEqual(firstRead, [original])
        let repeatedMerge = try await target.mergeArchive(archive)
        XCTAssertEqual(repeatedMerge,
                       ArchiveMergeResult(inserted: 0, updated: 0, unchanged: 1))

        let newer = try original.updatingNote("Restored note",
                                             at: Date(timeIntervalSince1970: 1_100))
        try await source.upsert(newer)
        let newerArchive = try await source.exportArchive()
        let newerMerge = try await target.mergeArchive(newerArchive)
        XCTAssertEqual(newerMerge,
                       ArchiveMergeResult(inserted: 0, updated: 1, unchanged: 0))
        let newerRead = try await target.all()
        XCTAssertEqual(newerRead, [newer])
    }

    func testArchiveSourceConflictDoesNotPartiallyImport() async throws {
        let sourceURL = temporaryFile()
        let targetURL = temporaryFile()
        defer {
            try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: targetURL.deletingLastPathComponent())
        }
        let original = try fixture()
        let source = ExcerptFileStore(fileURL: sourceURL)
        let target = ExcerptFileStore(fileURL: targetURL)
        try await target.upsert(original)
        try await source.upsert(fixture())
        try await source.upsert(original)

        let exported = try await source.exportArchive()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported)
            as? [String: Any])
        var excerpts = try XCTUnwrap(object["excerpts"] as? [[String: Any]])
        var conflicting = excerpts[1]
        var selection = try XCTUnwrap(conflicting["selection"] as? [String: Any])
        selection["documentID"] = "D9AA4E03-2EE5-4FB9-AF8B-F7D419158442"
        conflicting["selection"] = selection
        excerpts[1] = conflicting
        object["excerpts"] = excerpts
        let changed = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try await target.mergeArchive(changed)
            XCTFail("Changed source must reject the whole archive")
        } catch {
            XCTAssertEqual(error as? StudyStoreError, .archiveConflict)
            let afterConflict = try await target.all()
            XCTAssertEqual(afterConflict, [original])
        }
    }

    func testUnsupportedArchiveVersionKeepsExistingNotes() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = try fixture()
        let store = ExcerptFileStore(fileURL: url)
        try await store.upsert(original)
        let exported = try await store.exportArchive()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported)
            as? [String: Any])
        object["version"] = 2
        let changed = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try await store.mergeArchive(changed)
            XCTFail("Future archive versions must be rejected")
        } catch {
            XCTAssertEqual(error as? StudyStoreError,
                           .unsupportedArchiveVersion(2))
            let afterReject = try await store.all()
            XCTAssertEqual(afterReject, [original])
        }
    }
}
