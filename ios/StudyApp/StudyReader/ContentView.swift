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
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var isImmersive = false
    @State private var showingReadingControls = false
    @State private var showingImporter = false
    @State private var showingArchiveImporter = false
    @State private var showingArchiveExporter = false
    @State private var confirmingArchiveExport = false
    @State private var archiveDocument: StudyArchiveDocument?
    @State private var showingExcerpts = false
    @State private var showingOCRSettings = false
    @State private var pendingExcerpt: StudyExcerpt?
    @State private var pendingOCR: OCRChoice?

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
            Group {
                if session.document != nil {
                    HStack(spacing: 0) {
                        PDFReaderView(pdfView: session.pdfView,
                                      observesReadingTaps: isImmersive) {
                            showingReadingControls.toggle()
                        }
                        if sizeClass == .regular && !isImmersive {
                            Divider()
                            excerptList.frame(width: 320)
                        }
                    }
                    .ignoresSafeArea(.container, edges: isImmersive ? .all : [])
                } else {
                    ContentUnavailableView("还没有 PDF", systemImage: "doc.text",
                                           description: Text("导入 PDF，选择文字或识别扫描页。"))
                }
            }
            // Keep controls in the safe viewport; only the PDF extends to screen edges.
            .frame(width: viewport.size.width, height: viewport.size.height)
            .navigationTitle("PDF 学习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isImmersive ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(isImmersive)
            .persistentSystemOverlays(isImmersive ? .hidden : .automatic)
            .overlay(alignment: .topTrailing) {
                if isImmersive && (showingReadingControls || voiceOverEnabled) {
                    exitReadingButton.padding(12)
                }
            }
            .task(id: showingReadingControls) {
                guard showingReadingControls else { return }
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                showingReadingControls = false
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button { showingImporter = true } label: {
                            Label("导入 PDF", systemImage: "square.and.arrow.down")
                        }
                        Button {
                            if let url = Bundle.main.url(forResource: "F2_image_only", withExtension: "pdf") {
                                Task { await session.importPDF(url) }
                            } else {
                                session.errorMessage = "测试 PDF 未包含在此构建中。"
                            }
                        } label: {
                            Label("打开示例扫描 PDF", systemImage: "doc.text.viewfinder")
                        }
                        .accessibilityIdentifier("reader.openSample")
                        Button { confirmingArchiveExport = true } label: {
                            Label("导出摘录备份", systemImage: "square.and.arrow.up")
                        }
                        Button { showingArchiveImporter = true } label: {
                            Label("恢复摘录备份", systemImage: "arrow.counterclockwise")
                        }
                        Divider()
                        Button { showingOCRSettings = true } label: {
                            Label("识别设置", systemImage: "slider.horizontal.3")
                        }
                        .accessibilityIdentifier("ocr.settings.open")
                    } label: {
                        Label("文件", systemImage: "folder")
                    }
                    .disabled(session.isBusy)
                    .accessibilityIdentifier("reader.fileMenu")
                }
                if session.document != nil {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button {
                            showingReadingControls = false
                            isImmersive = true
                        } label: {
                            Label("全屏阅读", systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                        .accessibilityIdentifier("reader.enterFullscreen")
                        Button { session.excerptCurrentSelection() } label: {
                            Label("摘录选区", systemImage: "highlighter")
                        }.disabled(session.isBusy)
                        Button {
                            Task { await session.recognizeCurrentPage() }
                        } label: {
                            Label("识别本页", systemImage: "text.viewfinder")
                        }
                        .disabled(session.isBusy)
                        .accessibilityIdentifier("ocr.recognizePage")
                        if sizeClass != .regular {
                            Button { showingExcerpts = true } label: {
                                Label("摘录列表", systemImage: "list.bullet")
                            }
                            .accessibilityIdentifier("reader.excerpts")
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
            .sheet(isPresented: $showingOCRSettings) {
                OCRSettingsView(options: $session.ocrOptions)
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
    }

    private var exitReadingButton: some View {
        Button {
            isImmersive = false
            showingReadingControls = false
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.body.weight(.semibold))
                .frame(width: 48, height: 48)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ReadingControlGlass())
        .accessibilityLabel("退出全屏阅读")
        .accessibilityHint("恢复文件、摘录和识别工具栏")
        .accessibilityIdentifier("reader.exitFullscreen")
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

private struct ReadingControlGlass: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(.primary.opacity(0.12), lineWidth: 0.5))
        }
    }
}

private struct OCRSettingsView: View {
    @Binding var options: OCRRecognitionOptions
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("识别模式") {
                    Picker("识别模式", selection: $options.mode) {
                        ForEach(OCRRecognitionOptions.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("ocr.settings.mode")
                }
                Section {
                    Picker("文字语言", selection: $options.language) {
                        ForEach(OCRRecognitionOptions.Language.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .accessibilityIdentifier("ocr.settings.language")
                    Toggle("语言纠错", isOn: $options.usesLanguageCorrection)
                        .accessibilityIdentifier("ocr.settings.languageCorrection")
                } footer: {
                    Text("语言支持取决于系统与识别模式。语言纠错会参考语言模型调整识别文字，结果仍需核对。")
                }
                Section {
                    Text("设置用于下一次识别。准确模式的定位框可能覆盖整词；识别后可以在页面或文字列表中选择，再校正并建立摘录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("识别设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("ocr.settings.done")
                }
            }
        }
    }
}
