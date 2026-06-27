import Foundation
import CoreGraphics
import ScanCore

// Numbers for what a filter actually did to a page.
//
// "The filter looks like it is not working" is not something that can be acted
// on, and neither is "it looks better". These are the quantities that decide
// whether a document scan reads as a scan: how close the paper is to white, how
// close the ink is to black, and how much of the page is neither.

struct PageLevels {
    var paperLevel: Double
    var inkLevel: Double
    var pureWhiteFraction: Double
    var pureBlackFraction: Double
    var midtoneFraction: Double
    var separation: Double

    /// A document is "clean" when the paper is white enough to disappear, the
    /// ink is dark enough to read, and very little sits between them.
    var readsAsAScan: Bool {
        paperLevel >= 0.96 && inkLevel <= 0.14 && midtoneFraction < 0.12
    }
}

func measureLevels(_ image: CGImage) -> PageLevels {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var histogram = [Int](repeating: 0, count: 256)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let luma = 0.2126 * Double(pixels[index])
            + 0.7152 * Double(pixels[index + 1])
            + 0.0722 * Double(pixels[index + 2])
        histogram[Int(luma.rounded())] += 1
    }
    let total = Double(width * height)

    // Paper is the tallest peak in the upper half — where the page's background
    // actually sits, regardless of how much ink is on it.
    let paperBin = (128..<256).max { histogram[$0] < histogram[$1] } ?? 255
    // Ink is a low percentile rather than a peak: a sparse page may have no ink
    // mode worth the name, but it always has a darkest few percent.
    var cumulative = 0
    var inkBin = 0
    for bin in 0..<256 {
        cumulative += histogram[bin]
        if Double(cumulative) / total >= 0.01 { inkBin = bin; break }
    }

    let paper = Double(paperBin) / 255
    let ink = Double(inkBin) / 255
    return PageLevels(
        paperLevel: paper,
        inkLevel: ink,
        pureWhiteFraction: Double(histogram[250...].reduce(0, +)) / total,
        pureBlackFraction: Double(histogram[...12].reduce(0, +)) / total,
        midtoneFraction: Double(histogram[40...215].reduce(0, +)) / total,
        separation: paper - ink
    )
}

func formatLevels(_ label: String, _ levels: PageLevels) -> String {
    String(
        format: "%-12@ paper %.3f  ink %.3f  sep %.3f  white %5.1f%%  black %5.1f%%  mid %5.1f%%  %@",
        label as NSString,
        levels.paperLevel, levels.inkLevel, levels.separation,
        levels.pureWhiteFraction * 100, levels.pureBlackFraction * 100,
        levels.midtoneFraction * 100,
        (levels.readsAsAScan ? "ok" : "FLAT") as NSString
    )
}

/// Mean saturation of the pixels that carry colour.
///
/// Averaged over the whole page this is meaningless — a document is mostly
/// white paper and black ink, both of which are colourless, so any real colour
/// is diluted to nothing. Restricting to pixels that were coloured in the first
/// place measures the thing that matters: whether a stamp, a highlight, or a
/// letterhead survives the filter.
func measureColour(_ image: CGImage, threshold: Double = 0.18) -> (meanSaturation: Double, colouredFraction: Double) {
    let width = image.width
    let height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
        data: &pixels, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var total = 0.0
    var count = 0
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let r = Double(pixels[index]) / 255
        let g = Double(pixels[index + 1]) / 255
        let b = Double(pixels[index + 2]) / 255
        let maximum = max(r, g, b), minimum = min(r, g, b)
        guard maximum > 0 else { continue }
        let saturation = (maximum - minimum) / maximum
        if saturation >= threshold {
            total += saturation
            count += 1
        }
    }
    guard count > 0 else { return (0, 0) }
    return (total / Double(count), Double(count) / Double(width * height))
}
