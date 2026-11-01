import PDFKit
import SwiftUI

struct PDFReaderView: UIViewRepresentable {
    let pdfView: PDFView

    func makeUIView(context: Context) -> PDFView { pdfView }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}
