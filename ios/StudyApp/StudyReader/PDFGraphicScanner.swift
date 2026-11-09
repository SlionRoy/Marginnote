import CoreGraphics
import Foundation

/// Structural hints, not semantic layout recognition. A graphic-bearing Form
/// preserves its internal labels/panels; a page-sized image is usually a scan.
/// Flat page-level vector artwork, inline images, patterns and nonrectangular
/// clipping deliberately fall back to the page layout detector.
enum PDFGraphicScanner {
    static func figures(in page: CGPDFPage) -> [CGRect] {
        let crop = page.getBoxRect(.cropBox)
        guard valid(crop), page.rotationAngle % 360 == 0, let pageDictionary = page.dictionary,
              let table = operatorTable() else { return [] }
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources)
        // Resources may be inherited from the page tree. The stream resolves
        // resource names; this dictionary is only the fallback for child forms.
        let content = CGPDFContentStreamCreateWithPage(page)
        let budget = Budget()
        let context = Context(crop: crop, resources: resources, table: table,
                              budget: budget, depth: 0, activeForms: [],
                              state: State(clip: crop))
        scan(content, context)
        guard !budget.exhausted, !context.invalid else { return [] }
        // Preserve the largest structural parent. Overlapping but independent
        // objects remain separate; the layout stage decides whether to group.
        let ordered = context.regions.sorted { area($0) > area($1) }
        var result: [CGRect] = []
        for rect in ordered where !result.contains(where: {
            $0.insetBy(dx: -0.001, dy: -0.001).contains(rect)
        }) { result.append(rect) }
        return result
    }

    private final class Budget {
        var operations = 0
        var exhausted = false
    }

    private struct State {
        var transform = CGAffineTransform.identity
        var clip: CGRect
        var uncertainClip = false
        var whiteFill = false
        var whiteStroke = false
    }

    private final class Context {
        let crop: CGRect
        let resources: CGPDFDictionaryRef?
        let table: CGPDFOperatorTableRef
        let budget: Budget
        let depth: Int
        let activeForms: [CGPDFStreamRef]
        var state: State
        var stack: [State] = []
        var regions: [CGRect] = []
        var path = CGRect.null
        var rectangleOnly = false
        var pathCommands = 0
        var curved = false
        var pendingClip = false
        var graphics = 0
        var images = 0
        var curvedPaths = 0
        var invalid = false
        var hasUnsupportedClip = false

        init(crop: CGRect, resources: CGPDFDictionaryRef?, table: CGPDFOperatorTableRef,
             budget: Budget, depth: Int, activeForms: [CGPDFStreamRef], state: State) {
            self.crop = crop; self.resources = resources; self.table = table
            self.budget = budget; self.depth = depth
            self.activeForms = activeForms; self.state = state
        }

        func resetPath() {
            path = .null; pathCommands = 0; rectangleOnly = false
            curved = false; pendingClip = false
        }

        func endPath(fill: Bool, stroke: Bool) {
            if !state.uncertainClip, PDFGraphicScanner.valid(path),
               (fill && !state.whiteFill) || (stroke && !state.whiteStroke),
               PDFGraphicScanner.area(path.intersection(state.clip)) >= 1 {
                graphics += 1
                if curved { curvedPaths += 1 }
            }
            if pendingClip {
                if rectangleOnly && PDFGraphicScanner.valid(path) { state.clip = state.clip.intersection(path) }
                else { state.uncertainClip = true; hasUnsupportedClip = true }
            }
            resetPath()
        }
    }

    private static func scan(_ stream: CGPDFContentStreamRef, _ context: Context) {
        let scanner = CGPDFScannerCreate(stream, context.table,
                                        Unmanaged.passUnretained(context).toOpaque())
        if !CGPDFScannerScan(scanner) { context.invalid = true }
    }

    private static func context(_ scanner: CGPDFScannerRef,
                                _ info: UnsafeMutableRawPointer?) -> Context? {
        guard let info else { return nil }
        let context = Unmanaged<Context>.fromOpaque(info).takeUnretainedValue()
        context.budget.operations += 1
        if context.budget.operations > 30_000 || context.regions.count > 256 {
            context.budget.exhausted = true
        }
        guard !context.budget.exhausted, !context.invalid else {
            CGPDFScannerStop(scanner)
            return nil
        }
        return context
    }

    private static func numbers(_ scanner: CGPDFScannerRef, count: Int) -> [CGFloat]? {
        var values = [CGFloat](repeating: 0, count: count)
        for index in (0..<count).reversed() {
            var value: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &value), value.isFinite,
                  abs(value) < 10_000_000 else { return nil }
            values[index] = CGFloat(value)
        }
        return values
    }

    private static func array(_ dictionary: CGPDFDictionaryRef, key: String,
                              count: Int) -> [CGFloat]? {
        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, key, &array), let array,
              CGPDFArrayGetCount(array) == count else { return nil }
        var values: [CGFloat] = []
        for index in 0..<count {
            var value: CGPDFReal = 0
            guard CGPDFArrayGetNumber(array, index, &value), value.isFinite,
                  abs(value) < 10_000_000 else { return nil }
            values.append(CGFloat(value))
        }
        return values
    }

    private static func matrix(_ values: [CGFloat]) -> CGAffineTransform {
        CGAffineTransform(a: values[0], b: values[1], c: values[2],
                          d: values[3], tx: values[4], ty: values[5])
    }

    private static func valid(_ transform: CGAffineTransform) -> Bool {
        [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
            .allSatisfy { $0.isFinite && abs($0) < 1_000_000_000_000 }
    }

    private static func valid(_ rect: CGRect) -> Bool {
        !rect.isNull && rect.minX.isFinite && rect.minY.isFinite &&
        rect.width.isFinite && rect.height.isFinite && rect.width > 0 && rect.height > 0
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }

    private static func normalized(_ rect: CGRect, context: Context) -> CGRect? {
        guard !context.state.uncertainClip else { return nil }
        let clipped = rect.intersection(context.state.clip).intersection(context.crop)
        guard valid(clipped) else { return nil }
        let crop = context.crop
        let unit = CGRect(x: (clipped.minX - crop.minX) / crop.width,
                          y: (crop.maxY - clipped.maxY) / crop.height,
                          width: clipped.width / crop.width, height: clipped.height / crop.height)
        // Keep logos/icons, narrow rules and whole-page scans out of the figure
        // hierarchy. These thresholds are eligibility checks, not segmentation.
        guard unit.width >= 0.08, unit.height >= 0.04,
              area(unit) >= 0.008, area(unit) <= 0.85 else { return nil }
        return unit
    }

    private static func drawObject(_ scanner: CGPDFScannerRef, context: Context) {
        var name: UnsafePointer<CChar>?
        guard CGPDFScannerPopName(scanner, &name), let name else { context.invalid = true; return }
        let parent = CGPDFScannerGetContentStream(scanner)
        guard let object = CGPDFContentStreamGetResource(parent, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
              let dictionary = CGPDFStreamGetDictionary(stream) else { return }
        var type: UnsafePointer<CChar>?
        guard CGPDFDictionaryGetName(dictionary, "Subtype", &type), let type else { return }
        switch String(cString: type) {
        case "Image":
            var mask: CGPDFBoolean = 0
            if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &mask), mask != 0 { return }
            let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(context.state.transform)
            if let region = normalized(rect, context: context) {
                context.regions.append(region)
                context.images += 1
            }
        case "Form":
            guard context.depth < 8, !context.activeForms.contains(where: { $0 == stream }),
                  let box = array(dictionary, key: "BBox", count: 4) else { return }
            let bounds = CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1])
            guard valid(bounds) else { return }
            var state = context.state
            var matrixObject: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, "Matrix", &matrixObject) {
                guard let transform = array(dictionary, key: "Matrix", count: 6) else { return }
                state.transform = matrix(transform).concatenating(state.transform)
            }
            guard valid(state.transform) else { return }
            let placed = bounds.applying(state.transform)
            state.clip = state.clip.intersection(placed)
            guard valid(state.clip) else { return }
            var resources: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
            // A form with no resource dictionary inherits the current resources.
            // Pass the form dictionary as an empty fallback; parent resolves Do.
            let childResources = resources ?? context.resources ?? dictionary
            let content = CGPDFContentStreamCreateWithStream(stream, childResources, parent)
            let child = Context(crop: context.crop, resources: childResources,
                table: context.table, budget: context.budget, depth: context.depth + 1,
                activeForms: context.activeForms + [stream], state: state)
            scan(content, child)
            guard !child.invalid, !context.budget.exhausted else { return }
            context.graphics += child.graphics
            context.images += child.images
            context.curvedPaths += child.curvedPaths
            // A single rectangle can be a background or text frame. Promote a
            // Form only with an image, multiple graphic paths, or a curve.
            let graphicBearing = child.images > 0 || child.graphics >= 3 || child.curvedPaths > 0
            if graphicBearing, !child.hasUnsupportedClip,
               let region = normalized(placed, context: context) {
                context.regions.append(region)
            } else { context.regions.append(contentsOf: child.regions) }
        default: break
        }
    }

    private static func operatorTable() -> CGPDFOperatorTableRef? {
        guard let table = CGPDFOperatorTableCreate() else { return nil }
        CGPDFOperatorTableSetCallback(table, "q") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info) else { return }
            guard c.stack.count < 128 else { c.invalid = true; return }
            c.stack.append(c.state)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info) else { return }
            guard let state = c.stack.popLast() else { c.invalid = true; return }
            c.state = state
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info) else { return }
            guard let values = PDFGraphicScanner.numbers(scanner, count: 6) else { c.invalid = true; return }
            c.state.transform = PDFGraphicScanner.matrix(values).concatenating(c.state.transform)
            if !PDFGraphicScanner.valid(c.state.transform) { c.invalid = true }
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info) else { return }
            PDFGraphicScanner.drawObject(scanner, context: c)
        }
        for op in ["m", "l"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                guard let c = PDFGraphicScanner.context(scanner, info), let xy = PDFGraphicScanner.numbers(scanner, count: 2) else { return }
                let p = CGPoint(x: xy[0], y: xy[1]).applying(c.state.transform)
                c.path = c.path.union(CGRect(origin: p, size: .zero))
                c.pathCommands += 1; c.rectangleOnly = false
            }
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info), let v = PDFGraphicScanner.numbers(scanner, count: 4) else { return }
            let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3]).standardized
            c.path = c.path.union(r.applying(c.state.transform))
            let t = c.state.transform
            let axisAligned = (abs(t.b) < 0.000001 && abs(t.c) < 0.000001) ||
                              (abs(t.a) < 0.000001 && abs(t.d) < 0.000001)
            c.rectangleOnly = c.pathCommands == 0 && axisAligned; c.pathCommands += 1
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info), let v = PDFGraphicScanner.numbers(scanner, count: 6) else { return }
            for index in stride(from: 0, to: 6, by: 2) {
                let p = CGPoint(x: v[index], y: v[index + 1]).applying(c.state.transform)
                c.path = c.path.union(CGRect(origin: p, size: .zero))
            }
            c.curved = true; c.rectangleOnly = false; c.pathCommands += 1
        }
        for op in ["v", "y"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                guard let c = PDFGraphicScanner.context(scanner, info), let v = PDFGraphicScanner.numbers(scanner, count: 4) else { return }
                for index in [0, 2] {
                    let p = CGPoint(x: v[index], y: v[index + 1]).applying(c.state.transform)
                    c.path = c.path.union(CGRect(origin: p, size: .zero))
                }
                c.curved = true; c.rectangleOnly = false; c.pathCommands += 1
            }
        }
        for op in ["W", "W*"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                PDFGraphicScanner.context(scanner, info)?.pendingClip = true
            }
        }
        CGPDFOperatorTableSetCallback(table, "n") { scanner, info in
            PDFGraphicScanner.context(scanner, info)?.endPath(fill: false, stroke: false)
        }
        for op in ["f", "F", "f*"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                PDFGraphicScanner.context(scanner, info)?.endPath(fill: true, stroke: false)
            }
        }
        for op in ["S", "s"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                PDFGraphicScanner.context(scanner, info)?.endPath(fill: false, stroke: true)
            }
        }
        for op in ["B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                PDFGraphicScanner.context(scanner, info)?.endPath(fill: true, stroke: true)
            }
        }
        CGPDFOperatorTableSetCallback(table, "g") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info), let v = PDFGraphicScanner.numbers(scanner, count: 1) else { return }
            c.state.whiteFill = v[0] >= 0.98
        }
        CGPDFOperatorTableSetCallback(table, "G") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info), let v = PDFGraphicScanner.numbers(scanner, count: 1) else { return }
            c.state.whiteStroke = v[0] >= 0.98
        }
        CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info), let v = PDFGraphicScanner.numbers(scanner, count: 3) else { return }
            c.state.whiteFill = v.allSatisfy { $0 >= 0.98 }
        }
        CGPDFOperatorTableSetCallback(table, "RG") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info), let v = PDFGraphicScanner.numbers(scanner, count: 3) else { return }
            c.state.whiteStroke = v.allSatisfy { $0 >= 0.98 }
        }
        CGPDFOperatorTableSetCallback(table, "k") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info), let v = PDFGraphicScanner.numbers(scanner, count: 4) else { return }
            c.state.whiteFill = v.allSatisfy { $0 <= 0.02 }
        }
        CGPDFOperatorTableSetCallback(table, "K") { scanner, info in
            guard let c = PDFGraphicScanner.context(scanner, info), let v = PDFGraphicScanner.numbers(scanner, count: 4) else { return }
            c.state.whiteStroke = v.allSatisfy { $0 <= 0.02 }
        }
        // Count ignored operators too, so long text-only streams have a bound.
        for op in ["BT", "ET", "Tj", "TJ", "'", "\"", "Tf", "Td", "TD", "Tm", "T*", "h",
                   "Tc", "Tw", "Tz", "TL", "Tr", "Ts", "w", "J", "j", "M", "d", "ri", "i",
                   "gs", "sh", "BMC", "BDC", "EMC", "MP", "DP", "BX", "EX", "BI", "ID", "EI"] {
            CGPDFOperatorTableSetCallback(table, op) { scanner, info in
                _ = PDFGraphicScanner.context(scanner, info)
            }
        }
        return table
    }
}
