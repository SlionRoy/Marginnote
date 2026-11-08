import Foundation
import PDFKit
import StudyCore
import UIKit
import Vision

struct OCRCandidate: Identifiable, Sendable {
    let id = UUID()
    let documentID: UUID
    let pageIndex: Int
    let text: String
    let rect: UnitRect
    let confidence: Float
    let regions: [OCRTextRegion]
    let usesLineFallback: Bool

    init(documentID: UUID, pageIndex: Int, text: String, rect: UnitRect,
         confidence: Float, regions: [OCRTextRegion] = []) {
        self.documentID = documentID
        self.pageIndex = pageIndex
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.usesLineFallback = regions.isEmpty
        self.regions = regions.isEmpty
            ? [OCRTextRegion(range: 0..<text.count, rect: rect)] : regions
    }
}

struct OCRRecognitionOptions: Equatable, Sendable {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case accurate, fast
        var id: String { rawValue }
        var title: String { self == .accurate ? "准确优先" : "速度优先" }
    }
    enum Language: String, CaseIterable, Identifiable, Sendable {
        case automatic, chineseEnglish, english
        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "自动"
            case .chineseEnglish: "简体中文与英语"
            case .english: "英语"
            }
        }
    }
    var mode: Mode = .accurate
    var language: Language = .automatic
    var usesLanguageCorrection = false
}

enum OCRServiceError: LocalizedError {
    case rotatedPage
    case invalidPage
    case noImage
    case noText
    case invalidSelection
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .rotatedPage: "当前版本尚未处理旋转扫描页的 OCR 坐标。"
        case .invalidPage: "无法识别当前页面。"
        case .noImage: "无法生成用于识别的页面图像。"
        case .noText: "本页没有识别出文字，请检查扫描图是否清晰。"
        case .invalidSelection: "请选择同一页面上的识别文字，并核对摘录内容。"
        case .unsupportedLanguage: "当前识别模式不支持所选语言，请改用准确优先或其他语言。"
        }
    }
}

enum OCRService {
    /// PDFKit rendering stays on the UI actor; Vision receives only a rendered image.
    @MainActor
    static func render(_ page: PDFPage, maxDimension: CGFloat = 2048) throws -> CGImage {
        guard page.rotation % 360 == 0 else { throw OCRServiceError.rotatedPage }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw OCRServiceError.invalidPage
        }
        let scale = maxDimension / max(bounds.width, bounds.height)
        let size = CGSize(width: max(1, bounds.width * scale),
                          height: max(1, bounds.height * scale))
        guard let image = page.thumbnail(of: size, for: .cropBox).cgImage else {
            throw OCRServiceError.noImage
        }
        return image
    }

    static func recognize(_ image: CGImage, documentID: UUID,
                          pageIndex: Int,
                          options: OCRRecognitionOptions = .init()) throws -> [OCRCandidate] {
        let request = try configuredRequest(options)
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let candidates = (request.results ?? []).compactMap { observation -> OCRCandidate? in
            guard let recognized = observation.topCandidates(1).first,
                  !recognized.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let rect = try? unitRect(fromVision: observation.boundingBox) else {
                return nil
            }
            let text = recognized.string
            let boxes = text.indices.map { index -> UnitRect? in
                let end = text.index(after: index)
                guard let box = try? recognized.boundingBox(for: index..<end) else { return nil }
                return try? unitRect(fromVision: box.boundingBox)
            }
            let regions = (try? OCRTextSelection.coalescedRegions(
                text: text, characterRects: boxes)) ?? []
            return OCRCandidate(documentID: documentID, pageIndex: pageIndex,
                                text: recognized.string, rect: rect,
                                confidence: recognized.confidence, regions: regions)
        }
        // Keep the request's result order. A proximity-based comparator is not
        // transitive and can silently interleave columns or reorder lines.
        return candidates
    }

    static func configuredRequest(_ options: OCRRecognitionOptions) throws -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.mode == .accurate ? .accurate : .fast
        request.usesLanguageCorrection = options.usesLanguageCorrection
        request.automaticallyDetectsLanguage = options.language == .automatic
        if options.language != .automatic {
            let wanted = options.language == .chineseEnglish ? ["zh-Hans", "en-US"] : ["en-US"]
            let supported = try request.supportedRecognitionLanguages()
            guard wanted.allSatisfy({ supported.contains($0) }) else {
                throw OCRServiceError.unsupportedLanguage
            }
            request.recognitionLanguages = wanted
        }
        return request
    }

    /// Vision uses bottom-left normalized coordinates; StudyCore uses top-left.
    static func unitRect(fromVision box: CGRect) throws -> UnitRect {
        guard box.origin.x.isFinite, box.origin.y.isFinite,
              box.width.isFinite, box.height.isFinite,
              box.width > 0, box.height > 0 else {
            throw OCRServiceError.invalidSelection
        }
        let left = max(0, min(1, box.minX))
        let right = max(0, min(1, box.maxX))
        let top = max(0, min(1, 1 - box.maxY))
        let bottom = max(0, min(1, 1 - box.minY))
        return try UnitRect(x: Double(left), y: Double(top),
                            width: Double(right - left),
                            height: Double(bottom - top))
    }

    static func fittedImageRect(imageSize: CGSize, viewport: CGSize) -> CGRect? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              viewport.width.isFinite, viewport.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return nil }
        let scale = min(viewport.width / imageSize.width,
                        viewport.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (viewport.width - width) / 2,
                      y: (viewport.height - height) / 2,
                      width: width, height: height)
    }

    /// Place a top-left normalized OCR region over an aspect-fit page preview.
    static func previewRect(_ unit: UnitRect, imageSize: CGSize,
                            viewport: CGSize) -> CGRect? {
        guard let imageRect = fittedImageRect(imageSize: imageSize,
                                             viewport: viewport) else { return nil }
        return CGRect(x: imageRect.minX + CGFloat(unit.x) * imageRect.width,
                      y: imageRect.minY + CGFloat(unit.y) * imageRect.height,
                      width: CGFloat(unit.width) * imageRect.width,
                      height: CGFloat(unit.height) * imageRect.height)
    }

    /// Keep each chosen OCR line anchored to its own region on one PDF page.
    static func sourceSelection(from candidates: [OCRCandidate],
                                correctedText: String) throws -> SourceSelection {
        guard let first = candidates.first,
              !correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              Set(candidates.map(\.id)).count == candidates.count,
              candidates.allSatisfy({
                  $0.documentID == first.documentID && $0.pageIndex == first.pageIndex
              }) else {
            throw OCRServiceError.invalidSelection
        }
        let fragment = try PageSelectionFragment(
            pageIndex: first.pageIndex,
            rects: candidates.flatMap { $0.regions.map(\.rect) }, origin: .ocr)
        return try SourceSelection(documentID: first.documentID,
                                   fragments: [fragment], text: correctedText,
                                   ocrOriginalText: candidates.map(\.text).joined(separator: "\n"))
    }
}


