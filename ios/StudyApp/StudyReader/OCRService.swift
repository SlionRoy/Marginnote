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
}

enum OCRServiceError: LocalizedError {
    case rotatedPage
    case invalidPage
    case noImage
    case noText
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .rotatedPage: "当前版本尚未处理旋转扫描页的 OCR 坐标。"
        case .invalidPage: "无法识别当前页面。"
        case .noImage: "无法生成用于识别的页面图像。"
        case .noText: "本页没有识别出文字，请检查扫描图是否清晰。"
        case .invalidSelection: "请选择同一页面上的识别文字，并核对摘录内容。"
        }
    }
}

enum OCRService {
    /// PDFKit rendering stays on the UI actor; Vision receives only a rendered image.
    @MainActor
    static func render(_ page: PDFPage) throws -> CGImage {
        guard page.rotation % 360 == 0 else { throw OCRServiceError.rotatedPage }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw OCRServiceError.invalidPage
        }
        let scale = 2048 / max(bounds.width, bounds.height)
        let size = CGSize(width: max(1, bounds.width * scale),
                          height: max(1, bounds.height * scale))
        guard let image = page.thumbnail(of: size, for: .cropBox).cgImage else {
            throw OCRServiceError.noImage
        }
        return image
    }

    static func recognize(_ image: CGImage, documentID: UUID,
                          pageIndex: Int) throws -> [OCRCandidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let candidates = (request.results ?? []).compactMap { observation -> OCRCandidate? in
            guard let recognized = observation.topCandidates(1).first,
                  !recognized.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let rect = try? unitRect(fromVision: observation.boundingBox) else {
                return nil
            }
            return OCRCandidate(documentID: documentID, pageIndex: pageIndex,
                                text: recognized.string, rect: rect,
                                confidence: recognized.confidence)
        }
        return candidates.sorted {
            if abs($0.rect.y - $1.rect.y) > 0.01 { return $0.rect.y < $1.rect.y }
            return $0.rect.x < $1.rect.x
        }
    }

    /// Vision uses bottom-left normalized coordinates; StudyCore uses top-left.
    static func unitRect(fromVision box: CGRect) throws -> UnitRect {
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
            pageIndex: first.pageIndex, rects: candidates.map(\.rect), origin: .ocr)
        return try SourceSelection(documentID: first.documentID,
                                   fragments: [fragment], text: correctedText)
    }
}
