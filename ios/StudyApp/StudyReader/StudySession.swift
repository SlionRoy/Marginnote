import Foundation
import PDFKit
import StudyCore
import SwiftUI
import UIKit

@MainActor
final class StudySession: ObservableObject {
    let pdfView = PDFView()
    @Published private(set) var document: PDFDocument?
    @Published private(set) var documentID: UUID?
    @Published private(set) var excerpts: [StudyExcerpt] = []
    @Published var editingExcerpt: StudyExcerpt?
    @Published private(set) var ocrCandidates: [OCRCandidate] = []
    @Published private(set) var ocrPageImage: UIImage?
    @Published var showingOCRResults = false
    @Published var errorMessage: String?
    @Published var infoMessage: String?
    @Published private(set) var isBusy = false
    @Published var ocrOptions = OCRRecognitionOptions()

    private let store = ExcerptFileStore(
        fileURL: DocumentImport.supportDirectory.appendingPathComponent("excerpts.json"))
    private var displayedAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []

    init() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        isBusy = true
        Task { await restoreLastDocument() }
    }

    private func restoreLastDocument() async {
        defer { isBusy = false }
        do {
            try StorageProtection.prepareLibrary()
            let imported = try await Task.detached(priority: .userInitiated) {
                try DocumentImport.lastDocument()
            }.value
            guard let imported else { return }
            guard let pdf = PDFDocument(url: imported.fileURL), pdf.pageCount > 0 else {
                throw DocumentImportError.invalidPDF
            }
            open(pdf, imported: imported)
            await reloadExcerpts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importPDF(_ source: URL) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try DocumentImport.copyIntoLibrary(source)
            }.value
            guard let pdf = PDFDocument(url: imported.fileURL), pdf.pageCount > 0 else {
                if imported.wasCopied { try? FileManager.default.removeItem(at: imported.fileURL) }
                throw DocumentImportError.invalidPDF
            }
            DocumentImport.remember(imported)
            open(pdf, imported: imported)
            await reloadExcerpts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func makeArchiveDocument() async -> StudyArchiveDocument? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            return StudyArchiveDocument(data: try await store.exportArchive())
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func importArchive(_ source: URL) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if let size, size > ExcerptFileStore.maximumArchiveBytes {
                    throw StudyStoreError.archiveTooLarge
                }
                let handle = try FileHandle(forReadingFrom: source)
                defer { try? handle.close() }
                var data = Data()
                let maximum = ExcerptFileStore.maximumArchiveBytes
                while let chunk = try handle.read(upToCount:
                    min(1_048_576, maximum + 1 - data.count)), !chunk.isEmpty {
                    data.append(chunk)
                    if data.count > maximum { throw StudyStoreError.archiveTooLarge }
                }
                return data
            }.value
            try StorageProtection.prepareLibrary()
            let result = try await store.mergeArchive(data)
            await reloadExcerpts()
            infoMessage = "新增 \(result.inserted) 条、更新 \(result.updated) 条摘录。请导入原 PDF 以查看来源位置。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func excerptCurrentSelection() {
        guard let document, let documentID else { return }
        guard let selection = pdfView.currentSelection else {
            errorMessage = SelectionMappingError.emptyText.localizedDescription
            return
        }
        do {
            let source = try SelectionMapper.map(selection, in: document,
                                                 documentID: documentID)
            editingExcerpt = StudyExcerpt(selection: source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func recognizeCurrentPage() async {
        guard !isBusy else { return }
        guard let document, let documentID, let page = pdfView.currentPage else {
            errorMessage = OCRServiceError.invalidPage.localizedDescription
            return
        }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound, pageIndex >= 0,
              pageIndex < document.pageCount else {
            errorMessage = OCRServiceError.invalidPage.localizedDescription
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            ocrPageImage = nil
            let image = try OCRService.render(page)
            let options = ocrOptions
            let candidates = try await Task.detached(priority: .userInitiated) {
                try OCRService.recognize(image, documentID: documentID,
                                         pageIndex: pageIndex, options: options)
            }.value
            guard self.documentID == documentID else { return }
            guard !candidates.isEmpty else { throw OCRServiceError.noText }
            ocrCandidates = candidates
            ocrPageImage = UIImage(cgImage: image)
            showingOCRResults = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func prepareOCRExcerpt(_ candidates: [OCRCandidate], correctedText: String) {
        guard let first = candidates.first, first.documentID == documentID,
              let document, document.page(at: first.pageIndex) != nil else { return }
        do {
            let selection = try OCRService.sourceSelection(from: candidates,
                                                            correctedText: correctedText)
            editingExcerpt = StudyExcerpt(selection: selection)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveNote(_ text: String, for excerpt: StudyExcerpt) async -> Bool {
        guard excerpt.selection.documentID == documentID else { return false }
        do {
            let date = max(Date(), excerpt.updatedAt.addingTimeInterval(0.001))
            let updated = try excerpt.updatingNote(text, at: date)
            try await store.upsert(updated)
            await reloadExcerpts()
            editingExcerpt = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func jump(to excerpt: StudyExcerpt) {
        guard excerpt.selection.documentID == documentID, let document,
              let fragment = excerpt.selection.fragments.first,
              let page = document.page(at: fragment.pageIndex),
              let rect = fragment.rects.first else { return }
        let pdfRect = SelectionMapper.pdfRect(rect, on: page)
        let destination = PDFDestination(page: page,
                                         at: CGPoint(x: pdfRect.minX, y: pdfRect.maxY))
        pdfView.go(to: destination)
    }

    private func open(_ pdf: PDFDocument, imported: ImportedPDF) {
        clearAnnotations()
        document = pdf
        documentID = imported.id
        pdfView.document = pdf
        pdfView.currentSelection = nil
        excerpts = []
        ocrCandidates = []
        ocrPageImage = nil
        showingOCRResults = false
    }

    private func reloadExcerpts() async {
        guard let documentID else { return }
        do {
            let stored = try await store.all()
            guard self.documentID == documentID else { return }
            excerpts = stored.filter { $0.selection.documentID == documentID }
                .sorted { $0.updatedAt > $1.updatedAt }
            showAnnotations()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearAnnotations() {
        for (page, annotation) in displayedAnnotations {
            page.removeAnnotation(annotation)
        }
        displayedAnnotations.removeAll()
    }

    private func showAnnotations() {
        clearAnnotations()
        guard let document else { return }
        for excerpt in excerpts {
            for fragment in excerpt.selection.fragments {
                guard let page = document.page(at: fragment.pageIndex) else { continue }
                for rect in fragment.rects {
                    let annotation = PDFAnnotation(
                        bounds: SelectionMapper.pdfRect(rect, on: page),
                        forType: .highlight, withProperties: nil)
                    annotation.color = UIColor.systemYellow.withAlphaComponent(0.35)
                    page.addAnnotation(annotation)
                    displayedAnnotations.append((page, annotation))
                }
            }
        }
    }
}
