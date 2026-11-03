import Foundation
import SwiftUI
import UIKit

/// Selection uses actual recognized regions, including word-sized boxes.
/// OCRResultsView provides equivalent controls in its accessible text list.
struct OCRSelectionCanvas: UIViewRepresentable {
    let image: UIImage
    let candidates: [OCRCandidate]
    @Binding var selectedIDs: Set<UUID>
    let resetToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> OCRCanvasScrollView {
        let scroll = OCRCanvasScrollView()
        scroll.backgroundColor = .secondarySystemBackground
        scroll.delegate = context.coordinator
        scroll.bouncesZoom = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "ocr.selection.canvas"
        scroll.isAccessibilityElement = true
        scroll.accessibilityLabel = "扫描页识别区域"
        scroll.accessibilityHint = "可双指缩放，也可在下方文字列表中选择。"
        scroll.addSubview(scroll.canvas)
        context.coordinator.scroll = scroll
        scroll.onBoundsChange = { [weak coordinator = context.coordinator] in
            coordinator?.fitPage()
        }
        let press = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.dragSelection(_:)))
        press.minimumPressDuration = 0.35
        press.allowableMovement = 12
        scroll.canvas.addGestureRecognizer(press)
        // A normal swipe fails the long press on movement, then scrolls.
        // Holding first reserves the gesture for continuous text selection.
        scroll.panGestureRecognizer.require(toFail: press)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                        action: #selector(Coordinator.tapSelection(_:)))
        tap.require(toFail: press)
        scroll.canvas.addGestureRecognizer(tap)
        context.coordinator.update(self)
        return scroll
    }

    func updateUIView(_ uiView: OCRCanvasScrollView, context: Context) {
        context.coordinator.update(self)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: OCRSelectionCanvas
        weak var scroll: OCRCanvasScrollView?
        private var imageIdentity: ObjectIdentifier?
        private var lastResetToken: Int?
        private var orderedRegions: [OCRTextRegion] = []
        private var dragAnchor: Int?
        private var selectionBeforeDrag: Set<UUID> = []

        init(parent: OCRSelectionCanvas) { self.parent = parent }

        func update(_ parent: OCRSelectionCanvas) {
            self.parent = parent
            guard let scroll else { return }
            orderedRegions = parent.candidates.flatMap(\.regions)
            let identity = ObjectIdentifier(parent.image)
            let changedImage = imageIdentity != identity
            if changedImage {
                imageIdentity = identity
                scroll.minimumZoomScale = 0.01
                scroll.maximumZoomScale = 16
                scroll.setZoomScale(1, animated: false)
                scroll.canvas.setImage(parent.image)
                scroll.contentSize = parent.image.size
            }
            scroll.canvas.regions = orderedRegions
            scroll.canvas.selectedIDs = parent.selectedIDs
            scroll.canvas.updateOverlays(zoomScale: scroll.zoomScale)
            scroll.accessibilityValue = "已选择 \(parent.selectedIDs.count) 个区域"
            if changedImage || lastResetToken != parent.resetToken {
                lastResetToken = parent.resetToken
                fitPage()
            }
        }

        func fitPage() {
            guard let scroll, scroll.bounds.width > 0, scroll.bounds.height > 0,
                  parent.image.size.width > 0, parent.image.size.height > 0 else { return }
            let fit = min(scroll.bounds.width / parent.image.size.width,
                          scroll.bounds.height / parent.image.size.height)
            scroll.minimumZoomScale = fit
            scroll.maximumZoomScale = max(1, fit * 8)
            scroll.setZoomScale(fit, animated: false)
            centerPage()
            scroll.setContentOffset(CGPoint(x: -scroll.contentInset.left,
                                             y: -scroll.contentInset.top), animated: false)
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { scroll?.canvas }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerPage()
            scroll?.canvas.updateStrokeWidth(zoomScale: scrollView.zoomScale)
        }

        private func centerPage() {
            guard let scroll else { return }
            let horizontal = max(0, (scroll.bounds.width - scroll.contentSize.width) / 2)
            let vertical = max(0, (scroll.bounds.height - scroll.contentSize.height) / 2)
            let inset = UIEdgeInsets(top: vertical, left: horizontal,
                                     bottom: vertical, right: horizontal)
            if scroll.contentInset != inset { scroll.contentInset = inset }
        }

        @objc func tapSelection(_ gesture: UITapGestureRecognizer) {
            guard let scroll, let index = hitIndex(at: gesture.location(in: scroll.canvas),
                                                   allowNearest: false) else { return }
            let id = orderedRegions[index].id
            var selection = parent.selectedIDs
            if selection.contains(id) { selection.remove(id) }
            else { selection.insert(id) }
            parent.selectedIDs = selection
        }

        @objc func dragSelection(_ gesture: UILongPressGestureRecognizer) {
            guard let scroll else { return }
            let point = gesture.location(in: scroll.canvas)
            switch gesture.state {
            case .began:
                guard let anchor = hitIndex(at: point, allowNearest: false) else { return }
                dragAnchor = anchor
                selectionBeforeDrag = parent.selectedIDs
                parent.selectedIDs = selectionBeforeDrag.union([orderedRegions[anchor].id])
                UISelectionFeedbackGenerator().selectionChanged()
            case .changed:
                guard let anchor = dragAnchor,
                      let endpoint = hitIndex(at: point, allowNearest: true) else { return }
                let interval = min(anchor, endpoint)...max(anchor, endpoint)
                parent.selectedIDs = selectionBeforeDrag.union(interval.map { orderedRegions[$0].id })
            case .cancelled, .failed:
                if dragAnchor != nil { parent.selectedIDs = selectionBeforeDrag }
                dragAnchor = nil
            case .ended:
                dragAnchor = nil
            default:
                break
            }
        }

        private func hitIndex(at point: CGPoint, allowNearest: Bool) -> Int? {
            guard let scroll, scroll.canvas.bounds.contains(point), !orderedRegions.isEmpty else { return nil }
            let hits = orderedRegions.indices.filter { index in
                scroll.canvas.frame(for: orderedRegions[index]).contains(point)
            }
            if let smallest = hits.min(by: {
                let a = scroll.canvas.frame(for: orderedRegions[$0])
                let b = scroll.canvas.frame(for: orderedRegions[$1])
                return a.width * a.height < b.width * b.height
            }) { return smallest }
            guard allowNearest else { return nil }
            // Dragging through a gap picks an endpoint; it never invents a box.
            return orderedRegions.indices.min { a, b in
                distanceSquared(point, to: scroll.canvas.frame(for: orderedRegions[a]))
                    < distanceSquared(point, to: scroll.canvas.frame(for: orderedRegions[b]))
            }
        }

        private func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
            let dx = max(rect.minX - point.x, max(0, point.x - rect.maxX))
            let dy = max(rect.minY - point.y, max(0, point.y - rect.maxY))
            return dx * dx + dy * dy
        }
    }
}