// Candidate boxes use top-left normalized page coordinates. The grouping is a
// conservative geometric heuristic, not a claim about another app's algorithm.
struct PageRegion {
    enum Kind: Equatable { case text, graphic }
    let rect: CGRect
    let kind: Kind
}

enum PageRegionDetector {
    static func paragraphs(_ lines: [CGRect]) -> [CGRect] {
        let ordered = lines.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            .sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
        var groups: [(bounds: CGRect, last: CGRect)] = []
        for line in ordered {
            var best: Int?
            var distance = CGFloat.greatestFiniteMagnitude
            for i in groups.indices {
                let previous = groups[i].last
                let gap = line.minY - previous.maxY
                let overlap = min(line.maxX, previous.maxX) - max(line.minX, previous.minX)
                let aligned = overlap >= min(line.width, previous.width) * 0.35
                if gap >= -min(line.height, previous.height) * 0.25,
                   gap <= max(line.height, previous.height) * 0.9,
                   aligned, gap < distance {
                    best = i
                    distance = gap
                }
            }
            if let best {
                groups[best].bounds = groups[best].bounds.union(line)
                groups[best].last = line
            } else {
                groups.append((line, line))
            }
        }
        return groups.map(\.bounds)
    }

    static func hit(_ point: CGPoint, regions: [PageRegion]) -> PageRegion? {
        // Text takes precedence over a larger visual candidate containing it.
        let hits = regions.filter { $0.rect.insetBy(dx: -0.008, dy: -0.008).contains(point) }
        return hits.sorted {
            if $0.kind != $1.kind { return $0.kind == .text }
            return $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height
        }.first
    }

