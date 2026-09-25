import Foundation
import CoreGraphics
import Vision

/// One possible page outline, with the evidence for it.
public struct DocumentCandidate: Sendable {
    public enum Source: String, Sendable {
        case segmentation
        case rectangle
        case textCluster
        /// The whole photo, for a page that fills the frame.
        case frame
    }

    public var quad: DocumentQuad
    public var source: Source
    /// Share of all the print on the page that sits inside this candidate.
    public var textContainment: Double
    public var saliency: Double
    public var score: Double
}

/// Picks which of several rectangles on a page is the one the user means.
///
/// Apple's document segmenter returns a single answer with no alternatives, and
/// on a page lying on other rectangular things it reliably picks the largest —
/// a voucher resting on a ruled notepad comes back as the notepad. Competing
/// scanners get this right consistently, and not by finding edges better: they
/// judge which candidate is *document-like*, which is a semantic question, not
/// a geometric one.
///
/// This approximates that judgement from signals Vision already provides.
/// Printed matter carries dense text and reads as a distinct object; the
/// surface it rests on carries neither, however clean its edges are.
public struct DocumentCandidateSelector: Sendable {

    public struct Weights: Sendable {
        /// Share of all the print on the page that this candidate contains.
        ///
        /// The decisive signal, and it has to be containment rather than
        /// overlap. Measuring how much text a candidate is *covered by* rewards
        /// any small rectangle sitting in a busy area — including the
        /// photograph printed on a voucher, which is what an overlap score
        /// picked on every one of three real photographs. Asking instead which
        /// candidate the print is *on* names the voucher.
        public var textContainment: Double = 1.0
        /// Overlap with what Vision considers a distinct object in the scene.
        /// Useful when there is no print at all; misleading when there is,
        /// because the most salient thing on a voucher is the picture.
        public var saliency: Double = 0.25
        /// Cost per unit of area. With containment, the winner should be the
        /// *smallest* quad holding the print — the page underneath contains it
        /// too, and is twenty times larger.
        public var areaCost: Double = 0.8

        public init() {}
    }

    /// Below this share of the frame a candidate has too few pixels per
    /// character to recognise, whatever else recommends it.
    private static let minimumArea = 0.02
    /// Margin added around the block of print, as a fraction of its own size,
    /// to reach the edge of the page it sits on.
    ///
    /// Chosen by looking at real captures at 0.12, 0.22 and 0.32. At 0.12 the
    /// box clips the card wherever the print stops short of an edge — a corner
    /// marker, a white border. At 0.32 it spills onto the paper underneath.
    /// 0.22 contains the card with a little to spare, and erring wide is the
    /// right way to be wrong: an extra strip of white paper costs nothing,
    /// while a clipped edge loses content the user came for.
    private static let textMargin = 0.22
    /// Below this the segmenter is guessing rather than reporting an edge it
    /// saw. On flat pages that fill the frame it returned shapes cut along a
    /// shadow, at 0.34 to 0.50; around pages lying on something, 0.81 to 0.99.
    private static let confidentSegmentation: Float = 0.7
    /// A sharp edge, in 8-bit grey levels across two pixels of a copy at most
    /// `edgeSampleLength` long: a step of about a sixth of the full range.
    /// Shadow stays far below it, because it changes over many pixels.
    private static let edgeStep = 41
    private static let edgeSampleLength = 512.0
    /// The share of the photo around the print that may lie on a sharp edge
    /// while the photo still shows nothing but the page. Measured: 0.00% on
    /// every flat test page, 1.1% and more on every page photographed lying on
    /// something.
    private static let maximumSurfaceEdges = 0.0025
    /// The least share of a seen outline that the print's own estimate of
    /// its page must cover for the outline to be that page. Measured: 0.62
    /// to 0.66 on pages photographed on a table, 0.27 to 0.31 for a card
    /// lying on a larger sheet.
    private static let minimumPrintCover = 0.5

    public var weights: Weights

    public init(weights: Weights = .init()) {
        self.weights = weights
    }

    /// Counts of each raw signal, for diagnosing a scorer that is silently
    /// running on fewer inputs than it looks like it is.
    public struct SignalCounts: Sendable {
        public var rectangles: Int
        public var hasSegmentation: Bool
        public var textBoxes: Int
        public var salientBoxes: Int
    }