final class OCRCanvasScrollView: UIScrollView {
    let canvas = OCRCanvasContentView()
    var onBoundsChange: (() -> Void)?
    private var lastSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        lastSize = bounds.size
        onBoundsChange?()
    }
}

final class OCRCanvasContentView: UIView {
    private let imageView = UIImageView()
    private let unselectedLayer = CAShapeLayer()
    private let selectedLayer = CAShapeLayer()
    var regions: [OCRTextRegion] = []
    var selectedIDs: Set<UUID> = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(imageView)
        imageView.isUserInteractionEnabled = false
        layer.addSublayer(unselectedLayer)
        layer.addSublayer(selectedLayer)
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: UIImage) {
        imageView.image = image
        frame = CGRect(origin: .zero, size: image.size)
        imageView.frame = bounds
    }

    func frame(for region: OCRTextRegion) -> CGRect {
        CGRect(x: CGFloat(region.rect.x) * bounds.width,
               y: CGFloat(region.rect.y) * bounds.height,
               width: CGFloat(region.rect.width) * bounds.width,
               height: CGFloat(region.rect.height) * bounds.height)
    }

    func updateOverlays(zoomScale: CGFloat) {
        let selected = UIBezierPath()
        let unselected = UIBezierPath()
        for region in regions {
            let path = UIBezierPath(rect: frame(for: region))
            if selectedIDs.contains(region.id) { selected.append(path) }
            else { unselected.append(path) }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        unselectedLayer.frame = bounds
        selectedLayer.frame = bounds
        unselectedLayer.path = unselected.cgPath
        unselectedLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        unselectedLayer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.5).cgColor
        selectedLayer.path = selected.cgPath
        selectedLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.3).cgColor
        selectedLayer.strokeColor = UIColor.systemBlue.cgColor
        let width = 1 / max(zoomScale, 0.01)
        unselectedLayer.lineWidth = width
        selectedLayer.lineWidth = width * 1.5
        CATransaction.commit()
    }

    func updateStrokeWidth(zoomScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = 1 / max(zoomScale, 0.01)
        unselectedLayer.lineWidth = width
        selectedLayer.lineWidth = width * 1.5
        CATransaction.commit()
    }
}
