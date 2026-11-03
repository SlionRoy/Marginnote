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
    @State private var reviewCandidates: [OCRCandidate] = []
    @State private var correctedText = ""
    @State private var selectionError: String?
    @State private var previewReset = 0

    var body: some View {
        NavigationStack {
            Group {
                if reviewing {
                    Form {
                        Section("请对照 PDF 核对并改正") {
                            TextEditor(text: $correctedText)
                                .frame(minHeight: 160)
                                .accessibilityLabel("校正 OCR 文字")
                                .accessibilityIdentifier("ocr.review.text")
                        }
                        Section {
                            Text("第 \((reviewCandidates.first?.pageIndex ?? 0) + 1) 页 · \(reviewCandidates.count) 段所选文字")
                                .foregroundStyle(.secondary)
                            Text("修改文字会保留所选原页位置。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    selectionView
                }
            }
            .navigationTitle(reviewing ? "校正文字" : "识别本页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(reviewing ? "返回" : "关闭") {
                        if reviewing { reviewing = false } else { onCancel() }
                    }
                    .accessibilityIdentifier("ocr.results.back")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if reviewing {
                        Button("建立摘录") {
                            onConfirm(reviewCandidates, correctedText)
                        }
                        .disabled(correctedText.trimmingCharacters(
                            in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("ocr.review.confirm")
                    } else {
                        Button("校正所选", action: beginReview)
                            .disabled(selectedIDs.isEmpty)
                            .accessibilityIdentifier("ocr.selection.review")
                    }
                }
            }
            .alert("无法选择文字", isPresented: Binding(
                get: { selectionError != nil },
                set: { if !$0 { selectionError = nil } }
            )) {
                Button("好") { selectionError = nil }
            } message: {
                Text(selectionError ?? "请重新选择识别区域。")
            }
        }
    }

    private var selectionView: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if let pageImage {
                    OCRSelectionCanvas(image: pageImage, candidates: candidates,
                                       selectedIDs: $selectedIDs, resetToken: previewReset)
                        .frame(height: max(80, min(geometry.size.height * 0.42, 360)))
                        .background(Color.secondary.opacity(0.08))
                    Text("轻点选区，长按后拖动可连续选择；双指可缩放页面。")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal).padding(.top, 8)
                }
                HStack {
                    Text("已选 \(selectedIDs.count) 个区域")
                        .font(.subheadline.monospacedDigit())
                        .accessibilityIdentifier("ocr.selection.count")
                    Spacer()
                    if pageImage != nil {
                        Button("适应页面") { previewReset += 1 }
                            .accessibilityIdentifier("ocr.selection.fitPage")
                    }
                    Button("清空") { selectedIDs.removeAll() }
                        .disabled(selectedIDs.isEmpty)
                        .accessibilityIdentifier("ocr.selection.clear")
                }
                .font(.subheadline)
                .padding(.horizontal).padding(.vertical, 8)
                List {
                    Section {
                        Text("识别框可能覆盖整词。也可以使用下方文字列表选择。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { lineIndex, candidate in
                        Section {
                            ForEach(Array(candidate.regions.enumerated()), id: \.element.id) { regionIndex, region in
                                let text = OCRTextSelection.text(for: region, in: candidate)
                                Button { toggle(region.id) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Image(systemName: selectedIDs.contains(region.id)
                                              ? "checkmark.circle.fill" : "circle")
                                            .accessibilityHidden(true)
                                        Text(text).foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityLabel(text)
                                .accessibilityValue(selectedIDs.contains(region.id) ? "已选择" : "未选择")
                                .accessibilityIdentifier("ocr.region.\(lineIndex).\(regionIndex)")
                            }
                        } header: {
                            HStack(alignment: .firstTextBaseline) {
                                Text("第 \(lineIndex + 1) 行\(candidate.usesLineFallback ? " · 仅整行定位" : "")")
                                Spacer()
                                Button(allSelected(in: candidate) ? "取消整行" : "选择整行") {
                                    toggleLine(candidate)
                                }
                                .textCase(nil)
                                .accessibilityLabel("第 \(lineIndex + 1) 行，\(allSelected(in: candidate) ? "取消整行" : "选择整行")")
                                .accessibilityIdentifier("ocr.line.\(lineIndex).selectAll")
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .accessibilityIdentifier("ocr.selection.textList")
            }
        }
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }

    private func allSelected(in candidate: OCRCandidate) -> Bool {
        !candidate.regions.isEmpty && candidate.regions.allSatisfy { selectedIDs.contains($0.id) }
    }

    private func toggleLine(_ candidate: OCRCandidate) {
        let ids = Set(candidate.regions.map(\.id))
        if allSelected(in: candidate) { selectedIDs.subtract(ids) }
        else { selectedIDs.formUnion(ids) }
    }

    private func beginReview() {
        do {
            reviewCandidates = try OCRTextSelection.slices(in: candidates, regionIDs: selectedIDs)
            correctedText = reviewCandidates.map(\.text).joined(separator: "\n")
            reviewing = true
        } catch {
            selectionError = error.localizedDescription
        }
    }
}