    public func signalCounts(in image: CGImage) async throws -> SignalCounts {
        let signals = try await gatherSignals(in: image)
        return SignalCounts(
            rectangles: signals.rectangles.count,
            hasSegmentation: signals.segmented != nil,
            textBoxes: signals.lines.count,
            salientBoxes: signals.salient.count
        )
    }

    /// Everything the scorer needs, collected once.
    ///
    /// All four detectors run concurrently, so a request costs the slowest of
    /// them rather than their sum.
    private struct Signals {
        var segmented: (quad: DocumentQuad, confidence: Float)?
        var rectangles: [DocumentQuad]
        var lines: [TextLine]
        var salient: [CGRect]

        /// Whether a candidate from `source` is an outline seen in the photo
        /// with confidence: a rectangle, or the segmenter's when it is sure.
        func isSeenOutline(_ source: DocumentCandidate.Source, minimumSegmentation: Float) -> Bool {
            switch source {
            case .rectangle: true
            case .segmentation: (segmented?.confidence ?? 0) >= minimumSegmentation
            case .textCluster, .frame: false
            }
        }

        /// Whether an outline seen in the photo holds every line of print: a
        /// rectangle, or the segmenter's when it is sure of it.
        func hasOutlineHolding(_ text: [CGRect], minimumSegmentation: Float) -> Bool {
            var outlines = rectangles
            if let segmented, segmented.confidence >= minimumSegmentation { outlines.append(segmented.quad) }
            return outlines.contains { outline in
                text.allSatisfy { outline.contains(CGPoint(x: $0.midX, y: $0.midY)) }
            }
        }
    }

    private func gatherSignals(in image: CGImage) async throws -> Signals {
        async let segmented = segmentation(in: image)
        async let rectangles = rectangleCandidates(in: image)
        async let text = textLines(in: image)
        async let salient = salientBoxes(in: image)

        return Signals(
            segmented: try await segmented,
            rectangles: try await rectangles.map(\.0),
            lines: try await text,
            salient: try await salient
        )
    }

