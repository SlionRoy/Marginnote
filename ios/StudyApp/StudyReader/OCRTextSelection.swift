import Foundation
import StudyCore

/// Offsets count Swift Characters in the unedited recognition result, not UTF-16 units.
struct OCRTextRegion: Identifiable, Sendable {
    let id = UUID()
    let range: Range<Int>
    let rect: UnitRect
}

enum OCRTextSelection {
    /// Adjacent characters may share one word-sized box. Preserve the actual box;
    /// never subdivide it into invented equal-width character rectangles.
    static func coalescedRegions(text: String,
                                 characterRects: [UnitRect?]) throws -> [OCRTextRegion] {
        let characters = Array(text)
        guard characters.count == characterRects.count else {
            throw OCRServiceError.invalidSelection
        }
        var result: [OCRTextRegion] = []
        for index in characters.indices {
            guard !String(characters[index]).trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty,
                  let rect = characterRects[index] else { continue }
            if let previous = result.last,
               previous.range.upperBound == index,
               nearlyEqual(previous.rect, rect) {
                result[result.count - 1] = OCRTextRegion(
                    range: previous.range.lowerBound..<(index + 1),
                    rect: try enclosing([previous.rect, rect]))
            } else {
                result.append(OCRTextRegion(range: index..<(index + 1), rect: rect))
            }
        }
        return result
    }

    /// Convert chosen source ranges into consecutive runs on each original line.
    /// Missing geometry and unselected characters are never silently included.
    static func slices(in candidates: [OCRCandidate],
                       regionIDs: Set<UUID>) throws -> [OCRCandidate] {
        guard !regionIDs.isEmpty else { throw OCRServiceError.invalidSelection }
        let knownIDs = candidates.flatMap { $0.regions.map(\.id) }
        guard Set(knownIDs).count == knownIDs.count,
              regionIDs.isSubset(of: Set(knownIDs)) else {
            throw OCRServiceError.invalidSelection
        }
        var slices: [OCRCandidate] = []
        for candidate in candidates {
            let chars = Array(candidate.text)
            var previousEnd = 0
            for region in candidate.regions {
                guard !region.range.isEmpty, region.range.lowerBound >= previousEnd,
                      region.range.upperBound <= chars.count else {
                    throw OCRServiceError.invalidSelection
                }
                previousEnd = region.range.upperBound
            }
            var run: [OCRTextRegion] = []
            func appendRun() throws {
                guard let first = run.first, let last = run.last else { return }
                let text = String(chars[first.range.lowerBound..<last.range.upperBound])
                slices.append(OCRCandidate(documentID: candidate.documentID,
                    pageIndex: candidate.pageIndex, text: text,
                    rect: try enclosing(run.map(\.rect)), confidence: candidate.confidence,
                    regions: run.map { region in
                        OCRTextRegion(range: (region.range.lowerBound - first.range.lowerBound)..<(
                            region.range.upperBound - first.range.lowerBound), rect: region.rect)
                    }))
                run.removeAll()
            }
            for region in candidate.regions {
                guard regionIDs.contains(region.id) else {
                    try appendRun()
                    continue
                }
                if let last = run.last {
                    let gap = String(chars[last.range.upperBound..<region.range.lowerBound])
                    if gap.rangeOfCharacter(from: .newlines) != nil ||
                        !gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try appendRun()
                    }
                }
                run.append(region)
            }
            try appendRun()
        }
        guard !slices.isEmpty else { throw OCRServiceError.invalidSelection }
        return slices
    }

    static func text(for region: OCRTextRegion, in candidate: OCRCandidate) -> String {
        let chars = Array(candidate.text)
        guard region.range.lowerBound >= 0, region.range.upperBound <= chars.count else {
            return ""
        }
        return String(chars[region.range])
    }

    static func enclosing(_ rects: [UnitRect]) throws -> UnitRect {
        guard let first = rects.first else { throw OCRServiceError.invalidSelection }
        if rects.allSatisfy({ $0 == first }) { return first }
        let left = rects.reduce(first.x) { min($0, $1.x) }
        let top = rects.reduce(first.y) { min($0, $1.y) }
        let right = min(1, rects.reduce(first.x + first.width) { max($0, $1.x + $1.width) })
        let bottom = min(1, rects.reduce(first.y + first.height) { max($0, $1.y + $1.height) })
        return try UnitRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private static func nearlyEqual(_ a: UnitRect, _ b: UnitRect) -> Bool {
        let tolerance = 0.00001
        return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
