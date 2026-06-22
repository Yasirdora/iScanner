import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import ScanCore

/// Removes shadows and uneven lighting from a document photograph, then
/// restores contrast — the effect competitors market as "Magic Color".
///
/// The pipeline is flat-field correction. We estimate the page's illumination
/// by erasing the ink, then divide the original by that estimate:
///
///     C(x,y) = I(x,y) * mean(F) / F(x,y)
///
/// Dividing by the illumination cancels it, and rescaling by the plate's mean
/// puts the result back at the original exposure.
///
/// The ink is erased with a morphological dilation rather than a blur. A blur
/// is contaminated by the dark ink it is trying to ignore, so it leaves a bright
/// halo around every glyph. A max filter with a radius wider than the thickest
/// stroke removes ink outright, and the plate stays clean.
public struct DocumentEnhancer: Sendable {

    /// Illumination is estimated at reduced resolution. The plate is smooth by
    /// construction, so the detail is wasted, and dilation is superlinear in
    /// radius — this is both faster and slightly better conditioned.
    private static let estimateScale: Double = 0.25

    /// Smallest post-correction dynamic range that justifies a contrast stretch.
    /// Ink on paper spans far more than this; noise on a blank page does not.
    private static let minimumStretchRange: Double = 0.10

    /// How far below the paper's peak the white point is set. The paper's own
    /// tonal spread then clips to pure white instead of landing just under it.
    private static let paperHeadroom: Double = 0.06

    /// Multiplier turning the chroma difference into a mask that saturates
    /// across the range a printed colour actually occupies. Chroma from a
    /// highlighter is a small fraction of full scale, so it needs lifting
    /// before it can act as a selector.
    private static let colourMaskGain: Double = 14

    /// Reach, as a fraction of image width, over which surrounding paper is
    /// gathered to fill a coloured region.
    ///
    /// It has to reach the middle of the block, not just its rim, or the centre
    /// is filled mostly from itself and washes out. Swept from 0.06 to 0.34:
    /// the centre of a block spanning two thirds of the page holds its colour
    /// from 0.16 upward, and nothing improves past that. The smallest value
    /// that works is the right one — a wider blur has more chance of smearing
    /// the lighting it is trying to measure.
    private static let colourFillRadius: Double = 0.16

    /// Share of a page that must carry chroma before it is treated as a colour
    /// document, where faithful reproduction matters more than punch.
    private static let colourfulPageThreshold: Double = 0.06
    /// Share of a page's marks that must be faint before the punchy style is
    /// chosen. Below this the page is mostly solid ink and needs no deepening.
    private static let faintInkThreshold: Double = 0.45

    /// Neighbourhood, as a fraction of image width, over which continuous tone
    /// is judged. Wide enough that a paragraph of text averages out to paper
    /// rather than reading as midtone.
    private static let toneProbeRadius: Double = 0.012
    /// Midtone band treated as photographic rather than as paper or ink.
    private static let toneBandLow: Double = 0.20
    private static let toneBandHigh: Double = 0.88
    private static let toneBandEdge: Double = 0.12


    private let context: CIContext

