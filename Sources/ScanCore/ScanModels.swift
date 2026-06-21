import Foundation
import CoreGraphics

/// What a page should be made to look like.
///
/// Six choices rather than twenty. Each one exists because there is a kind of
/// page it is the right answer for, and none of them is another with a slider
/// moved — a list where most entries are near-duplicates makes the user do the
/// comparing, which is the work the scanner is supposed to do for them.
public enum ScanStyle: String, Sendable, CaseIterable, Codable {
    /// Reads the page and chooses. The default, and the one most people should
    /// never need to change.
    case auto
    /// Punchy. Deepens faint marks hard, for handwriting, pencil, carbon
    /// copies, and anything printed feebly.
    case enhanced
    /// Faithful. Paper to white and ink to black without touching what sits
    /// between them, for printed documents that carry photographs or colour.
    case color
    /// Gentle. Corrects the lighting and little else, for originals that are
    /// already clean or too delicate to push.
    case light
    /// Neutral grey, tone preserved.
    case grayscale
    /// Two tones. Smallest files by an order of magnitude, best for printed
    /// text destined for a printer.
    case bitonal
    /// Untouched, as captured.
    case original

    /// Styles offered in the interface, in the order they should appear.
    public static let offered: [ScanStyle] = [.auto, .enhanced, .color, .light, .grayscale, .bitonal]

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .enhanced: "Enhance"
        case .color: "Colour"
        case .light: "Light"
        case .grayscale: "Grey"
        case .bitonal: "Ink"
        case .original: "Photo"
        }
    }
}

/// Tunables for the enhancement pipeline. Defaults are calibrated for a
/// handheld phone capture of a letter/A4 page under mixed indoor light.
///
/// Radii are in pixels at the quarter-scale estimate, which makes them
/// technically resolution-dependent. That was investigated as a suspected cause
/// of poor results on a 12 MP phone capture and the suspicion did not survive
/// measurement: at 4032 px, and again with strokes seven times thicker than the
/// reference fixture, fixed radii scored the same or better than radii scaled
/// to image width. The dependence is real but does not bite at any resolution
/// or stroke weight tested, so the simpler version stands.
public struct EnhancementOptions: Sendable, Codable {
    /// Dilation radius used to erase ink before estimating illumination. Must
    /// exceed the thickest glyph stroke or text bleeds into the illumination
    /// estimate and halos.
    public var inkErasureRadius: Double
    /// Gaussian sigma applied to the dilated plate to smooth residual texture.
    public var illuminationBlurSigma: Double
    /// Post-division contrast stretch, as a fraction of the histogram clipped
    /// at each end.
    public var clipFraction: Double
    /// Saturation multiplier applied after correction, for `.color`.
    ///
    /// 1.05, measured rather than chosen by eye. With the colour path's
    /// gain-only mapping a boost of 1.00 reproduces a printed highlighter at
    /// 0.729 against a true 0.717, so this is a deliberate five percent lift
    /// for a little pop — not the accidental thirty percent the old per-channel
    /// levels map was adding on its own.
    public var saturationBoost: Double

    /// How strongly coloured content is shielded from the paper-whitening
    /// levels, 0...1.
    ///
    /// The levels map is deliberately aggressive: it drives the paper peak to
    /// pure white so a scan reads as a scan. Applied without regard for colour
    /// it also drives anything else that is bright to white, and a yellow
    /// highlighter or a pale coloured table cell is bright. The result is a
    /// block that keeps its edges and loses its fill — hollowed out. Saturated
    /// pixels are content, never paper, so they get a gentler mapping.
    public var colourProtection: Double

    /// How hard marks below paper level are pushed towards black, as a gamma.
    ///
    /// The levels map is global: its black point comes from the darkest ink on
    /// the page, so on a page carrying both ballpoint and pencil the pencil
    /// lands near paper level and stays pale — which is exactly how handwritten
    /// notes come out looking washed. Flat-field correction has already
    /// divided out the lighting, so a pixel's value *is* its darkness relative
    /// to the paper beside it; raising that to a power above one darkens a
    /// faint mark steeply while leaving paper at one untouched.
    ///
    /// 1.0 is no change.
    public var inkGamma: Double

    /// Strength of the S-curve applied after the levels map, 0...1.
    ///
    /// A pure linear map between the ink and paper points leaves a document
    /// looking flat and grey. The S-curve deepens what is nearly ink and lifts
    /// what is nearly paper, which is most of the difference between a
    /// photograph of a page and something that reads as a scan.
    public var toneCurveStrength: Double

    /// Large-radius unsharp amount, which raises contrast between a block of
    /// text and the paper around it rather than at glyph edges. This is what
    /// makes text look present on the page instead of washed into it.
    public var localContrast: Double

    /// Radius of that local-contrast pass, in pixels.
    public var localContrastRadius: Double

    /// Radius of the glyph-edge sharpening pass, in pixels.
    public var sharpenRadius: Double
    /// Unsharp mask intensity. 0 disables sharpening.
    public var sharpenIntensity: Double