    public func candidates(in image: CGImage) async throws -> [DocumentCandidate] {
        let signals = try await gatherSignals(in: image)
        let textBoxes = signals.lines.map(\.boundingBox)

        // The page implied by the print itself.
        //
        // Edge detection never proposed the voucher on any of three real
        // photographs — white card on white paper has almost no gradient to
        // find — so no amount of scoring could pick it. But the print is *on*
        // the card, and its extent is therefore the card's extent. A document
        // carrying text can be located from the text even when its border
        // cannot be seen at all.
        let clustered = signals.lines.isEmpty
            ? nil
            : (enclosingQuad(of: signals.lines), DocumentCandidate.Source.textCluster)

        // Built by appending, not with `??` between concatenations: nil
        // coalescing binds looser than `+`, so the obvious one-expression form
        // silently reduces to "segmentation, or everything else" and discards
        // every other candidate whenever Apple's segmenter succeeds.
        var quads: [(DocumentQuad, DocumentCandidate.Source)] = []
        if let segmented = signals.segmented { quads.append((segmented.quad, .segmentation)) }
        quads += signals.rectangles.map { ($0, .rectangle) }
        if let clustered { quads.append(clustered) }

        let ranked = quads
            .map { score($0.0, source: $0.1, text: textBoxes, salient: signals.salient) }
            .filter { $0.quad.area >= Self.minimumArea }
            .sorted { $0.score > $1.score }

        // The page seen around its print.
        //
        // The print's own estimate of its page reaches a fixed margin past the
        // print, and wins on area whenever the real page reaches further. On a
        // page photographed on a table the segmenter saw the page at 0.99 and
        // its outline held every line, yet the estimate won: it ran onto the
        // table on one side and cut blank paper on the other.
        //
        // So a seen outline — a rectangle, or the segmenter when it is sure —
        // comes first when it holds all the print and the estimate covers at
        // least half of it. The sheet under a card holds the card's print too,
        // but the estimate covers only a small part of it. Where the card's own
        // border cannot be seen, that is the only difference between the two.
        if let clustered, ranked.first?.source == .textCluster,
           let index = ranked.firstIndex(where: { candidate in
               signals.isSeenOutline(candidate.source, minimumSegmentation: Self.confidentSegmentation)
                   && candidate.textContainment == 1
                   && clustered.0.area >= Self.minimumPrintCover * candidate.quad.area
           }) {
            var reordered = ranked
            let page = reordered.remove(at: index)
            return [page] + reordered
        }

        // The page that fills the frame.
        //
        // Every candidate above is a region of the photo, and the area cost
        // ranks them as if whatever lies around them were a table. On a flat
        // page — a screenshot, a scan, a photo taken close — there is no table:
        // the page's edges are the photo's edges. Asked for an outline anyway,
        // the segmenter cut one along a shadow, and the scan lost a fifth to a
        // third of the receipt's characters.
        //
        // So the whole photo comes first when two things hold. No outline seen
        // in the photo holds the print, and the photo around the print shows no
        // edge — not the border of a page, not the lines of a notepad, not the
        // pattern of a rug.
        guard let clustered,
              !signals.hasOutlineHolding(textBoxes, minimumSegmentation: Self.confidentSegmentation),
              let share = edgeShare(in: image, outside: clustered.0),
              share <= Self.maximumSurfaceEdges
        else { return ranked }

        let frame = orient(
            [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0)],
            toReadAlong: readingDirection(of: signals.lines)
        )
        return [score(frame, source: .frame, text: textBoxes, salient: signals.salient)] + ranked
    }

    public func best(in image: CGImage) async throws -> DocumentCandidate? {
        try await candidates(in: image).first
    }

    // MARK: - Scoring

    private func score(
        _ quad: DocumentQuad,
        source: DocumentCandidate.Source,
        text: [CGRect],
        salient: [CGRect]
    ) -> DocumentCandidate {
        // Containment, by the centre of each line of print. A line whose middle
        // falls inside the quad is print on that page.
        let contained = text.filter { quad.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        let containment = text.isEmpty ? 0 : Double(contained.count) / Double(text.count)

        let box = quad.boundingBox
        let area = max(quad.area, 1e-6)
        let salientOverlap = salient
            .map { $0.intersection(box) }
            .filter { !$0.isNull }
            .reduce(0.0) { $0 + Double($1.width * $1.height) }
        let saliency = min(salientOverlap / area, 1)

        // With no print anywhere, containment says nothing and saliency is all
        // there is to go on.
        let total = text.isEmpty
            ? saliency - weights.areaCost * area
            : weights.textContainment * containment
                + weights.saliency * saliency
                - weights.areaCost * area

        return DocumentCandidate(
            quad: quad,
            source: source,
            textContainment: containment,
            saliency: saliency,
            score: total
        )
    }

    // MARK: - Signals

    /// Share of the photo outside `region` that lies on a sharp edge, or nil
    /// when the photo cannot be drawn.
    ///
    /// A page lying on anything shows its own border, and usually the texture
    /// of what is under it. The paper around the print of a flat page has
    /// neither.
    private func edgeShare(in image: CGImage, outside region: DocumentQuad) -> Double? {
        let scale = min(1, Self.edgeSampleLength / Double(max(image.width, image.height)))
        let width = max(Int(Double(image.width) * scale), 3)
        let height = max(Int(Double(image.height) * scale), 3)
        var grey = [UInt8](repeating: 0, count: width * height)
        let drawn = grey.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let limit = Self.edgeStep * Self.edgeStep
        var outside = 0, edges = 0
        for row in 1..<(height - 1) {
            // Row 0 in memory is the top of the photo; Vision's y runs upwards.
            let y = 1 - (Double(row) + 0.5) / Double(height)
            for column in 1..<(width - 1) {
                let x = (Double(column) + 0.5) / Double(width)
                guard !region.contains(CGPoint(x: x, y: y)) else { continue }
                outside += 1
                let index = row * width + column
                let dx = Int(grey[index + 1]) - Int(grey[index - 1])
                let dy = Int(grey[index + width]) - Int(grey[index - width])
                if dx * dx + dy * dy > limit { edges += 1 }
            }
        }
        return outside == 0 ? 0 : Double(edges) / Double(outside)
    }

    private func segmentation(in image: CGImage) async throws -> (quad: DocumentQuad, confidence: Float)? {
        let request = DetectDocumentSegmentationRequest()
        guard let observation = try await ImageRequestHandler(image).perform(request) else { return nil }
        return (DocumentQuad(
            topLeft: observation.topLeft.cgPoint,
            topRight: observation.topRight.cgPoint,
            bottomRight: observation.bottomRight.cgPoint,
            bottomLeft: observation.bottomLeft.cgPoint
        ), observation.confidence)
    }

    private func rectangleCandidates(in image: CGImage) async throws -> [(DocumentQuad, DocumentCandidate.Source)] {
        var request = DetectRectanglesRequest()
        // Deliberately permissive. The point is to gather alternatives for the
        // scorer to choose between, not to be right on the first guess.
        request.maximumObservations = 12
        request.minimumConfidence = 0.25
        request.minimumSize = 0.05
        request.minimumAspectRatio = 0.2
        request.maximumAspectRatio = 1.0
        request.quadratureToleranceDegrees = 35

        return try await ImageRequestHandler(image).perform(request).map { observation in
            (DocumentQuad(
                topLeft: observation.topLeft.cgPoint,
                topRight: observation.topRight.cgPoint,
                bottomRight: observation.bottomRight.cgPoint,
                bottomLeft: observation.bottomLeft.cgPoint
            ), .rectangle)
        }
    }

    /// The tightest rectangle of any orientation enclosing every line of print,
    /// with a margin.
    ///
    /// Found by rotating calipers over the convex hull rather than by averaging
    /// the text's angle. Averaging assumes all the print runs one way, and on
    /// this voucher it does not — the headline runs along the card and the
    /// serial number runs across it. The mean of two perpendicular directions
    /// is a direction that matches neither, and the box came out skewed against
    /// the card on every photograph. A minimum-area rectangle needs no angle
    /// estimate at all: it tries every edge of the hull and keeps the best.
    private func enclosingQuad(of lines: [TextLine]) -> DocumentQuad {
        let points = lines.flatMap { [$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft] }
        let hull = convexHull(of: points)
        guard hull.count >= 3 else { return DocumentQuad(
            topLeft: .zero, topRight: .zero, bottomRight: .zero, bottomLeft: .zero
        ) }

        var best: (area: Double, corners: [CGPoint])?

        for i in hull.indices {
            let a = hull[i], b = hull[(i + 1) % hull.count]
            let angle = atan2(Double(b.y - a.y), Double(b.x - a.x))

            let rotated = points.map { rotate($0, by: -angle) }
            let minX = rotated.map(\.x).min() ?? 0, maxX = rotated.map(\.x).max() ?? 0
            let minY = rotated.map(\.y).min() ?? 0, maxY = rotated.map(\.y).max() ?? 0
            let area = Double((maxX - minX) * (maxY - minY))

            if best == nil || area < best!.area {
                let padX = (maxX - minX) * CGFloat(Self.textMargin)
                let padY = (maxY - minY) * CGFloat(Self.textMargin)
                best = (area, [
                    CGPoint(x: minX - padX, y: maxY + padY),
                    CGPoint(x: maxX + padX, y: maxY + padY),
                    CGPoint(x: maxX + padX, y: minY - padY),
                    CGPoint(x: minX - padX, y: minY - padY),
                ].map { rotate($0, by: angle) })
            }
        }

        let corners = best?.corners ?? []
        guard corners.count == 4 else {
            return DocumentQuad(topLeft: .zero, topRight: .zero, bottomRight: .zero, bottomLeft: .zero)
        }
        return orient(corners, toReadAlong: readingDirection(of: lines))
    }

    /// The direction the text runs, weighted by line length.
    ///
    /// Longer lines are more reliable indicators of the reading direction than
    /// a stray short one, and on this voucher the body text is much longer than
    /// the serial number printed across it.
    private func readingDirection(of lines: [TextLine]) -> CGVector {
        var dx = 0.0, dy = 0.0
        for line in lines {
            let vx = Double(line.topRight.x - line.topLeft.x)
            let vy = Double(line.topRight.y - line.topLeft.y)
            let length = hypot(vx, vy)
            dx += vx * length
            dy += vy * length
        }
        return CGVector(dx: dx, dy: dy)
    }

    /// Relabels the rectangle's corners so the rectified page comes out with its
    /// text upright.
    ///
    /// A minimum-area rectangle has no inherent top. Without this the crop is
    /// whatever orientation the card happened to be lying in — a portrait
    /// voucher photographed sideways came out as a landscape page with the
    /// text running bottom to top, which is unreadable without turning the
    /// phone.
    private func orient(_ corners: [CGPoint], toReadAlong direction: CGVector) -> DocumentQuad {
        // Which edge of the rectangle best matches the direction the text runs.
        var bestIndex = 0
        var bestAlignment = -Double.infinity
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            let edge = CGVector(dx: Double(b.x - a.x), dy: Double(b.y - a.y))
            let length = hypot(edge.dx, edge.dy)
            guard length > 0 else { continue }
            let alignment = (edge.dx * direction.dx + edge.dy * direction.dy) / length
            if alignment > bestAlignment {
                bestAlignment = alignment
                bestIndex = i
            }
        }

        let ordered = (0..<4).map { corners[(bestIndex + $0) % 4] }
        return DocumentQuad(
            topLeft: ordered[0], topRight: ordered[1],
            bottomRight: ordered[2], bottomLeft: ordered[3]
        )
    }

    private func rotate(_ point: CGPoint, by theta: Double) -> CGPoint {
        CGPoint(
            x: CGFloat(Double(point.x) * cos(theta) - Double(point.y) * sin(theta)),
            y: CGFloat(Double(point.x) * sin(theta) + Double(point.y) * cos(theta))
        )
    }

    /// Andrew's monotone chain, counter-clockwise.
    private func convexHull(of points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard sorted.count >= 3 else { return sorted }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        func build(_ input: [CGPoint]) -> [CGPoint] {
            var chain: [CGPoint] = []
            for point in input {
                while chain.count >= 2, cross(chain[chain.count - 2], chain[chain.count - 1], point) <= 0 {
                    chain.removeLast()
                }
                chain.append(point)
            }
            return chain
        }
        return build(sorted).dropLast() + build(sorted.reversed()).dropLast()
    }

    struct TextLine {
        var topLeft: CGPoint
        var topRight: CGPoint
        var bottomRight: CGPoint
        var bottomLeft: CGPoint
        var boundingBox: CGRect
    }

    private func textLines(in image: CGImage) async throws -> [TextLine] {
        // `RecognizeDocumentsRequest`, not either text detector.
        //
        // `DetectTextRectanglesRequest` returned nothing on real photographs of
        // a printed voucher, and `RecognizeTextRequest` at its fast level
        // returned nothing either — the type is small and lying on its side,
        // and neither handles that. The document reader finds it: a hundred and
        // twenty-five characters off the same file. It costs more than a
        // detector, but this runs once per imported photo rather than per
        // frame, and a signal that reports zero is worth nothing at any price.
        let request = RecognizeDocumentsRequest()
        let observations = try await ImageRequestHandler(image).perform(request)
        guard let document = observations.first?.document else { return [] }

        return document.text.lines.map { line in
            let xs = [line.topLeft.x, line.topRight.x, line.bottomLeft.x, line.bottomRight.x]
            let ys = [line.topLeft.y, line.topRight.y, line.bottomLeft.y, line.bottomRight.y]
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            return TextLine(
                topLeft: line.topLeft.cgPoint,
                topRight: line.topRight.cgPoint,
                bottomRight: line.bottomRight.cgPoint,
                bottomLeft: line.bottomLeft.cgPoint,
                boundingBox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            )
        }
    }

    private func salientBoxes(in image: CGImage) async throws -> [CGRect] {
        let request = GenerateObjectnessBasedSaliencyImageRequest()
        let observation = try await ImageRequestHandler(image).perform(request)
        return observation.salientObjects.map { object in
            let xs = [object.topLeft.x, object.topRight.x, object.bottomLeft.x, object.bottomRight.x]
            let ys = [object.topLeft.y, object.topRight.y, object.bottomLeft.y, object.bottomRight.y]
            let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
            let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }
}
