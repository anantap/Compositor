import AppKit
import CoreImage
import Testing
@testable import Compositor

@MainActor
struct FilmNegativeTests {
    static let width = 120, height = 80, rebate = 6

    /// A scan of a color negative, as a film scanner makes it: an unexposed rebate around the frame (the orange base
    /// alone), a gray ramp across the top half, and below it a strongly cyan patch beside a mid gray.
    static func negative() throws -> CGImage {
        let base = [0.25, 0.55, 0.85], gamma = [0.55, 0.60, 0.65]
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let inRebate = x < rebate || x >= width - rebate || y < rebate || y >= height - rebate
                let scene: [Double]
                if y < height / 2 {
                    let t = Double(x - rebate) / Double(width - 2 * rebate - 1)
                    let light = pow(10, log10(0.01) + t * (log10(0.9) - log10(0.01)))
                    scene = [light, light, light]
                } else {
                    scene = x < width / 2 ? [0.003, 0.25, 0.35] : [0.18, 0.18, 0.18]
                }
                for channel in 0..<3 {
                    let density = inRebate ? base[channel]
                        : base[channel] + gamma[channel] * (log10(max(0.0001, scene[channel])) - log10(0.002))
                    let encoded = FilmNegativeSettings.encoded(pow(10, -density))
                    data[(y * width + x) * 4 + channel] = UInt8((encoded * 255).rounded())
                }
                data[(y * width + x) * 4 + 3] = 255
            }
        }
        return try #require(context.makeImage())
    }

    /// Straight RGB of the pixel at `x`, `y`, top row first.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [Int] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let i = (y * image.width + x) * 4
        return (0..<3).map { Int(data[i + $0]) }
    }

    @Test func measuresTheFilmAndPrintsNeutralGrays() throws {
        let scan = try Self.negative()
        var settings = FilmNegativeSettings()
        settings.measure(scan)
        #expect(settings.measured && settings.isValid)
        // The mask: each channel's film is denser than the one before it.
        #expect(settings.shadowDensity[0] < settings.shadowDensity[1] && settings.shadowDensity[1] < settings.shadowDensity[2])

        let positive = try settings.apply(scan)
        var previous = -1
        for x in [10, 30, 60, 90, 109] {
            let rgb = try Self.pixel(positive, x, 20)
            #expect(rgb.max()! - rgb.min()! <= 10, "a gray prints gray: \(rgb) at \(x)")
            #expect(rgb[1] > previous, "lighter in the scene, lighter in the print")
            previous = rgb[1]
        }
        let gray = try Self.pixel(positive, 90, 60)
        #expect(gray.max()! - gray.min()! <= 10 && (100...150).contains(gray[1]), "18% gray prints near the middle: \(gray)")
        // The cyan patch (almost no red) doesn't tint the rest: it stays cyan, the grays above stay gray.
        let cyan = try Self.pixel(positive, 30, 60)
        #expect(cyan[0] < 40 && cyan[2] > 120, "cyan stays cyan: \(cyan)")
    }

    @Test func slidersMoveThePrint() throws {
        let scan = try Self.negative()
        var settings = FilmNegativeSettings()
        settings.measure(scan)
        let plain = try Self.pixel(try settings.apply(scan), 60, 20)
        settings.exposure = 50
        let brighter = try Self.pixel(try settings.apply(scan), 60, 20)
        #expect(brighter[1] > plain[1] + 10)
        settings.exposure = 0
        settings.temperature = 60
        let warmer = try Self.pixel(try settings.apply(scan), 60, 20)
        #expect(warmer[0] > plain[0] && warmer[2] < plain[2])
    }

    @Test func blankPictureKeepsTheDefaults() throws {
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        var settings = FilmNegativeSettings()
        settings.measure(try #require(context.makeImage()))
        #expect(settings == FilmNegativeSettings(), "nothing to measure: light straight through")
    }

    @Test func savesAndValidates() throws {
        var adjustment = LayerAdjustment(kind: .filmNegative)
        adjustment.filmNegative.measure(try Self.negative())
        adjustment.filmNegative.contrast = 55
        #expect(adjustment.isValid)
        let decoded = try JSONDecoder().decode(LayerAdjustment.self, from: try JSONEncoder().encode(adjustment))
        #expect(decoded == adjustment)
        #expect(ProjectManifest.current >= 22)

        var broken = adjustment
        broken.filmNegative.highlightDensity[1] = broken.filmNegative.shadowDensity[1] - 0.1
        #expect(!broken.isValid, "white must be denser than black")
        #expect(broken.filmNegative.normalized.isValid)
        broken.filmNegative.shadowDensity = [1]
        #expect(!broken.isValid)
        #expect(broken.filmNegative.normalized.isValid)
    }

    /// The canvas's GPU drawing matches the export, and a Film Negative layer saves, reopens, and needs version 22.
    @Test func canvasMatchesExportAndSaves() async throws {
        let scan = try Self.negative()
        var adjustment = LayerAdjustment(kind: .filmNegative)
        adjustment.filmNegative.measure(scan)
        adjustment.filmNegative.contrast = 45
        let exported = try adjustment.apply(scan)
        let gpu = try #require(GPUAdjustment.apply(adjustment, to: CIImage(cgImage: scan), scale: 1, mapping: .identity))
        let shown = try #require(PixelAdjust.ciContext.createCGImage(gpu, from: CGRect(x: 0, y: 0, width: Self.width, height: Self.height),
                                                                      format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        for (x, y) in [(30, 20), (60, 20), (90, 20), (30, 60), (90, 60)] {
            let export = try Self.pixel(exported, x, y), canvas = try Self.pixel(shown, x, y)
            #expect(zip(export, canvas).allSatisfy { abs($0 - $1) <= 4 }, "canvas \(canvas) against export \(export) at \(x), \(y)")
        }

        let session = EditorSession()
        session.createDocument(width: Self.width, height: Self.height)
        session.insert(ImportedImage(image: scan, thumbnail: scan, name: "Scan"))
        session.addAdjustment(.filmNegative)
        session.adjustmentEditingID = nil
        session.updateAdjustment(try #require(session.activeLayerID), value: adjustment)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.version >= 22)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FilmNegative-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        #expect(try await ProjectStore.shared.load(from: url).manifest.layers.last?.adjustment == adjustment)
        var older = snapshot.manifest
        older.version = 21
        await #expect(throws: (any Error).self) {
            try await ProjectStore.shared.save(ProjectSnapshot(manifest: older, images: snapshot.images), to: url)
        }
    }

    @Test func isAnImageAdjustmentAndALayer() {
        #expect(AdjustmentKind.imageAdjustments.contains(.filmNegative))
        #expect(AdjustmentKind.filmNegative.filterKind == .filmNegative)
        #expect(FilterKind.filmNegative.isImageAdjustment)
    }
}
