import CoreGraphics
import ScanCore
import ScanCapture

/// One scanned page: the cleaned image and what was read from it.
public struct ScannedPage: Sendable {
    /// The page, straightened and cleaned in `style`.
    public var image: CGImage

    /// Everything recognition found: the transcript, positioned lines,
    /// tables, detected data such as phone numbers and addresses, and barcodes.
    public var recognition: PageRecognition

    /// Where the page was found in the original photo, normalised with the
    /// origin at the lower left, as Vision reports it.
    ///
    /// `nil` when page finding was off or found nothing. `image` is then the
    /// whole photo, cleaned.
    public var outline: DocumentQuad?

    /// The style that was applied. Never `.auto`: Auto is resolved to the
    /// style it chose.
    public var style: ScanStyle

    public init(image: CGImage, recognition: PageRecognition, outline: DocumentQuad?, style: ScanStyle) {
        self.image = image
        self.recognition = recognition
        self.outline = outline
        self.style = style
    }

    /// The recognised text, in reading order.
    public var text: String { recognition.transcript }

    /// Whether a page was found in the photo and straightened.
    public var wasPageFound: Bool { outline != nil }
}
