import StudyCore
import SwiftUI

struct NoteEditorView: View {
    let excerpt: StudyExcerpt
    let onSave: (String) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var noteText: String
    @State private var saving = false

    init(excerpt: StudyExcerpt, onSave: @escaping (String) async -> Bool) {
        self.excerpt = excerpt
        self.onSave = onSave
        _noteText = State(initialValue: excerpt.note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("摘录") {
                    Text(excerpt.selection.text).textSelection(.enabled)
                    Text("第 \(excerpt.selection.fragments[0].pageIndex + 1) 页")
                        .font(.caption).foregroundStyle(.secondary)
                    if excerpt.selection.fragments[0].origin == .ocr {
                        Text("OCR 来源文字")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let original = excerpt.selection.ocrOriginalText,
                   original != excerpt.selection.text {
                    Section("校正前的识别文字") {
                        Text(original).textSelection(.enabled)
                    }
                }
                Section("我的笔记") {
                    TextEditor(text: $noteText)
                        .frame(minHeight: 160)
                        .accessibilityLabel("笔记内容")
                        .accessibilityIdentifier("note.editor.text")
                }
            }
            .navigationTitle("摘录与笔记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saving = true
                        Task {
                            if await onSave(noteText) { dismiss() }
                            saving = false
                        }
                    }.disabled(saving)
                    .accessibilityIdentifier("note.editor.save")
                }
            }
        }
    }
}
