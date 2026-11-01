import Foundation
import PDFKit
import StudyCore

enum SelectionMappingError: LocalizedError {
    case emptyText
    case noGeometry
    case rotatedPage

    var errorDescription: String? {
        switch self {
        case .emptyText: "请先在 PDF 中选中文字；扫描页可点“识别本页”。"
        case .noGeometry: "无法取得选区在页面上的位置。"
        case .rotatedPage: "当前版本尚未处理旋转页面的选区坐标。"
        }
    }
}

enum SelectionMapper {
    static func map(_ selection: PDFSelection, in document: PDFDocument,
                    documentID: UUID) throws -> SourceSelection {
        guard let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SelectionMappingError.emptyText
        }
        let lines = selection.selectionsByLine()
        let pieces = lines.isEmpty ? [selection] : lines
        var fragments: [PageSelectionFragment] = []
        for piece in pieces {
            for page in piece.pages {
                guard page.rotation % 360 == 0 else {
                    throw SelectionMappingError.rotatedPage
                }
                let pageIndex = document.index(for: page)
                guard pageIndex != NSNotFound,
                      pageIndex >= 0, pageIndex < document.pageCount else { continue }
                let box = page.bounds(for: .cropBox)
                let region = piece.bounds(for: page).intersection(box)
                guard box.width > 0, box.height > 0,
                      !region.isNull, !region.isEmpty else { continue }
                let x = max(0, min(1, (region.minX - box.minX) / box.width))
                let top = max(0, min(1, 1 - (region.maxY - box.minY) / box.height))
                let right = max(0, min(1, (region.maxX - box.minX) / box.width))
                let bottom = max(0, min(1, 1 - (region.minY - box.minY) / box.height))
                guard right > x, bottom > top else { continue }
                let rect = try UnitRect(x: Double(x), y: Double(top),
                                        width: Double(right - x),
                                        height: Double(bottom - top))
                fragments.append(try PageSelectionFragment(
                    pageIndex: pageIndex, rects: [rect], origin: .pdfText))
            }
        }
        guard !fragments.isEmpty else { throw SelectionMappingError.noGeometry }
        fragments = fragments.enumerated().sorted { left, right in
            if left.element.pageIndex != right.element.pageIndex {
                return left.element.pageIndex < right.element.pageIndex
            }
            return left.offset < right.offset
        }.map(\.element)
        return try SourceSelection(documentID: documentID,
                                   fragments: fragments, text: text)
    }

    static func pdfRect(_ unit: UnitRect, on page: PDFPage) -> CGRect {
        let box = page.bounds(for: .cropBox)
        return CGRect(x: box.minX + CGFloat(unit.x) * box.width,
                      y: box.minY + CGFloat(1 - unit.y - unit.height) * box.height,
                      width: CGFloat(unit.width) * box.width,
                      height: CGFloat(unit.height) * box.height)
    }
}
