import Foundation

public enum StudyDataError: Error, Equatable, Sendable {
    case invalidPageIndex
    case invalidSelectionRect
    case emptySelectionGeometry
    case emptySelectionFragments
    case unorderedSelectionPages
    case emptySelectionText
    case updateBeforePreviousRevision
}

/// Coordinates are normalized to the displayed PDF page, with origin at top left.
/// Converting from PDF or OCR coordinate systems belongs to a later adapter.
public struct UnitRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1, y + height <= 1 else {
            throw StudyDataError.invalidSelectionRect
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey { case x, y, width, height }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(x: values.decode(Double.self, forKey: .x),
                      y: values.decode(Double.self, forKey: .y),
                      width: values.decode(Double.self, forKey: .width),
                      height: values.decode(Double.self, forKey: .height))
    }
}

public enum TextOrigin: String, Codable, Equatable, Sendable {
    case pdfText
    case ocr
}

/// A selected region on one PDF page. Multiple regions may share a page.
public struct PageSelectionFragment: Codable, Equatable, Sendable {
    public let pageIndex: Int
    public let rects: [UnitRect]
    public let origin: TextOrigin

    public init(pageIndex: Int, rects: [UnitRect], origin: TextOrigin) throws {
        guard pageIndex >= 0 else { throw StudyDataError.invalidPageIndex }
        guard !rects.isEmpty else { throw StudyDataError.emptySelectionGeometry }
        self.pageIndex = pageIndex
        self.rects = rects
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey { case pageIndex, rects, origin }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(pageIndex: values.decode(Int.self, forKey: .pageIndex),
                      rects: values.decode([UnitRect].self, forKey: .rects),
                      origin: values.decode(TextOrigin.self, forKey: .origin))
    }
}

/// Ordered fragments preserve source pages without guessing text geometry.
public struct SourceSelection: Codable, Equatable, Sendable {
    public let documentID: UUID
    public let fragments: [PageSelectionFragment]
    public let text: String

    public init(documentID: UUID, fragments: [PageSelectionFragment],
                text: String) throws {
        guard !fragments.isEmpty else { throw StudyDataError.emptySelectionFragments }
        guard zip(fragments, fragments.dropFirst()).allSatisfy({
            $0.0.pageIndex <= $0.1.pageIndex
        }) else {
            throw StudyDataError.unorderedSelectionPages
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudyDataError.emptySelectionText
        }
        self.documentID = documentID
        self.fragments = fragments
        self.text = text
    }

    private enum CodingKeys: String, CodingKey { case documentID, fragments, text }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(documentID: values.decode(UUID.self, forKey: .documentID),
                      fragments: values.decode([PageSelectionFragment].self,
                                               forKey: .fragments),
                      text: values.decode(String.self, forKey: .text))
    }
}

/// An empty note is valid while the user has only made an excerpt.
public struct StudyExcerpt: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let selection: SourceSelection
    public let note: String
    public let createdAt: Date
    public let updatedAt: Date

    public init(id: UUID = UUID(), selection: SourceSelection, note: String = "",
                createdAt: Date = Date()) {
        self.id = id
        self.selection = selection
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public func updatingNote(_ text: String, at date: Date = Date()) throws -> StudyExcerpt {
        guard date >= updatedAt else { throw StudyDataError.updateBeforePreviousRevision }
        return StudyExcerpt(id: id, selection: selection, note: text,
                            createdAt: createdAt, updatedAt: date)
    }

    private init(id: UUID, selection: SourceSelection, note: String,
                 createdAt: Date, updatedAt: Date) {
        self.id = id
        self.selection = selection
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, selection, note, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let createdAt = try values.decode(Date.self, forKey: .createdAt)
        let updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        guard updatedAt >= createdAt else { throw StudyDataError.updateBeforePreviousRevision }
        self.init(id: try values.decode(UUID.self, forKey: .id),
                  selection: try values.decode(SourceSelection.self, forKey: .selection),
                  note: try values.decode(String.self, forKey: .note),
                  createdAt: createdAt, updatedAt: updatedAt)
    }
}
