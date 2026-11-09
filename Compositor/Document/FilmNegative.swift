import AppKit

/// Film Negative: a scanned color negative made positive, as a darkroom print makes it. Each pixel's light becomes the
/// film's density (−log10 of it in linear light). Each channel's density is spread between the film's thinnest part (its
/// base, which prints black) and its densest (the highlights, which print white); doing so per channel takes out the
/// orange mask. The result then goes through a print-like curve. Every channel works on its own, so it runs as a curve per
/// channel, as Levels does.
nonisolated struct FilmNegativeSettings: Codable, Equatable, Sendable {
    static let densityRange: ClosedRange<Double> = 0...5
    static let exposureRange: ClosedRange<Double> = -100...100
    static let contrastRange: ClosedRange<Double> = 0...100
    static let colorRange: ClosedRange<Double> = -100...100
    static let pointRange: ClosedRange<Double> = -50...50

    /// Each channel's density (red, green, blue) that prints black: the film base and the thinnest shadows.
    var shadowDensity: [Double] = [0.3, 0.6, 0.9]
    /// Each channel's density that prints white: the densest highlights.
    var highlightDensity: [Double] = [1.7, 2.1, 2.6]
    /// Whether the densities have been measured from a picture yet; a new adjustment measures them as it opens.
    var measured = false
    /// −100…100: brighter or darker, about two stops each way.
    var exposure: Double = 0
    /// 0…100: the print curve's S.
    var contrast: Double = 30
    /// −100…100: warmer (red up, blue down) or cooler.
    var temperature: Double = 0
    /// −100…100: toward magenta (green down) or toward green.
    var tint: Double = 0
    /// −50…50: where black and white fall on the print curve, as Levels' input points.
    var blackPoint: Double = 0
    var whitePoint: Double = 0

    var isValid: Bool {
        shadowDensity.count == 3 && highlightDensity.count == 3
            && zip(shadowDensity, highlightDensity).allSatisfy { shadow, highlight in
                shadow.isFinite && highlight.isFinite && Self.densityRange.contains(shadow)
                    && Self.densityRange.contains(highlight) && highlight > shadow
            }
            && exposure.isFinite && Self.exposureRange.contains(exposure)
            && contrast.isFinite && Self.contrastRange.contains(contrast)
            && temperature.isFinite && Self.colorRange.contains(temperature)
            && tint.isFinite && Self.colorRange.contains(tint)
            && blackPoint.isFinite && Self.pointRange.contains(blackPoint)
            && whitePoint.isFinite && Self.pointRange.contains(whitePoint)
    }

    var normalized: Self {
        var result = self
        let fallback = Self()
        if shadowDensity.count != 3 || highlightDensity.count != 3
            || !zip(shadowDensity, highlightDensity).allSatisfy({ $0.isFinite && $1.isFinite }) {
            result.shadowDensity = fallback.shadowDensity
            result.highlightDensity = fallback.highlightDensity
        }
        for channel in 0..<3 {
            let shadow = min(Self.densityRange.upperBound - 0.05, max(0, result.shadowDensity[channel]))
            result.shadowDensity[channel] = shadow
            result.highlightDensity[channel] = min(Self.densityRange.upperBound, max(shadow + 0.05, result.highlightDensity[channel]))
        }
        result.exposure = ImageAdjustmentPixels.clamp(exposure, Self.exposureRange, 0)
        result.contrast = ImageAdjustmentPixels.clamp(contrast, Self.contrastRange, 30)
        result.temperature = ImageAdjustmentPixels.clamp(temperature, Self.colorRange, 0)
        result.tint = ImageAdjustmentPixels.clamp(tint, Self.colorRange, 0)
        result.blackPoint = ImageAdjustmentPixels.clamp(blackPoint, Self.pointRange, 0)
        result.whitePoint = ImageAdjustmentPixels.clamp(whitePoint, Self.pointRange, 0)
        return result
    }

    /// `input`, one channel of a pixel (0 red, 1 green, 2 blue) as sRGB 0–1, as the print shows it, 0–1.
    func value(_ input: Double, channel: Int) -> Double {
        let encoded = min(1, max(0, input))
        let light = Self.linear(encoded)
        let density = -log10(max(light, 0.00001))
        let span = max(0.05, highlightDensity[channel] - shadowDensity[channel])
        // How far the channel's density sits from black (0) to white (1), in log exposure, as on the print.
        var position = (density - shadowDensity[channel]) / span + exposure * 0.003
        switch channel {
        case 0: position += temperature * 0.0015
        case 1: position -= tint * 0.0015
        default: position -= temperature * 0.0015
        }
        return printed(position)
    }

    /// The print: `position` 0 (black) to 1 (white) as light over two log units, a print's range; then sRGB; then a
    /// gentle S for contrast, which leaves black and white where they are.
    private func printed(_ position: Double) -> Double {
        let black = blackPoint / 200, white = 1 + whitePoint / 200
        let x = (position - black) / (white - black)
        let floor = 0.01
        let light = min(1, max(0, (pow(10, (x - 1) * 2) - floor) / (1 - floor)))
        let encoded = Self.encoded(light)
        let k = 0.01 + contrast * 0.08
        func s(_ t: Double) -> Double { 1 / (1 + exp(-k * (t - 0.5))) }
        return min(1, max(0, (s(encoded) - s(0)) / (s(1) - s(0))))
    }

    static func linear(_ encoded: Double) -> Double {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ linear: Double) -> Double {
        linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }

    func apply(_ image: CGImage) throws -> CGImage {
        guard isValid else { throw ProjectError.invalid }
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let table = (0..<3).flatMap { channel in (0...255).map { Float(value(Double($0) / 255, channel: channel)) } }
        levels_apply(context.data!.assumingMemoryBound(to: UInt8.self), image.width * image.height, table)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    /// The densities measured from `image`, the scan as it is, keeping the other settings.
    mutating func measure(_ image: CGImage) {
        guard let found = Self.densities(in: image) else { return }
        shadowDensity = found.shadow
        highlightDensity = found.highlight
        measured = true
    }

    /// Where the tones of a negative lie: per channel, its thinnest and densest parts, leaving out the frame's edge (the
    /// film holder) and anything the scanner's light came straight through (sprocket holes). The film base is the
    /// thinnest part of the whole picture, edges included, where unexposed film shows; black sits the same fraction of
    /// the way from it to white in every channel, so the shadows come out neutral. Nil for a picture with too little in it.
    static func densities(in image: CGImage) -> (shadow: [Double], highlight: [Double])? {
        // Plenty to find the tones in, and quick.
        let scale = min(1, 800 / Double(max(1, max(image.width, image.height))))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = try? BrushRaster.context(width: width, height: height, mask: false) else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }

        let bins = 1000, densityPerBin = densityRange.upperBound / Double(bins)
        let densityBin = (0...255).map { value -> Int in
            let density = -log10(max(linear(Double(value) / 255), 0.00001))
            return min(bins - 1, Int(density / densityPerBin))
        }
        var inner = Array(repeating: Array(repeating: 0, count: bins), count: 3)
        var whole = inner
        var innerCount = 0, wholeCount = 0
        let marginX = Int(Double(width) * 0.08), marginY = Int(Double(height) * 0.08)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = data + (y * width + x) * 4
                let alpha = Int(pixel[3])
                guard alpha > 0 else { continue }
                let rgb = (0..<3).map { min(255, (Int(pixel[$0]) * 255 + alpha / 2) / alpha) }
                // Light straight through, or none at all (the holder).
                if rgb.allSatisfy({ $0 >= 251 }) || rgb.allSatisfy({ $0 < 2 }) { continue }
                let inside = x >= marginX && x < width - marginX && y >= marginY && y < height - marginY
                for channel in 0..<3 {
                    let bin = densityBin[rgb[channel]]
                    whole[channel][bin] += 1
                    if inside { inner[channel][bin] += 1 }
                }
                wholeCount += 1
                if inside { innerCount += 1 }
            }
        }
        guard innerCount >= 16 else { return nil }

        func percentile(_ histogram: [Int], _ count: Int, _ fraction: Double) -> Double {
            let target = Double(count) * fraction
            var sum = 0
            for (bin, n) in histogram.enumerated() {
                sum += n
                if Double(sum) >= target { return (Double(bin) + 0.5) * densityPerBin }
            }
            return densityRange.upperBound
        }
        let thinnest = (0..<3).map { percentile(inner[$0], innerCount, 0.002) }
        let highlight = (0..<3).map { max(percentile(inner[$0], innerCount, 0.998), thinnest[$0] + 0.05) }
        let base = (0..<3).map { min(thinnest[$0], percentile(whole[$0], wholeCount, 0.0005)) }
        // The median channel's fraction, so one strongly colored subject (a cyan, with almost no red) doesn't pull its
        // channel's black away from the others.
        let fractions = (0..<3).map { max(0, (thinnest[$0] - base[$0]) / max(0.05, highlight[$0] - base[$0])) }.sorted()
        let shadow = (0..<3).map { base[$0] + fractions[1] * (highlight[$0] - base[$0]) }
        var result = Self()
        result.shadowDensity = shadow
        result.highlightDensity = highlight
        result = result.normalized
        return (result.shadowDensity, result.highlightDensity)
    }
}

extension EditorSession {
    /// Film Negative's Measure Again: the densities found afresh from the picture it works on, after a crop or for
    /// another frame.
    func measureFilmNegative() {
        guard let edit = filterEdit, edit.kind == .filmNegative, !edit.committing else { return }
        var settings = edit.settings
        settings.filmNegative.measure(edit.original.image)
        updateFilter(settings, preview: edit.preview)
    }
}
