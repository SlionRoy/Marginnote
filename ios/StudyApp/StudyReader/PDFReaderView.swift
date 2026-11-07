import PDFKit
import SwiftUI
import UIKit

struct PDFReaderView: UIViewRepresentable {
    let pdfView: PDFView
    var observesReadingTaps = false
    var onReadingTap: () -> Void = {}
    var onPageTap: (PDFPage, CGPoint) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        pdfView.accessibilityIdentifier = "reader.pdfView"
        context.coordinator.install(on: pdfView)
        context.coordinator.update(reading: observesReadingTaps, action: onReadingTap, pageAction: onPageTap)
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.update(reading: observesReadingTaps, action: onReadingTap, pageAction: onPageTap)
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        coordinator.remove(from: uiView)
    }

    // Observe a single tap without consuming PDFKit's selection, pan or pinch.
    // The passive double-tap recognizer keeps double-tap zoom from toggling chrome.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var onTap: () -> Void = {}
        private var onPageTap: (PDFPage, CGPoint) -> Void = { _, _ in }
        private weak var pdfView: PDFView?
        private lazy var singleTap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        private let doubleTap = UITapGestureRecognizer()

        func install(on view: PDFView) {
            pdfView = view
            doubleTap.numberOfTapsRequired = 2
            for recognizer in [singleTap, doubleTap] {
                recognizer.cancelsTouchesInView = false
                recognizer.delaysTouchesBegan = false
                recognizer.delaysTouchesEnded = false
                recognizer.delegate = self
                view.addGestureRecognizer(recognizer)
            }
            singleTap.require(toFail: doubleTap)
        }

        func update(reading: Bool, action: @escaping () -> Void,
                    pageAction: @escaping (PDFPage, CGPoint) -> Void) {
            onTap = reading ? action : {}
            onPageTap = pageAction
            singleTap.isEnabled = true
            doubleTap.isEnabled = true
        }

        func remove(from view: PDFView) {
            view.removeGestureRecognizer(singleTap)
            view.removeGestureRecognizer(doubleTap)
            onTap = {}
            onPageTap = { _, _ in }
            pdfView = nil
        }

        @objc private func tapped() {
            onTap()
            guard let view = pdfView else { return }
            let point = singleTap.location(in: view)
            guard let page = view.page(for: point, nearest: false) else { return }
            onPageTap(page, view.convert(point, to: page))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
