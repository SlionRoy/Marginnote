import Foundation
import StudyCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private struct OCRChoice {
        let candidates: [OCRCandidate]
        let correctedText: String
    }

    @EnvironmentObject private var session: StudySession
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showingImporter = false
    @State private var showingArchiveImporter = false
    @State private var showingArchiveExporter = false
    @State private var confirmingArchiveExport = false
    @State private var archiveDocument: StudyArchiveDocument?
    @State private var showingExcerpts = false
    @State private var pendingExcerpt: StudyExcerpt?
    @State private var pendingOCR: OCRChoice?

    var body: some View {
        NavigationStack {
            Group {
                if session.document != nil {
                    if sizeClass == .regular {
                        HStack(spacing: 0) {
                            PDFReaderView(pdfView: session.pdfView)
                            Divider()
                            excerptList.frame(width: 320)
                        }
                    } else {
                        PDFReaderView(pdfView: session.pdfView)
                    }
                } else {
                    ContentUnavailableView("还没有 PDF", systemImage: "doc.text",
                                           description: Text("导入 PDF，选择文字或识别扫描页。"))
                }
            }
            .navigationTitle("PDF 学习")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showingImporter = true } label: {
                            Label("导入 PDF", systemImage: "square.and.arrow.down")
                        }
                        Button { confirmingArchiveExport = true } label: {
                            Label("导出摘录备份", systemImage: "square.and.arrow.up")
                        }
                        Button { showingArchiveImporter = true } label: {
                            Label("恢复摘录备份", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Label("文件", systemImage: "folder")
                    }.disabled(session.isBusy)
                }
                if session.document != nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { session.excerptCurrentSelection() } label: {
                            Label("摘录选区", systemImage: "highlighter")
                        }.disabled(session.isBusy)
                        Button {
                            Task { await session.recognizeCurrentPage() }
                        } label: {
                            Label("识别本页", systemImage: "text.viewfinder")
                        }.disabled(session.isBusy)
                        if sizeClass != .regular {
                            Button { showingExcerpts = true } label: {
                                Label("摘录列表", systemImage: "list.bullet")
                            }
                        }
                    }
                }
            }
            .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.pdf]) { result in
                switch result {
                case .success(let url):
                    Task { await session.importPDF(url) }
                case .failure(let error):
                    session.errorMessage = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $showingArchiveImporter,
                          allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url):
                    Task { await session.importArchive(url) }
                case .failure(let error):
                    session.errorMessage = error.localizedDescription
                }
            }
            .fileExporter(isPresented: $showingArchiveExporter,
                          document: archiveDocument, contentType: .json,
                          defaultFilename: "StudyReader-Notes") { result in
                archiveDocument = nil
                switch result {
                case .success:
                    session.infoMessage = "摘录备份已导出。文件包含摘录和笔记文字，请妥善保存。"
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError {
                        session.errorMessage = error.localizedDescription
                    }
                }
            }
            .confirmationDialog("备份文件包含摘录和笔记文字。请选择可信的位置保存。",
                                isPresented: $confirmingArchiveExport) {
                Button("继续导出") {
                    Task {
                        if let archive = await session.makeArchiveDocument() {
                            archiveDocument = archive
                            showingArchiveExporter = true
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(item: $session.editingExcerpt) { excerpt in
                NoteEditorView(excerpt: excerpt) { text in
                    await session.saveNote(text, for: excerpt)
                }
            }
            .sheet(isPresented: $showingExcerpts, onDismiss: {
                if let pendingExcerpt {
                    session.editingExcerpt = pendingExcerpt
                    self.pendingExcerpt = nil
                }
            }) {
                NavigationStack {
                    excerptList.navigationTitle("摘录")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { showingExcerpts = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $session.showingOCRResults, onDismiss: {
                if let pendingOCR {
                    session.prepareOCRExcerpt(pendingOCR.candidates,
                                              correctedText: pendingOCR.correctedText)
                    self.pendingOCR = nil
                }
            }) {
                OCRResultsView(pageImage: session.ocrPageImage,
                               candidates: session.ocrCandidates) {
                    session.showingOCRResults = false
                } onConfirm: { candidates, text in
                    pendingOCR = OCRChoice(candidates: candidates, correctedText: text)
                    session.showingOCRResults = false
                }
            }
            .alert(session.errorMessage == nil ? Text("操作完成") : Text("无法完成操作"),
                   isPresented: Binding(
                get: { session.errorMessage != nil || session.infoMessage != nil },
                set: {
                    if !$0 {
                        session.errorMessage = nil
                        session.infoMessage = nil
                    }
                }
            )) {
                Button("好") {
                    session.errorMessage = nil
                    session.infoMessage = nil
                }
            } message: {
                Text(session.errorMessage ?? session.infoMessage ?? "未知结果")
            }
        }
    }

    private var excerptList: some View {
        List {
            if session.excerpts.isEmpty {
                Text("还没有摘录。先在 PDF 中选中文字，再点“摘录选区”。")
                    .foregroundStyle(.secondary)
            }
            ForEach(session.excerpts) { excerpt in
                Button {
                    session.jump(to: excerpt)
                    if sizeClass == .regular {
                        session.editingExcerpt = excerpt
                    } else {
                        pendingExcerpt = excerpt
                        showingExcerpts = false
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(excerpt.selection.text).lineLimit(3)
                        Text("第 \(excerpt.selection.fragments[0].pageIndex + 1) 页")
                            .font(.caption).foregroundStyle(.secondary)
                        if excerpt.selection.fragments[0].origin == .ocr {
                            Text("OCR 文字")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if !excerpt.note.isEmpty {
                            Text(excerpt.note).lineLimit(2)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

