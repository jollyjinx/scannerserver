import Foundation

enum NativeDocumentCommandOptionsError: Error, Equatable {
    case invalidArguments
}

struct NativeRemoveBlankPagesOptions: Equatable, Sendable {
    let pdfPath: String
    var whiteThreshold = 245
    var contentRatioThreshold = 0.003
    var meanThreshold = 248.0
    var keepOne = true
    var debug = false

    init(arguments: [String]) throws {
        guard let pdfPath = arguments.first else {
            throw NativeDocumentCommandOptionsError.invalidArguments
        }
        self.pdfPath = pdfPath

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--white-threshold":
                whiteThreshold = try Self.integer(after: &index, in: arguments)
            case "--content-ratio-threshold":
                contentRatioThreshold = try Self.floatingPoint(after: &index, in: arguments)
            case "--mean-threshold":
                meanThreshold = try Self.floatingPoint(after: &index, in: arguments)
            case "--keep-one":
                keepOne = true
            case "--no-keep-one":
                keepOne = false
            case "--debug":
                debug = true
            default:
                throw NativeDocumentCommandOptionsError.invalidArguments
            }
            index += 1
        }
        guard (0...255).contains(whiteThreshold),
              contentRatioThreshold.isFinite, contentRatioThreshold >= 0,
              meanThreshold.isFinite, meanThreshold >= 0
        else {
            throw NativeDocumentCommandOptionsError.invalidArguments
        }
    }

    private static func integer(after index: inout Int, in arguments: [String]) throws -> Int {
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]) else {
            throw NativeDocumentCommandOptionsError.invalidArguments
        }
        return value
    }

    private static func floatingPoint(
        after index: inout Int,
        in arguments: [String]
    ) throws -> Double {
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]) else {
            throw NativeDocumentCommandOptionsError.invalidArguments
        }
        return value
    }
}

struct NativeCropPDFPagesOptions: Equatable, Sendable {
    let pdfPath: String
    var backgroundDelta = 8
    var borderPixels = 64
    var marginPoints = 12.0
    var maximumWidthRatio = 0.80
    var maximumHeightRatio = 0.80
    var minimumDensity = 0.08
    var keepOriginalBoxes = false
    var debug = false

    init(arguments: [String]) throws {
        guard let pdfPath = arguments.first else {
            throw NativeDocumentCommandOptionsError.invalidArguments
        }
        self.pdfPath = pdfPath

        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--background-delta":
                backgroundDelta = try Self.integer(after: &index, in: arguments)
            case "--border-px":
                borderPixels = try Self.integer(after: &index, in: arguments)
            case "--margin-points":
                marginPoints = try Self.floatingPoint(after: &index, in: arguments)
            case "--max-width-ratio":
                maximumWidthRatio = try Self.floatingPoint(after: &index, in: arguments)
            case "--max-height-ratio":
                maximumHeightRatio = try Self.floatingPoint(after: &index, in: arguments)
            case "--min-density":
                minimumDensity = try Self.floatingPoint(after: &index, in: arguments)
            case "--keep-original-boxes":
                keepOriginalBoxes = true
            case "--debug":
                debug = true
            default:
                throw NativeDocumentCommandOptionsError.invalidArguments
            }
            index += 1
        }
        guard backgroundDelta >= 0,
              borderPixels >= 0,
              marginPoints.isFinite, marginPoints >= 0,
              maximumWidthRatio.isFinite, maximumWidthRatio >= 0,
              maximumHeightRatio.isFinite, maximumHeightRatio >= 0,
              minimumDensity.isFinite, minimumDensity >= 0
        else {
            throw NativeDocumentCommandOptionsError.invalidArguments
        }
    }

    private static func integer(after index: inout Int, in arguments: [String]) throws -> Int {
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]) else {
            throw NativeDocumentCommandOptionsError.invalidArguments
        }
        return value
    }

    private static func floatingPoint(
        after index: inout Int,
        in arguments: [String]
    ) throws -> Double {
        index += 1
        guard index < arguments.count, let value = Double(arguments[index]) else {
            throw NativeDocumentCommandOptionsError.invalidArguments
        }
        return value
    }
}

struct NativeBlankPageDecision: Equatable, Sendable {
    let isBlank: Bool
    let detail: String

    static func evaluate(
        nonwhiteRatio: Double,
        mean: Double,
        options: NativeRemoveBlankPagesOptions
    ) -> Self {
        Self(
            isBlank: nonwhiteRatio < options.contentRatioThreshold
                && mean >= options.meanThreshold,
            detail: String(
                format: "nonwhite=%.5f mean=%.1f",
                locale: Locale(identifier: "en_US_POSIX"),
                nonwhiteRatio,
                mean
            )
        )
    }
}

struct NativeImageBoundingBox: Equatable, Sendable {
    let left: Int
    let top: Int
    let width: Int
    let height: Int

    var right: Int { left + width }
    var bottom: Int { top + height }
}

struct NativePDFBox: Equatable, Sendable {
    let left: Double
    let bottom: Double
    let right: Double
    let top: Double

    var jsonArray: [Double] { [left, bottom, right, top] }
}

struct NativeCropPageDecision: Equatable, Sendable {
    let shouldCrop: Bool
    let widthRatio: Double
    let heightRatio: Double

    static func evaluate(
        image: NativeDocumentImageDimensions,
        boundingBox: NativeImageBoundingBox,
        density: Double,
        options: NativeCropPDFPagesOptions
    ) -> Self {
        let widthRatio = Double(boundingBox.width) / Double(image.width)
        let heightRatio = Double(boundingBox.height) / Double(image.height)
        let isSmallObject = widthRatio <= options.maximumWidthRatio
            || heightRatio <= options.maximumHeightRatio
        return Self(
            shouldCrop: isSmallObject && density >= options.minimumDensity,
            widthRatio: widthRatio,
            heightRatio: heightRatio
        )
    }

    static func cropBox(
        mediaBox: NativePDFBox,
        image: NativeDocumentImageDimensions,
        boundingBox: NativeImageBoundingBox,
        marginPoints: Double
    ) -> NativePDFBox {
        let pageWidth = mediaBox.right - mediaBox.left
        let pageHeight = mediaBox.top - mediaBox.bottom
        let xScale = pageWidth / Double(image.width)
        let yScale = pageHeight / Double(image.height)
        return NativePDFBox(
            left: max(
                mediaBox.left,
                mediaBox.left + Double(boundingBox.left) * xScale - marginPoints
            ),
            bottom: max(
                mediaBox.bottom,
                mediaBox.top - Double(boundingBox.bottom) * yScale - marginPoints
            ),
            right: min(
                mediaBox.right,
                mediaBox.left + Double(boundingBox.right) * xScale + marginPoints
            ),
            top: min(
                mediaBox.top,
                mediaBox.top - Double(boundingBox.top) * yScale + marginPoints
            )
        )
    }
}