    /// The most any pixel may be brightened by the correction.
    ///
    /// In a deep shadow the sensor recorded only a handful of distinct levels,
    /// and dividing by a near-zero illumination estimate stretches those few
    /// levels across the full range — which shows up as banding and, because
    /// each colour channel lands on a different level, as coloured fringing.
    /// Capping the gain admits the honest limit: detail that was never captured
    /// cannot be recovered, and the shadow should stay dark rather than boil.
    ///
    /// 20 is measured, not guessed: on the harness's hard fixture, character
    /// error rate reaches zero at a cap of 8 and stops improving well before
    /// 20, so this bounds a runaway division without costing any accuracy.
    /// Tightening it further does cost accuracy — a heavily shadowed page needs
    /// real amplification to be readable at all.
    public var maximumGain: Double

    public init(
        inkErasureRadius: Double = 12,
        illuminationBlurSigma: Double = 8,
        clipFraction: Double = 0.005,
        saturationBoost: Double = 1.05,
        colourProtection: Double = 1.0,
        inkGamma: Double = 1.0,
        toneCurveStrength: Double = 0.75,
        localContrast: Double = 0.6,
        localContrastRadius: Double = 40,
        sharpenRadius: Double = 2.5,
        sharpenIntensity: Double = 0.5,
        maximumGain: Double = 20
    ) {
        self.inkErasureRadius = inkErasureRadius
        self.illuminationBlurSigma = illuminationBlurSigma
        self.clipFraction = clipFraction
        self.saturationBoost = saturationBoost
        self.colourProtection = colourProtection
        self.inkGamma = inkGamma
        self.toneCurveStrength = toneCurveStrength
        self.localContrast = localContrast
        self.localContrastRadius = localContrastRadius
        self.sharpenRadius = sharpenRadius
        self.sharpenIntensity = sharpenIntensity
        self.maximumGain = maximumGain
    }

    public static let `default` = EnhancementOptions()

    /// The settings that give each style its character.
    ///
    /// Only the values that distinguish a style are named here; everything else
    /// stays at the calibrated default, so a change to the shared pipeline
    /// reaches every style rather than only the one it was measured on.
    public static func preset(for style: ScanStyle) -> EnhancementOptions {
        var options = EnhancementOptions()
        switch style {
        case .enhanced:
            // Faint marks are the whole point: pencil and weak ballpoint sit
            // close to paper level and a linear map leaves them grey.
            options.inkGamma = 2.2
            options.localContrast = 0.85
            options.saturationBoost = 1.12
        case .color, .auto:
            break
        case .light:
            // Lighting corrected, tone left alone. For an original that is
            // already clean, or one whose faint detail matters more than
            // contrast — a pencil sketch, a thermal receipt going grey.
            options.inkGamma = 1.0
            options.toneCurveStrength = 0.25
            options.localContrast = 0.25
            options.saturationBoost = 1.0
        case .grayscale:
            options.inkGamma = 1.5
        case .bitonal:
            // No deepening here. Otsu already picks the ink/paper split from
            // the histogram, and pre-darkening only moves the peaks it is
            // measuring — worth four characters of accuracy on the reference
            // page and nothing in return.
            break
        case .original:
            break
        }
        return options
    }
}

/// One recognised text run with its position on the page.
///
/// `boundingBox` is normalised to the page with the origin at the lower-left,
/// matching Vision's convention, so it can be handed to PDFKit without a flip.
public struct TextRun: Sendable, Codable, Equatable {
    public var text: String
    public var boundingBox: CGRect
    public var confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// A value the document recogniser identified as structured data.
public struct DetectedValue: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case email, phoneNumber, url, postalAddress, calendarEvent, money
        case measurement, flightNumber, shipmentTracking, paymentIdentifier, other
    }
    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }
}

/// A table recovered from the page, as rows of cell strings.
public struct RecognizedTable: Sendable, Codable, Equatable {
    public var rows: [[String]]
    public var boundingBox: CGRect

    public init(rows: [[String]], boundingBox: CGRect) {
        self.rows = rows
        self.boundingBox = boundingBox
    }
}

/// Everything the recognition stage learned about one page.
public struct PageRecognition: Sendable, Codable, Equatable {
    public var transcript: String
    public var runs: [TextRun]
    public var tables: [RecognizedTable]
    public var detected: [DetectedValue]
    public var barcodes: [String]

    public init(
        transcript: String = "",
        runs: [TextRun] = [],
        tables: [RecognizedTable] = [],
        detected: [DetectedValue] = [],
        barcodes: [String] = []
    ) {
        self.transcript = transcript
        self.runs = runs
        self.tables = tables
        self.detected = detected
        self.barcodes = barcodes
    }
}

/// Wall-clock cost of each stage, so regressions surface in the harness
/// instead of in a user's hand.
public struct StageTimings: Sendable, Codable {
    public var enhanceMs: Double = 0
    public var recognizeMs: Double = 0
    public var extractMs: Double = 0
    public var exportMs: Double = 0

    public init() {}

    public var totalMs: Double { enhanceMs + recognizeMs + extractMs + exportMs }
}
