import Foundation
import SwiftUI
import UIKit

struct OCRResultsView: View {
    let pageImage: UIImage?
    let candidates: [OCRCandidate]
    let onCancel: () -> Void
    let onConfirm: ([OCRCandidate], String) -> Void
    @State private var selectedIDs: Set<UUID> = []
    @State private var reviewing = false
    @State private var correctedText = ""

    private var selectedCandidates: [OCRCandidate] {
        candidates.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if reviewing {
                    Form {
                        Section("识别文字，请对照 PDF 核对并改正") {
                            TextEditor(text: $correctedText)
                                .frame(minHeight: 140)
                                .accessibilityLabel("校正 OCR 文字")
                        }
                        Section {
                            Text("第 \((selectedCandidates.first?.pageIndex ?? 0) + 1) 页 · \(selectedCandidates.count) 个识别区域")
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        if let pageImage {
                            OCRPagePreview(image: pageImage, candidates: candidates,
                                           selectedIDs: selectedIDs, onToggle: toggle)
                                .frame(height: 240)
                                .padding(.horizontal)
                                .padding(.top)
                        }
                        List {
                            Text("点选页面识别区域或下方文字行，核对后建立摘录。")
                                .foregroundStyle(.secondary)
                            ForEach(candidates) { candidate in
                                Button { toggle(candidate.id) } label: {
                                    HStack {
                                        Image(systemName: selectedIDs.contains(candidate.id)
                                              ? "checkmark.circle.fill" : "circle")
                                            .accessibilityHidden(true)
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(candidate.text)
                                            Text("第 \(candidate.pageIndex + 1) 页 · 置信度 \(Int(candidate.confidence * 100))%")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .accessibilityLabel("\(selectedIDs.contains(candidate.id) ? "已选择" : "未选择")，\(candidate.text)")
                            }
                        }
                    }
                }
            }
            .navigationTitle(reviewing ? "校正文字" : "识别本页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(reviewing ? "返回" : "关闭") {
                        if reviewing { reviewing = false } else { onCancel() }
                    }
                }
                if reviewing {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("建立摘录") {
                            onConfirm(selectedCandidates, correctedText)
                        }
                            .disabled(correctedText.trimmingCharacters(
                                in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("校正所选") {
                            correctedText = selectedCandidates.map(\.text).joined(separator: "\n")
                            reviewing = true
                        }.disabled(selectedIDs.isEmpty)
                    }
                }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

private struct OCRPagePreview: View {
    let image: UIImage
    let candidates: [OCRCandidate]
    let selectedIDs: Set<UUID>
    let onToggle: (UUID) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.secondary.opacity(0.08)
                if let imageFrame = OCRService.fittedImageRect(
                    imageSize: image.size, viewport: geometry.size) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: imageFrame.width, height: imageFrame.height)
                        .position(x: imageFrame.midX, y: imageFrame.midY)
                    ForEach(candidates) { candidate in
                        if let rect = OCRService.previewRect(candidate.rect,
                            imageSize: image.size, viewport: geometry.size) {
                            Button { onToggle(candidate.id) } label: {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.accentColor.opacity(
                                        selectedIDs.contains(candidate.id) ? 0.38 : 0.14))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(Color.accentColor, lineWidth: 1)
                                    }
                            }
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .accessibilityLabel("\(selectedIDs.contains(candidate.id) ? "已选择" : "未选择")，\(candidate.text)")
                        }
                    }
                }
            }
        }
        .accessibilityLabel("扫描页识别区域")
    }
}
