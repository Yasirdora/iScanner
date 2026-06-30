import SwiftUI
import UIKit
import VisionKit

/// A scanned page, shown the way a document should be shown.
///
/// Zoomable, and with Apple's Live Text attached so the words on the page can
/// be selected, copied, and looked up, and so telephone numbers, addresses and
/// links are underlined and tappable — the behaviour Notes has, from the same
/// framework.
///
/// The scroll view recomputes its fit on every layout pass rather than only at
/// setup, which is what makes rotation land correctly instead of leaving the
/// page half off-screen at the old zoom.
struct PageViewer: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> ZoomablePageView {
        let view = ZoomablePageView()
        view.display(image)
        return view
    }

    func updateUIView(_ view: ZoomablePageView, context: Context) {
        view.display(image)
    }
}

final class ZoomablePageView: UIScrollView, UIScrollViewDelegate {

    /// How far past fitting the page a reader may zoom. Enough to read the
    /// smallest hand-written note on a full page.
    private static let maximumMagnification: CGFloat = 8

    private let pageView = UIImageView()
    private let liveText = ImageAnalysisInteraction()
    private var analysedImage: UIImage?
    private var lastFittedSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)

        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .systemBackground

        pageView.contentMode = .scaleAspectFit
        pageView.isUserInteractionEnabled = true
        pageView.addInteraction(liveText)
        // Text and the data detectors that underline numbers and links; the
        // subject-lifting and visual look-up types belong to photographs, not
        // to documents.
        liveText.preferredInteractionTypes = [.textSelection, .dataDetectors]
        addSubview(pageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func display(_ image: UIImage) {
        guard pageView.image !== image else { return }
        pageView.image = image
        lastFittedSize = .zero
        setNeedsLayout()
        analyse(image)
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = pageView.image, bounds.width > 0, bounds.height > 0 else { return }

        // Refit whenever the available space changes — which is what a rotation
        // is. Fitting only once at setup leaves the page at a zoom computed for
        // the old bounds, so it lands cropped or adrift after turning the phone.
        if bounds.size != lastFittedSize {
            lastFittedSize = bounds.size
            fit(image)
        }
        centrePage()
    }

    private func fit(_ image: UIImage) {
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        pageView.frame = CGRect(origin: .zero, size: CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        ))
        contentSize = pageView.frame.size

        minimumZoomScale = 1
        maximumZoomScale = Self.maximumMagnification
        zoomScale = 1
    }

    /// Keeps the page in the middle while it is smaller than the viewport,
    /// rather than pinned to a corner.
    private func centrePage() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { pageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centrePage() }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        // Double tap zooms to the tapped point, or back out if already zoomed —
        // the gesture every photo viewer on the platform has.
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: pageView)
        let target = min(maximumZoomScale, 3)
        let size = CGSize(width: bounds.width / target, height: bounds.height / target)
        zoom(to: CGRect(
            x: point.x - size.width / 2, y: point.y - size.height / 2,
            width: size.width, height: size.height
        ), animated: true)
    }

    // MARK: - Live Text

    /// Attaches Live Text once per image.
    ///
    /// Analysis is asynchronous and costs real time on a full-resolution page,
    /// so a re-layout must not start it again — this runs on the image, not on
    /// the layout pass.
    private func analyse(_ image: UIImage) {
        guard analysedImage !== image else { return }
        analysedImage = image

        Task { @MainActor in
            let analyzer = ImageAnalyzer()
            let configuration = ImageAnalyzer.Configuration([.text, .machineReadableCode])
            guard let analysis = try? await analyzer.analyze(image, configuration: configuration),
                  analysedImage === image else { return }
            liveText.analysis = analysis
        }
    }
}