    public init(context: CIContext? = nil) {
        // Gamma-encoded sRGB, not linear light. Strictly, illumination is
        // multiplicative in linear light, so linear is the physically correct
        // space for the division. But every tonal decision after it — the
        // contrast stretch, Otsu's threshold — is about perceived lightness,
        // and those are only meaningful in a display-referred space. Running
        // one pipeline in sRGB keeps the thresholds honest and matches how the
        // 8-bit capture was encoded in the first place. The division still
        // holds: a max-filtered plate dominates the page pointwise in either
        // space, so the quotient stays in range.
        self.context = context ?? CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            .cacheIntermediates: false,
        ])
    }

    /// Applies a style, using that style's own calibrated settings.
    public func enhance(_ input: CGImage, style: ScanStyle) throws -> CGImage {
        let resolved = style == .auto ? try chooseStyle(for: input) : style
        return try enhance(input, style: resolved, options: .preset(for: resolved))
    }

    public func enhance(
        _ input: CGImage,
        style: ScanStyle,
        options: EnhancementOptions
    ) throws -> CGImage {
        guard style != .original else { return input }

        let source = CIImage(cgImage: input)
        let corrected = flatFieldCorrect(source, options: options)

        switch style {
        case .original:
            return input

        // Auto is resolved before it reaches here by the single-argument entry
        // point; a caller supplying explicit settings gets the faithful path
        // rather than having the page analysed behind their back.
        case .auto, .color, .enhanced:
            // Two tone maps, chosen per pixel. The aggressive one turns paper
            // white; the gentle one leaves bright colour intact. A mask decides
            // which applies where, so a highlighter keeps its fill while the
            // paper around it still goes to true white.
            //
            // Both read the same histogram, so it is measured once. Each
            // measurement costs a full render and a read back from the GPU.
            let levels = try histogram(of: corrected)
            let aggressive = boostLocalContrast(
                applyDocumentTone(corrected, levels: levels, options: options),
                options: options
            )
            let gentle = applyGentleTone(corrected, levels: levels, options: options)
            let merged = protectContent(
                aggressive: aggressive,
                gentle: gentle,
                reference: corrected,
                paperLevel: paperWhitePoint(levels),
                strength: options.colourProtection
            )
            let saturated = applySaturation(merged, amount: options.saturationBoost)
            return try render(sharpen(saturated, options: options), like: source)

        case .light:
            // Lighting corrected, tone barely touched. Nothing is pushed toward
            // black, so faint detail survives that the other styles would
            // deepen past legibility.
            let toned = applyDocumentTone(corrected, levels: try histogram(of: corrected), options: options)
            return try render(sharpen(toned, options: options), like: source)

        case .grayscale:
            let mono = desaturate(corrected)
            let toned = applyDocumentTone(mono, levels: try histogram(of: mono), options: options)
            let contrasted = boostLocalContrast(toned, options: options)
            return try render(sharpen(contrasted, options: options), like: source)

        case .bitonal:
            let mono = desaturate(corrected)
            let toned = applyDocumentTone(mono, levels: try histogram(of: mono), options: options)
            let threshold = try otsuThreshold(toned)
            return try render(binarize(toned, threshold: threshold), like: source)
        }
    }

    // MARK: - Choosing a style

    /// Reads the page and picks the style that suits it.
    ///
    /// Three questions decide it, in order of how much they change the result:
    /// does the page carry colour worth preserving, and how much of its ink is
    /// faint enough to be lost by a linear mapping. A page of pencil notes and
    /// a printed colour brochure want opposite treatments, and asking the user
    /// to know that is asking them to do the scanner's job.
    public func chooseStyle(for input: CGImage) throws -> ScanStyle {
        let source = CIImage(cgImage: input)
        let corrected = flatFieldCorrect(source, options: .default)
        let levels = try histogram(of: corrected)
        let paper = paperWhitePoint(levels)

        // Ink that sits close to the paper: pencil, weak ballpoint, faded
        // toner. This is what a linear map leaves grey.
        let faintRange = (Int(0.45 * paper * 255)...Int(0.92 * paper * 255))
        let bins = levels.count
        var faint = 0.0, marked = 0.0
        for bin in 0..<bins {
            let level = Double(bin) / Double(bins - 1)
            guard level < paper * 0.97 else { continue }
            marked += levels[bin]
            if faintRange.contains(Int(level * 255)) { faint += levels[bin] }
        }

        let colour = measureColourPresence(corrected)

        if colour >= Self.colourfulPageThreshold {
            return .color
        }
        if marked > 0, faint / marked >= Self.faintInkThreshold {
            return .enhanced
        }
        return .color
    }

    /// Share of the page carrying enough chroma to be worth preserving.
    private func measureColourPresence(_ image: CIImage) -> Double {
        let mask = saturationMask(of: image, gain: Self.colourMaskGain)
        return Double(averageLuminance(of: mask, extent: image.extent))
    }

    // MARK: - Diagnostics

    /// The pipeline's intermediate images, for inspection.
    ///
    /// Enhancement failures are rarely legible in the final page — a hollowed
    /// highlight looks like a tone problem and is actually an illumination
    /// problem. Being able to look at the plate and the mask that produced it
    /// is the difference between fixing the cause and guessing at the symptom.
    public struct Intermediates {
        public var colourMask: CGImage
        /// Where the gentle mapping is used instead of the paper-whitening one.
        /// White means "protected content"; a filter that seems to do nothing
        /// is usually a mask that is white where it should be black.
        public var contentMask: CGImage
        public var suppressed: CGImage
        public var plate: CGImage
        public var corrected: CGImage
    }

    public func intermediates(
        _ input: CGImage,
        options: EnhancementOptions = .default
    ) throws -> Intermediates {
        let source = CIImage(cgImage: input)
        return Intermediates(
            colourMask: try render(saturationMask(of: source, gain: Self.colourMaskGain), like: source),
            contentMask: try render({
                let corrected = flatFieldCorrect(source, options: options)
                let levels = (try? histogram(of: corrected)) ?? []
                return contentMask(
                    of: corrected,
                    paperLevel: levels.isEmpty ? 1 : paperWhitePoint(levels),
                    strength: options.colourProtection
                )
            }(), like: source),
            suppressed: try render(suppressColour(in: source), like: source),
            plate: try render(illuminationPlate(for: source, options: options), like: source),
            corrected: try render(flatFieldCorrect(source, options: options), like: source)
        )
    }

    // MARK: - Flat-field correction

    /// Estimates illumination and divides it out. See the type's documentation
    /// for the equation.
    func flatFieldCorrect(_ image: CIImage, options: EnhancementOptions) -> CIImage {
        let rawPlate = illuminationPlate(for: image, options: options)
        let mean = averageLuminance(of: rawPlate, extent: image.extent)

        // Floor the plate so no pixel can be brightened by more than the gain
        // cap. Without this, the core of a cast shadow divides by something
        // close to zero and the two or three levels the sensor actually
        // recorded there get stretched across the whole range.
        let floorLevel = mean / max(options.maximumGain, 1)
        let plate = rawPlate.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: floorLevel, y: floorLevel, z: floorLevel, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])

        // Divide blend computes background / foreground, so the page goes in as
        // the background and the illumination estimate as the foreground.
        let divide = CIFilter.divideBlendMode()
        divide.inputImage = plate
        divide.backgroundImage = image
        guard let divided = divide.outputImage else { return image }

        // Division normalises the page to white. Rescale by the plate's mean so
        // the result keeps the original overall exposure rather than clipping.
        let scaled = divided.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: mean, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: mean, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: mean, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])

        // Note on deep shadows: where the plate is very dark the sensor
        // resolved only a few levels, and dividing spreads those across the
        // range as banding. Fading the correction out there was tried and
        // reverted — on a heavily shadowed page the unrecoverable regions and
        // the regions that most need correcting are the same pixels, and
        // backing off cost roughly thirty points of character accuracy to
        // remove an artifact that is mostly cosmetic. Accuracy wins. The floor
        // above still bounds how far a dead pixel can be pushed.
        return scaled.cropped(to: image.extent)
    }

    /// Builds the "fake flat field": the page as it would look with no ink on it.
    ///
    /// Coloured content is suppressed before the estimate is taken. The plate is
    /// found with a max filter, and a max filter cannot tell a bright colour
    /// from bright lighting — so a yellow highlight, brighter than the paper
    /// around it, was being read as illumination and divided away. Anything
    /// wider than the filter's reach lost its whole interior and kept only the
    /// edge where the filter could still see paper: a hollow block with an
    /// outline, which is precisely what a highlighter came out as.
    ///
    /// Illumination is achromatic; printed colour is not. Replacing saturated
    /// pixels with their minimum channel makes them the darkest thing around,
    /// so the max filter reaches past them to the real paper on either side.
    /// Neutral areas are untouched, which keeps the per-channel division doing
    /// its other job of neutralising a colour cast.
    private func illuminationPlate(for image: CIImage, options: EnhancementOptions) -> CIImage {
        let s = Self.estimateScale
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))

        // Clamp first: morphology and blur both read outside the extent, and the
        // default transparent-black edge would darken the plate at the margins,
        // which the division would then blow out to pure white.
        let clamped = small.clampedToExtent()

        // Ink first, then colour. The colour fill gathers paper from around a
        // coloured region, and text printed over that region counts as
        // neighbouring paper until the dilation has removed it — filling from
        // ink drags the plate dark exactly where the highlight is, and the
        // division then blows the block out to white. Erasing the ink first
        // leaves the fill nothing but paper to draw on.
        let dilate = CIFilter.morphologyMaximum()
        dilate.inputImage = clamped
        dilate.radius = Float(options.inkErasureRadius * s)
        guard let dilated = dilate.outputImage?.cropped(to: small.extent) else { return image }

        let filled = suppressColour(in: dilated)

        let blur = CIFilter.gaussianBlur()
        blur.inputImage = filled.clampedToExtent()
        blur.radius = Float(options.illuminationBlurSigma * s)
        guard let blurred = blur.outputImage else { return image }

        return blurred
            .cropped(to: small.extent)
            .transformed(by: CGAffineTransform(scaleX: 1 / s, y: 1 / s))
            .cropped(to: image.extent)
    }

    /// Replaces coloured regions with the paper that surrounds them.
    ///
    /// Darkening them instead was tried and simply inverted the fault: the
    /// plate then held a dark patch where the highlight was, the division
    /// brightened that patch instead of erasing it, and the block came out
    /// hollow all the same. The plate must not contain the content at any
    /// brightness — it needs the paper level that would have been there.
    ///
    /// This is normalised convolution. Blurring the page weighted by "how
    /// paper-like is this pixel", then dividing by the same blur of the weights
    /// alone, spreads the surrounding paper across the hole in proportion to
    /// how close and how confident each contributing pixel was. Both blurs and
    /// the division are stock filters, and the quotient cannot exceed one
    /// because the numerator is the denominator scaled by pixel values, so the
    /// divide blend's clamp never bites.
    private func suppressColour(in image: CIImage) -> CIImage {
        let mask = saturationMask(of: image, gain: Self.colourMaskGain)
        let paperConfidence = mask.applyingFilter("CIColorInvert")

        let weighted = CIFilter.multiplyBlendMode()
        weighted.inputImage = image
        weighted.backgroundImage = paperConfidence
        guard let weightedImage = weighted.outputImage else { return image }

        let radius = Float(Double(image.extent.width) * Self.colourFillRadius)
        let numerator = blur(weightedImage, radius: radius, within: image.extent)
        let denominator = blur(paperConfidence, radius: radius, within: image.extent)

        let divide = CIFilter.divideBlendMode()
        divide.inputImage = denominator
        divide.backgroundImage = numerator
        guard let filled = divide.outputImage else { return image }

        let substitute = CIFilter.blendWithMask()
        substitute.inputImage = filled.cropped(to: image.extent)
        substitute.backgroundImage = image
        substitute.maskImage = mask
        return substitute.outputImage ?? image
    }

    private func blur(_ image: CIImage, radius: Float, within extent: CGRect) -> CIImage {
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = image.clampedToExtent()
        filter.radius = radius
        return (filter.outputImage ?? image).cropped(to: extent)
    }

    // MARK: - Tone

    private func desaturate(_ image: CIImage) -> CIImage {
        // Rec. 709 luma. CIColorControls' saturation would also work, but an
        // explicit matrix keeps the weights visible and the result predictable.
        image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    private func applySaturation(_ image: CIImage, amount: Double) -> CIImage {
        let controls = CIFilter.colorControls()
        controls.inputImage = image
        controls.saturation = Float(amount)
        controls.brightness = 0
        controls.contrast = 1
        return controls.outputImage ?? image
    }

    private func sharpen(_ image: CIImage, options: EnhancementOptions) -> CIImage {
        guard options.sharpenIntensity > 0 else { return image }
        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = image
        unsharp.radius = Float(options.sharpenRadius)
        unsharp.intensity = Float(options.sharpenIntensity)
        return unsharp.outputImage ?? image
    }

    /// Maps ink to black and paper to white, then shapes the midtones.
    ///
    /// The white point comes from the **mode** of the upper histogram, not from
    /// a percentile. Percentiles move with how much ink is on the page: a
    /// sparse receipt and a dense contract have their 99.5th percentiles in
    /// different places even when photographed on identical paper, so a
    /// percentile white point makes the same paper come out a different shade
    /// depending on what is printed on it. The paper's peak is where the paper
    /// actually is, and it barely moves.
    func applyDocumentTone(
        _ image: CIImage,
        levels: [Double],
        options: EnhancementOptions
    ) -> CIImage {
        let paper = paperWhitePoint(levels)
        let ink = inkBlackPoint(levels, clip: options.clipFraction)
        let range = paper - ink

        // A page with almost no tonal range is a page with almost no ink — a
        // blank sheet, or a margin. Its remaining variation is sensor noise and
        // whatever the illumination estimate failed to remove, and a full
        // stretch would multiply that by the reciprocal of a very small number
        // and turn a clean blank page into visible banding. Below the minimum,
        // leave the page alone.
        guard range >= Self.minimumStretchRange else { return image }

        let scale = 1.0 / range
        let bias = -ink * scale
        let levelled = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ])

        // Deepen faint marks before the S-curve shapes the midtones.
        let deepened = deepenInk(levelled, gamma: options.inkGamma)
        return applyToneCurve(deepened, strength: options.toneCurveStrength)
    }

    /// A mapping that lifts the page to white without distorting its colours.
    ///
    /// Gain only, no black-point subtraction. Saturation is
    /// `(max - min) / max`, which is invariant under scaling but not under an
    /// offset: subtracting a black point takes the same absolute amount off
    /// every channel, which is a far larger proportion of the smallest one. A
    /// yellow whose blue channel is already low loses most of it and the colour
    /// comes back more vivid than it ever was. Measured on a printed
    /// highlighter, the levels map inflated saturation from 0.72 to 0.94 before
    /// any deliberate boost was applied at all.
    ///
    /// Used only where the page carries colour. Paper and ink still get the
    /// full levels treatment, where an offset is exactly what is wanted.
    func applyGentleTone(
        _ image: CIImage,
        levels: [Double],
        options: EnhancementOptions
    ) -> CIImage {
        let paper = paperWhitePoint(levels)
        guard paper > Self.minimumStretchRange else { return image }

        let gain = 1.0 / paper
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    }

    /// Chooses the gentle mapping wherever the page carries content that the
    /// paper-whitening levels would destroy.
    private func protectContent(
        aggressive: CIImage,
        gentle: CIImage,
        reference: CIImage,
        paperLevel: Double,
        strength: Double
    ) -> CIImage {
        guard strength > 0 else { return aggressive }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = gentle
        blend.backgroundImage = aggressive
        blend.maskImage = contentMask(of: reference, paperLevel: paperLevel, strength: strength)
        return blend.outputImage ?? aggressive
    }

    /// Everything on the page that is neither paper nor ink.
    ///
    /// Saturation alone is not enough. A photograph printed on a document is
    /// often nearly neutral — a cup of coffee is brown and grey — so a
    /// saturation mask leaves it unprotected and the levels crush it to white,
    /// which is exactly what happened to the picture on a scanned voucher.
    /// Continuous tone is the other signal: paper blurs to near white and sparse
    /// text blurs to nearly paper, while a photographic region blurs to a
    /// midtone and stays there.
    private func contentMask(of image: CIImage, paperLevel: Double, strength: Double) -> CIImage {
        let colour = saturationMask(of: image, gain: strength * Self.colourMaskGain)
        let tone = continuousToneMask(of: image, paperLevel: paperLevel)

        // Whichever says "content", wins.
        let combine = CIFilter.lightenBlendMode()
        combine.inputImage = colour
        combine.backgroundImage = tone
        return combine.outputImage ?? colour
    }

    /// 1 where the page holds midtones over a whole neighbourhood, 0 on paper
    /// and on solid ink.
    ///
    /// The band is a fraction of where the paper actually sits, not an absolute
    /// range. Flat-field correction rescales by the illumination plate's mean
    /// so the page keeps its original exposure, which puts the paper of a
    /// normally lit photograph near mid-grey — inside any fixed midtone band.
    /// With absolute thresholds this mask came out white over the entire page,
    /// so every pixel took the gentle mapping and the paper-whitening path
    /// never ran at all. That is why scans of handwriting came out washed.
    private func continuousToneMask(of image: CIImage, paperLevel: Double) -> CIImage {
        let smoothed = desaturate(blur(
            image,
            radius: Float(Double(image.extent.width) * Self.toneProbeRadius),
            within: image.extent
        ))

        // Two clamped ramps multiplied together make a band: rising through the
        // shadows, falling through the highlights, flat across the middle.
        func ramp(scale: Double, bias: Double) -> CIImage {
            smoothed.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
        }

        // Scaled to the page's own paper level, so the band means the same
        // thing whatever exposure the capture had.
        let paper = max(paperLevel, Self.minimumStretchRange)
        let width = Self.toneBandEdge * paper
        let low = Self.toneBandLow * paper
        let high = Self.toneBandHigh * paper
        let rising = ramp(scale: 1 / width, bias: -low / width)
        let falling = ramp(scale: -1 / width, bias: high / width)

        let band = CIFilter.multiplyBlendMode()
        band.inputImage = rising
        band.backgroundImage = falling
        return band.outputImage ?? smoothed
    }

    /// Approximates per-pixel saturation as a greyscale mask.
    ///
    /// The distance from a pixel to its own luminance is its chroma, so
    /// differencing the image against a desaturated copy and collapsing the
    /// result to one channel gives a usable saturation map without a custom
    /// kernel. Paper and black ink sit at zero; a stamp or a highlight does not.
    private func saturationMask(of image: CIImage, gain: Double) -> CIImage {
        let difference = CIFilter.differenceBlendMode()
        difference.inputImage = image
        difference.backgroundImage = desaturate(image)
        guard let chroma = difference.outputImage else { return image }

        let amplified = desaturate(chroma).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
        return amplified.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
    }

    /// Where the paper sits: the tallest histogram bin in the upper range.
    ///
    /// Backed off by a small margin so the paper's own spread lands at or above
    /// pure white rather than straddling it, which is what stops a scan looking
    /// faintly grey.
    private func paperWhitePoint(_ histogram: [Double]) -> Double {
        let n = histogram.count
        let searchFloor = n / 2
        var peakBin = n - 1
        var peakCount = -1.0
        for bin in searchFloor..<n where histogram[bin] > peakCount {
            peakCount = histogram[bin]
            peakBin = bin
        }
        let level = Double(peakBin) / Double(n - 1)
        return max(level - Self.paperHeadroom, Self.minimumStretchRange)
    }

    /// Where the ink sits: a low percentile, which is stable because ink is
    /// always the darkest thing on a page.
    private func inkBlackPoint(_ histogram: [Double], clip: Double) -> Double {
        var cumulative = 0.0
        for bin in histogram.indices {
            cumulative += histogram[bin]
            if cumulative >= clip { return Double(bin) / Double(histogram.count - 1) }
        }
        return 0
    }

    /// Pushes anything below paper level towards black.
    private func deepenInk(_ image: CIImage, gamma: Double) -> CIImage {
        guard gamma > 1.001 else { return image }
        return image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": gamma])
    }

    /// S-curve through the midtones: deepen what is nearly ink, lift what is
    /// nearly paper, leave true mid-grey alone so photographs and stamps on the
    /// page do not posterise.
    private func applyToneCurve(_ image: CIImage, strength: Double) -> CIImage {
        guard strength > 0 else { return image }
        let amount = min(max(strength, 0), 1)
        let lift = 0.10 * amount

        let curve = CIFilter.toneCurve()
        curve.inputImage = image
        curve.point0 = CGPoint(x: 0, y: 0)
        curve.point1 = CGPoint(x: 0.25, y: 0.25 - lift)
        curve.point2 = CGPoint(x: 0.5, y: 0.5)
        curve.point3 = CGPoint(x: 0.75, y: 0.75 + lift)
        curve.point4 = CGPoint(x: 1, y: 1)
        return curve.outputImage ?? image
    }

    /// Raises contrast at the scale of a paragraph rather than a glyph edge.
    ///
    /// A wide, gentle unsharp mask separates blocks of text from the paper
    /// around them. Sharpening at glyph scale is a different job, done later,
    /// and doing only that leaves the page looking crisp but washed out.
    private func boostLocalContrast(_ image: CIImage, options: EnhancementOptions) -> CIImage {
        guard options.localContrast > 0 else { return image }
        let unsharp = CIFilter.unsharpMask()
        unsharp.inputImage = image
        unsharp.radius = Float(options.localContrastRadius)
        unsharp.intensity = Float(options.localContrast)
        return unsharp.outputImage ?? image
    }

    private func binarize(_ image: CIImage, threshold: Double) -> CIImage {
        // A steep linear ramp centred on the threshold, clamped by the output
        // range. Cheaper than a tone curve and produces a hard edge with a
        // one-level transition, which keeps glyph edges from aliasing.
        let slope = 255.0
        let bias = -threshold * slope + 0.5
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: slope, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: slope, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: slope, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ])
    }

    // MARK: - Statistics

    /// Mean luminance of an image, read back as a single pixel.
    private func averageLuminance(of image: CIImage, extent: CGRect) -> Double {
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = extent
        guard let output = average.outputImage else { return 1 }

        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            context.render(
                output,
                toBitmap: buffer.baseAddress!,
                rowBytes: 16,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBAf,
                colorSpace: nil
            )
        }
        let luma = 0.2126 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.0722 * Double(pixel[2])
        // Guard against a fully black plate, which would make the division explode.
        return max(luma, 0.001)
    }

    /// 256-bin luminance histogram, normalised to sum to 1.
    func histogram(of image: CIImage) throws -> [Double] {
        let bins = 256
        let filter = CIFilter.areaHistogram()
        // Division can push values above 1 on specular highlights; the
        // histogram bins only [0,1], so clamp before measuring or that energy
        // lands in the top bin and drags the white point with it.
        let clamped = image.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        filter.inputImage = desaturate(clamped)
        filter.extent = image.extent
        filter.count = bins
        filter.scale = 1
        guard let output = filter.outputImage else {
            throw EnhancementError.histogramUnavailable
        }

        var raw = [Float](repeating: 0, count: bins * 4)
        raw.withUnsafeMutableBytes { buffer in
            context.render(
                output,
                toBitmap: buffer.baseAddress!,
                rowBytes: bins * 16,
                bounds: CGRect(x: 0, y: 0, width: bins, height: 1),
                format: .RGBAf,
                // No colour space: histogram bins are counts, not colours, and
                // colour-managing them would apply a transfer function to the
                // very numbers being measured.
                colorSpace: nil
            )
        }

        var counts = (0..<bins).map { Double(raw[$0 * 4]) }
        let total = counts.reduce(0, +)
        guard total > 0 else { throw EnhancementError.histogramUnavailable }
        for i in counts.indices { counts[i] /= total }
        return counts
    }

    /// Intensity values below which `clip` and above which `clip` of the mass lies.
    private func percentiles(_ histogram: [Double], clip: Double) -> (black: Double, white: Double) {
        let n = histogram.count
        var cumulative = 0.0
        var black = 0.0
        var white = 1.0

        for i in 0..<n {
            cumulative += histogram[i]
            if cumulative >= clip { black = Double(i) / Double(n - 1); break }
        }
        cumulative = 0
        for i in stride(from: n - 1, through: 0, by: -1) {
            cumulative += histogram[i]
            if cumulative >= clip { white = Double(i) / Double(n - 1); break }
        }
        return (black, white)
    }

    /// Otsu's threshold: the split that minimises intra-class variance.
    ///
    /// A global threshold is only defensible because flat-field correction ran
    /// first. On a raw photo the lighting gradient would swamp the ink/paper
    /// separation and this would fail; on a corrected page the histogram is
    /// cleanly bimodal and Otsu lands between the two modes.
    func otsuThreshold(_ image: CIImage) throws -> Double {
        let hist = try histogram(of: image)
        let n = hist.count

        let totalMean = (0..<n).reduce(0.0) { $0 + Double($1) * hist[$1] }
        var weightBackground = 0.0
        var sumBackground = 0.0
        var bestVariance = -1.0
        // A clean bimodal page has no mass between the modes, so every split in
        // that gap scores identically. Taking the first maximiser would pin the
        // threshold against the ink mode and thin every glyph; averaging the
        // ties puts it in the middle of the gap, where it belongs.
        var bestBins: [Int] = [n / 2]

        for i in 0..<n {
            weightBackground += hist[i]
            guard weightBackground > 0 else { continue }
            let weightForeground = 1 - weightBackground
            guard weightForeground > 0 else { break }

            sumBackground += Double(i) * hist[i]
            let meanBackground = sumBackground / weightBackground
            let meanForeground = (totalMean - sumBackground) / weightForeground

            let between = weightBackground * weightForeground
                * (meanBackground - meanForeground) * (meanBackground - meanForeground)
            if between > bestVariance {
                bestVariance = between
                bestBins = [i]
            } else if between == bestVariance {
                bestBins.append(i)
            }
        }

        let mean = Double(bestBins.reduce(0, +)) / Double(bestBins.count)
        return mean / Double(n - 1)
    }

    // MARK: - Rendering

    private func render(_ image: CIImage, like source: CIImage) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cg = context.createCGImage(
            image.cropped(to: source.extent),
            from: source.extent,
            format: .RGBA8,
            colorSpace: space
        ) else {
            throw EnhancementError.renderFailed
        }
        return cg
    }
}

public enum EnhancementError: Error, CustomStringConvertible {
    case histogramUnavailable
    case renderFailed

    public var description: String {
        switch self {
        case .histogramUnavailable: "Could not compute an image histogram."
        case .renderFailed: "Core Image could not render the enhanced page."
        }
    }
}
