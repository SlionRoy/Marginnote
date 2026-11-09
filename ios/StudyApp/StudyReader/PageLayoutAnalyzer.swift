import Foundation
import PDFKit
import UIKit
import Vision

/// Evidence retained until figure ownership and reading lanes are resolved.
struct LayoutTextLine {
    let rect: CGRect
    let text: String
}

enum PageLayoutAnalyzer {
    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// A worker owns this PDFDocument; no PDFView/PDFPage crosses from the UI actor.
    static func analyze(fileURL: URL, pageIndex: Int,
                        options: OCRRecognitionOptions) throws -> [PageRegion] {
        try Task.checkCancellation()
        guard fileURL.isFileURL, let document = PDFDocument(url: fileURL),
              pageIndex >= 0, pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else { throw OCRServiceError.invalidPage }
        guard page.rotation % 360 == 0 else { throw OCRServiceError.rotatedPage }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { throw OCRServiceError.invalidPage }
        let scale = 1400 / max(bounds.width, bounds.height)
        guard let image = page.thumbnail(of: CGSize(width: bounds.width * scale,
            height: bounds.height * scale), for: .cropBox).cgImage else { throw OCRServiceError.noImage }
        var lines = try nativeLines(page)
        if lines.isEmpty { lines = try recognizedLines(image, options: options) }
        let graphics = page.pageRef.map { PDFGraphicScanner.figures(in: $0) } ?? []
        try Task.checkCancellation()
        return regions(lines: lines, nativeGraphics: graphics, image: image)
    }