    // PDFKit geometry is preferred when a usable text layer exists. The method
    // returns normalized top-left rectangles, not recognized or copied text.
    @MainActor
    static func nativeTextLines(_ page: PDFPage) -> [CGRect] {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0,
              let selection = page.selection(for: bounds) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let r = line.bounds(for: page).intersection(bounds)
            guard !r.isNull, r.width > 0, r.height > 0 else { return nil }
            return CGRect(x: (r.minX - bounds.minX) / bounds.width,
                          y: (bounds.maxY - r.maxY) / bounds.height,
                          width: r.width / bounds.width, height: r.height / bounds.height)
        }
    }

    // Coarse connected-ink proposals. Text boxes are masked before joining
    // nearby graphic elements; this deliberately remains an approximate layout
    // heuristic and can join unrelated graphics or miss pale artwork.
    static func graphicRegions(pixels: [UInt8], width: Int, height: Int,
                               excluding lines: [CGRect]) -> [CGRect] {
        guard width > 16, height > 16, pixels.count == width * height else { return [] }
        var ink = pixels.map { $0 < 200 }
        for r in lines {
            let x0 = max(0, Int(floor(r.minX * CGFloat(width))) - 1)
            let x1 = min(width, Int(ceil(r.maxX * CGFloat(width))) + 1)
            let y0 = max(0, Int(floor(r.minY * CGFloat(height))) - 1)
            let y1 = min(height, Int(ceil(r.maxY * CGFloat(height))) + 1)
            guard x0 < x1, y0 < y1 else { continue }
            for y in y0..<y1 { for x in x0..<x1 { ink[y * width + x] = false } }
        }
        let radius = max(1, Int((CGFloat(min(width, height)) * 0.023).rounded()))
        var horizontal = [Bool](repeating: false, count: ink.count)
        var joined = [Bool](repeating: false, count: ink.count)
        for y in 0..<height { for x in 0..<width where ink[y * width + x] {
            for xx in max(0, x-radius)...min(width-1, x+radius) { horizontal[y * width + xx] = true }
        }}
        for y in 0..<height { for x in 0..<width where horizontal[y * width + x] {
            for yy in max(0, y-radius)...min(height-1, y+radius) { joined[yy * width + x] = true }
        }}
        var regions: [CGRect] = []
        for start in joined.indices where joined[start] {
            joined[start] = false
            var queue = [start], cursor = 0, count = 0
            var minX = width, minY = height, maxX = -1, maxY = -1
            while cursor < queue.count {
                let current = queue[cursor]; cursor += 1
                let x = current % width, y = current / width
                if ink[current] {
                    count += 1; minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
                if x > 0 && joined[current-1] { joined[current-1] = false; queue.append(current-1) }
                if x+1 < width && joined[current+1] { joined[current+1] = false; queue.append(current+1) }
                if y > 0 && joined[current-width] { joined[current-width] = false; queue.append(current-width) }
                if y+1 < height && joined[current+width] { joined[current+width] = false; queue.append(current+width) }
            }
            guard count >= 30, maxX >= minX, maxY >= minY else { continue }
            let r = CGRect(x: CGFloat(minX)/CGFloat(width), y: CGFloat(minY)/CGFloat(height),
                           width: CGFloat(maxX-minX+1)/CGFloat(width),
                           height: CGFloat(maxY-minY+1)/CGFloat(height))
            let area = r.width * r.height
            if r.width >= 0.10 && r.height >= 0.035 && area >= 0.01 && area <= 0.8 {
                regions.append(r)
            }
        }
        return regions
    }

    static func rasterGraphicRegions(_ image: CGImage, excluding lines: [CGRect]) -> [CGRect] {
        let width = 256, height = 256
        var pixels = [UInt8](repeating: 255, count: width * height)
        let success = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // Bitmap rows and CGImage source rows share the same top-left order.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? graphicRegions(pixels: pixels, width: width, height: height,
                                         excluding: lines) : []
    }

    static func detect(_ image: CGImage, documentID: UUID, pageIndex: Int,
                       options: OCRRecognitionOptions, nativeLines: [CGRect] = []) throws -> [PageRegion] {
        try Task.checkCancellation()
        let textRects: [CGRect]
        if nativeLines.isEmpty {
            // Only line boxes are needed here; do not compute a box per character.
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            let supported = try request.supportedRecognitionLanguages()
            let preferred = ["zh-Hans", "en-US"].filter { supported.contains($0) }
            if !preferred.isEmpty { request.recognitionLanguages = preferred }
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            textRects = (request.results ?? []).compactMap { observation in
                guard let unit = try? OCRService.unitRect(fromVision: observation.boundingBox) else { return nil }
                return CGRect(x: unit.x, y: unit.y, width: unit.width, height: unit.height)
            }
        } else { textRects = nativeLines }
        try Task.checkCancellation()
        var result = paragraphs(textRects).map { PageRegion(rect: $0, kind: .text) }
        let graphics = rasterGraphicRegions(image, excluding: textRects)
        try Task.checkCancellation()
        result.append(contentsOf: graphics.map { PageRegion(rect: $0, kind: .graphic) })
        return result
    }
}
