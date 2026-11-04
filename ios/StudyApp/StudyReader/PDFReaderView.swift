import PDFKit
import SwiftUI
import UIKit

struct PDFReaderView: UIViewRepresentable {
    let pdfView: PDFView
    var observesReadingTaps = false
    var onReadingTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PDFView {
        pdfView.accessibilityIdentifier = "reader.pdfView"
        context.coordinator.install(on: pdfView)
        context.coordinator.update(enabled: observesReadingTaps, action: onReadingTap)
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        context.coordinator.update(enabled: observesReadingTaps, action: onReadingTap)
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        coordinator.remove(from: uiView)
    }

    // Observe a single tap without consuming PDFKit's selection, pan or pinch.
    // The passive double-tap recognizer keeps double-tap zoom from toggling chrome.
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private var onTap: () -> Void = {}
        private lazy var singleTap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        private let doubleTap = UITapGestureRecognizer()

        func install(on view: PDFView) {
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

        func update(enabled: Bool, action: @escaping () -> Void) {
            onTap = action
            if singleTap.isEnabled != enabled { singleTap.isEnabled = enabled }
            if doubleTap.isEnabled != enabled { doubleTap.isEnabled = enabled }
        }

        func remove(from view: PDFView) {
            view.removeGestureRecognizer(singleTap)
            view.removeGestureRecognizer(doubleTap)
            onTap = {}
        }

        @objc private func tapped() { onTap() }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