    /// PDFKit supplies typographic line bounds. Glyph ink bounds vary between
    /// capitals, descenders and punctuation, so they must not define baselines.
    /// Only wide lines need a horizontal glyph-gap check for a merged gutter.
    static func nativeLines(_ page: PDFPage) throws -> [LayoutTextLine] {
        let crop = page.bounds(for: .cropBox)
        guard crop.width > 0, crop.height > 0 else { return [] }
        let text = (page.string ?? "") as NSString
        let count = page.numberOfCharacters
        func normalized(_ r: CGRect) -> CGRect {
            CGRect(x: (r.minX - crop.minX) / crop.width, y: (crop.maxY - r.maxY) / crop.height,
                   width: r.width / crop.width, height: r.height / crop.height)
        }
        var result: [LayoutTextLine] = []
        for selection in (page.selection(for: crop)?.selectionsByLine() ?? []).prefix(2401) {
            try Task.checkCancellation()
            let r = selection.bounds(for: page).intersection(crop)
            guard valid(r), let string = selection.string,
                  !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let line = LayoutTextLine(rect: normalized(r), text: string)
            guard line.rect.width > 0.55, count == text.length, count <= 60_000 else {
                result.append(line); continue
            }
            var glyphs: [(rect: CGRect, text: String)] = []
            for part in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: part, on: page)
                guard range.location != NSNotFound, range.location >= 0,
                      range.length >= 0, range.location <= count - range.length else { continue }
                for i in range.location..<(range.location + range.length) {
                    let character = text.substring(with: NSRange(location: i, length: 1))
                    guard !character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    let glyph = page.characterBounds(at: i).intersection(r)
                    if valid(glyph) { glyphs.append((glyph, character)) }
                }
            }
            glyphs.sort { $0.rect.minX < $1.rect.minX }
            var fragments: [LayoutTextLine] = [], box = CGRect.null, value = "", previous: CGRect?
            for glyph in glyphs {
                if let last = previous {
                    let gap = glyph.rect.minX - last.maxX
                    if gap > max(crop.width * 0.012, r.height * 0.95) {
                        fragments.append(LayoutTextLine(rect: normalized(box), text: value))
                        box = .null; value = ""
                    } else if gap > min(last.width, glyph.rect.width) * 0.28 { value += " " }
                }
                box = box.union(CGRect(x: glyph.rect.minX, y: r.minY,
                                       width: glyph.rect.width, height: r.height))
                value += glyph.text; previous = glyph.rect
            }
            if valid(box) { fragments.append(LayoutTextLine(rect: normalized(box), text: value)) }
            // Preserve original extraction unless an actual horizontal split exists.
            result.append(contentsOf: fragments.count > 1 ? fragments : [line])
        }
        return result
    }

    static func recognizedLines(_ image: CGImage, options: OCRRecognitionOptions) throws -> [LayoutTextLine] {
        let request = VNRecognizeTextRequest()
        // Region accuracy needs reliable words and small labels, but never per-character OCR.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = options.language == .automatic
        let supported = try request.supportedRecognitionLanguages()
        let wanted = options.language == .english ? ["en-US"] : ["zh-Hans", "en-US"]
        request.recognitionLanguages = wanted.filter { supported.contains($0) }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        return (request.results ?? []).compactMap {
            guard let text = $0.topCandidates(1).first?.string,
                  let r = try? OCRService.unitRect(fromVision: $0.boundingBox) else { return nil }
            return LayoutTextLine(rect: CGRect(x: r.x, y: r.y, width: r.width, height: r.height), text: text)
        }
    }

    static func regions(lines: [LayoutTextLine], nativeGraphics: [CGRect], image: CGImage) -> [PageRegion] {
        // Bounded fallback for pathological pages: never spend unbounded CPU on
        // thousands of vector glyph fragments or guess a whole-page figure.
        guard lines.count <= 2400, !Task.isCancelled else { return [] }
        let lines = lines.filter { valid($0.rect) && !$0.text.isEmpty }
        var margins: [LayoutTextLine] = [], content: [LayoutTextLine] = []
        for line in lines {
            if marginal(line, among: lines) { margins.append(line) } else { content.append(line) }
        }
        // Reject a Form around a whole page or a boxed passage. Form bounds alone
        // are structural evidence, not proof of a semantic figure.
        var figures = outermost(nativeGraphics.filter { r in
            valid(r) && area(r) < 0.78 && area(r) > 0.008 &&
            proseCoverage(in: r, lines: content) < 0.30
        })
        let outside = content.filter { line in !figures.contains { contains($0, line.rect) } }
        let flows = paragraphs(outside)
        let captionSeeds = flows.filter { $0.contains { captionStart($0.text) } }
        let captions = flows.filter { flow in
            captionSeeds.contains { seed in
                let a = bounds(seed), b = bounds(flow)
                return a == b || (abs(a.minY - b.minY) < 0.012 &&
                    abs(a.height - b.height) < 0.025 &&
                    min(abs(a.maxX - b.minX), abs(b.maxX - a.minX)) < 0.25 &&
                    !flow.contains { captionStart($0.text) })
            }
        }
        let prose = flows.filter { flow in
            flow.filter { isProse($0) }.count >= 2
        }
        // Mask only confirmed prose/captions/margins. Diagram labels remain in the
        // visual evidence and are owned by a figure after the page layout is built.
        let barriers = (prose + captions).map(bounds) + margins.map(\.rect)
        let raster = Raster(image)
        let visual = raster.proposals(excluding: barriers, barriers: barriers)
            .filter { proseCoverage(in: $0, lines: outside) < 0.25 }
        figures = outermost(figures + visual)
        // A caption anchors the illustration above it. This also assembles separate
        // Image XObjects and vector panels that have no common Form parent. Text
        // blocks are hard boundaries; adjacent independently captioned figures are
        // kept in their own horizontal lanes.
        for seed in captionSeeds {
            let cap = bounds(seed)
            let peers = captionSeeds.filter { abs(bounds($0).minY - cap.minY) < 0.025 && bounds($0) != cap }
            let companion = captions.filter { abs(bounds($0).minY - cap.minY) < 0.012 }
            let capBand = peers.isEmpty ? companion.map(bounds).reduce(cap) { $0.union($1) } : cap
            let horizontal = capBand.insetBy(dx: -0.025, dy: 0).intersection(unit)
            let above = prose.map(bounds).filter {
                $0.maxY < cap.minY - 0.025 &&
                min($0.maxX, horizontal.maxX) - max($0.minX, horizontal.minX) > 0.06
            }
            let top = above.map(\.maxY).max() ?? 0.09
            let zone = CGRect(x: horizontal.minX, y: top + 0.006, width: horizontal.width,
                              height: max(0, cap.minY - top - 0.012))
            let parts = figures.filter { contains(zone, $0) }
            guard !parts.isEmpty else { continue }
            var parent = parts.reduce(CGRect.null) { $0.union($1) }
            let labels = content.filter { contains(zone, $0.rect) &&
                !$0.text.isEmpty && !isProse($0) }
            for label in labels where label.rect.minY > parent.minY - 0.06 &&
                label.rect.maxY < parent.maxY + 0.04 { parent = parent.union(label.rect) }
            if area(parent) < 0.72 && parent.height > 0.05 &&
                !barriers.contains(where: { area(parent.intersection($0)) > area($0) * 0.10 }) {
                figures.append(parent)
            }
        }
        figures = outermost(figures)
        let text = content.filter { line in !figures.contains { contains($0, line.rect) } }
        let textRegions = paragraphs(text).map { flow in
            let r = bounds(flow)
            let isCaption = captions.contains { contains(bounds($0), r) }
            return PageRegion(rect: r, kind: isCaption ? .caption : .text)
        }
        return figures.map { PageRegion(rect: $0, kind: .graphic) } + textRegions +
            margins.map { PageRegion(rect: $0.rect, kind: .marginal) }
    }

    /// Join only a reading lane. Start a new paragraph at indentation, short tails,
    /// larger leading, or a changed line height; never bridge a column gutter.
    static func paragraphs(_ lines: [LayoutTextLine]) -> [[LayoutTextLine]] {
        var groups: [[LayoutTextLine]] = []
        let ordered = lines.sorted { $0.rect.minY == $1.rect.minY ? $0.rect.minX < $1.rect.minX : $0.rect.minY < $1.rect.minY }
        for line in ordered {
            if Task.isCancelled { return [] }
            let r = line.rect
            var best: Int?, bestGap = CGFloat.greatestFiniteMagnitude
            for i in groups.indices {
                let group = groups[i], last = group.last!.rect, b = bounds(group)
                let h = max(last.height, r.height), gap = r.minY - last.maxY
                let overlap = min(last.maxX, r.maxX) - max(last.minX, r.minX)
                guard gap >= -h * 0.25, gap <= h * 0.85,
                      min(last.height, r.height) / h > 0.72,
                      overlap > min(last.width, r.width) * 0.6,
                      abs(r.minX - b.minX) < 0.027 else { continue }
                let indented = group.count >= 2 && r.minX - b.minX > 0.009
                let shortTail = group.count >= 2 && last.width < b.width * 0.78 &&
                    r.width > last.width * 1.12
                if indented || shortTail || captionStart(line.text) { continue }
                if gap < bestGap { best = i; bestGap = gap }
            }
            if let best { groups[best].append(line) } else { groups.append([line]) }
        }
        return groups
    }

    private static func marginal(_ line: LayoutTextLine, among lines: [LayoutTextLine]) -> Bool {
        let r = line.rect
        guard r.maxY < 0.09 || r.minY > 0.91 else { return false }
        // Edge position alone is insufficient: text continuing into the body stays.
        let hasContinuation = lines.contains {
            let other = $0.rect
            let gap = r.maxY < 0.09 ? other.minY - r.maxY : r.minY - other.maxY
            return gap >= 0 && gap < max(r.height, other.height) * 1.6 &&
                min(other.maxX, r.maxX) > max(other.minX, r.minX)
        }
        return !hasContinuation
    }

    private static func captionStart(_ text: String) -> Bool {
        text.range(of: #"^\s*(fig(ure)?\.?\s*\d|图\s*\d|table\s*\d|表\s*\d)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }
    private static func isProse(_ line: LayoutTextLine) -> Bool {
        let cjk = line.text.unicodeScalars.filter { (0x3400...0x9FFF).contains(Int($0.value)) }.count
        return line.rect.width > 0.18 && (line.text.count >= 32 || cjk >= 13)
    }
    private static func proseCoverage(in r: CGRect, lines: [LayoutTextLine]) -> CGFloat {
        let covered = lines.filter { isProse($0) && contains(r, $0.rect) }
        guard covered.count >= 3 else { return 0 }
        return covered.reduce(0) { $0 + area($1.rect.intersection(r)) } / max(area(r), 0.00001)
    }
    static func bounds(_ lines: [LayoutTextLine]) -> CGRect { lines.reduce(.null) { $0.union($1.rect) } }
    private static func valid(_ r: CGRect) -> Bool {
        !r.isNull && !r.isInfinite && r.width > 0 && r.height > 0 &&
            r.minX.isFinite && r.minY.isFinite && r.maxX.isFinite && r.maxY.isFinite
    }
    private static func area(_ r: CGRect) -> CGFloat { valid(r) ? r.width * r.height : 0 }
    private static func contains(_ parent: CGRect, _ child: CGRect) -> Bool {
        area(parent.intersection(child)) >= area(child) * 0.8
    }
    private static func outermost(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for r in rects.sorted(by: { area($0) > area($1) }) {
            if !result.contains(where: { contains($0, r) }) { result.append(r.intersection(unit)) }
        }
        return result
    }

    /// A low-resolution, aspect-preserving map. Text barriers and whitespace
    /// constrain panel assembly; this is a fallback, not learned layout semantics.
    private struct Raster {
        let width: Int, height: Int
        var pixels: [UInt8]
        init(_ image: CGImage) {
            let scale = 640.0 / Double(max(image.width, image.height))
            width = max(1, Int(Double(image.width) * scale))
            height = max(1, Int(Double(image.height) * scale))
            var data = [UInt8](repeating: 255, count: width * height)
            let w = width, h = height
            data.withUnsafeMutableBytes { raw in
                if let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                    bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                    c.setFillColor(gray: 1, alpha: 1); c.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
            }
            pixels = data
        }
        func proposals(excluding masks: [CGRect], barriers: [CGRect]) -> [CGRect] {
            var ink = pixels.map { $0 < 215 }
            for mask in masks {
                let r = mask.insetBy(dx: -0.004, dy: -0.004).intersection(unit)
                guard valid(r) else { continue }
                let x0 = max(0, Int(r.minX * CGFloat(width))), x1 = min(width, Int(ceil(r.maxX * CGFloat(width))))
                let y0 = max(0, Int(r.minY * CGFloat(height))), y1 = min(height, Int(ceil(r.maxY * CGFloat(height))))
                for y in y0..<y1 { for x in x0..<x1 { ink[y * width + x] = false } }
            }
            // Small local dilation joins strokes. Large panel unions below must pass
            // explicit reading-block and whitespace checks, unlike the 0.5 kernel.
            let radius = 2
            var joined = [Bool](repeating: false, count: ink.count)
            for y in 0..<height { for x in 0..<width where ink[y * width + x] {
                for yy in max(0, y-radius)...min(height-1, y+radius) {
                    for xx in max(0, x-radius)...min(width-1, x+radius) { joined[yy * width + xx] = true }
                }
            }}
            var components: [CGRect] = []
            for start in joined.indices where joined[start] {
                if Task.isCancelled { return [] }
                joined[start] = false
                var queue = [start], cursor = 0, count = 0, x0 = width, x1 = 0, y0 = height, y1 = 0
                while cursor < queue.count {
                    let k = queue[cursor]; cursor += 1
                    let x = k % width, y = k / width
                    if ink[k] { count += 1; x0 = min(x0,x); x1 = max(x1,x); y0 = min(y0,y); y1 = max(y1,y) }
                    for next in [x > 0 ? k-1 : -1, x+1 < width ? k+1 : -1,
                                 y > 0 ? k-width : -1, y+1 < height ? k+width : -1] where next >= 0 {
                        if joined[next] { joined[next] = false; queue.append(next) }
                    }
                }
                guard count > 4 else { continue }
                let r = CGRect(x: CGFloat(x0)/CGFloat(width), y: CGFloat(y0)/CGFloat(height),
                               width: CGFloat(x1-x0+1)/CGFloat(width), height: CGFloat(y1-y0+1)/CGFloat(height))
                // Long thin rules separate page bands, they do not define a figure.
                if r.height < 0.006 && r.width > 0.25 { continue }
                components.append(r)
            }
            guard components.count <= 1200 else { return [] }
            // Assemble panels in a free area, never across prose or caption boxes.
            var changed = true
            var comparisons = 0
            while changed {
                if Task.isCancelled { return [] }
                changed = false
                outer: for i in components.indices {
                    for j in components.indices where j > i {
                        comparisons += 1
                        if comparisons > 200_000 { break outer }
                        let a = components[i], b = components[j]
                        let dx = max(0, max(a.minX,b.minX) - min(a.maxX,b.maxX))
                        let dy = max(0, max(a.minY,b.minY) - min(a.maxY,b.maxY))
                        guard (dx < 0.04 && dy < 0.012) || (dy < 0.035 && dx < 0.012) else { continue }
                        let merged = a.union(b)
                        guard !barriers.contains(where: { area(merged.intersection($0)) > area($0) * 0.08 }) else { continue }
                        components[i] = merged; components.remove(at: j); changed = true; break outer
                    }
                }
            }
            let accepted = components.filter { r in
                r.width > 0.09 && r.height > 0.045 && area(r) > 0.012 && area(r) < 0.72 &&
                !barriers.contains { area(r.intersection($0)) > area($0) * 0.15 }
            }
            // Include a small visual breathing margin around the ink. Clip this
            // margin at reading blocks, rather than swallowing a nearby caption.
            return accepted.map { r in
                var padded = r.insetBy(dx: -6 / CGFloat(width), dy: -6 / CGFloat(height)).intersection(unit)
                for barrier in barriers where padded.intersects(barrier) && !r.intersects(barrier) {
                    if barrier.minY >= r.maxY { padded.size.height = min(padded.maxY, barrier.minY - 0.002) - padded.minY }
                    if barrier.maxY <= r.minY {
                        let bottom = padded.maxY
                        padded.origin.y = max(padded.minY, barrier.maxY + 0.002); padded.size.height = bottom - padded.minY
                    }
                    if barrier.minX >= r.maxX { padded.size.width = min(padded.maxX, barrier.minX - 0.002) - padded.minX }
                    if barrier.maxX <= r.minX {
                        let right = padded.maxX
                        padded.origin.x = max(padded.minX, barrier.maxX + 0.002); padded.size.width = right - padded.minX
                    }
                }
                return padded
            }
        }
    }
}
