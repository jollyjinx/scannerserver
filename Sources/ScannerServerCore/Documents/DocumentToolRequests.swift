import Foundation

public struct ExternalDocumentToolCommand: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public protocol ExternalDocumentToolRequest: Sendable {
    var command: ExternalDocumentToolCommand { get }
}

public struct RemoveBlankPagesRequest: ExternalDocumentToolRequest, Equatable, Sendable {
    public var pdfPath: String
    public var whiteThreshold: Int
    public var contentRatioThreshold: Double
    public var meanThreshold: Double
    public var keepOne: Bool
    public var debug: Bool

    public init(
        pdfPath: String,
        whiteThreshold: Int = 230,
        contentRatioThreshold: Double = 0.003,
        meanThreshold: Double = 248.0,
        keepOne: Bool = true,
        debug: Bool = false
    ) {
        self.pdfPath = pdfPath
        self.whiteThreshold = whiteThreshold
        self.contentRatioThreshold = contentRatioThreshold
        self.meanThreshold = meanThreshold
        self.keepOne = keepOne
        self.debug = debug
    }

    public var command: ExternalDocumentToolCommand {
        var arguments = [
            pdfPath,
            "--white-threshold", String(whiteThreshold),
            "--content-ratio-threshold", decimal(contentRatioThreshold, defaultValue: 0.003, defaultText: "0.003"),
            "--mean-threshold", decimal(meanThreshold, defaultValue: 248.0, defaultText: "248.0"),
        ]
        if !keepOne {
            arguments.append("--no-keep-one")
        }
        if debug {
            arguments.append("--debug")
        }
        return ExternalDocumentToolCommand(executable: "remove-blank-pages", arguments: arguments)
    }
}

public struct CropPDFPagesRequest: ExternalDocumentToolRequest, Equatable, Sendable {
    public var pdfPath: String
    public var backgroundDelta: Int
    public var borderPixels: Int
    public var marginPoints: Double
    public var maximumWidthRatio: Double
    public var maximumHeightRatio: Double
    public var minimumDensity: Double
    public var keepOriginalBoxes: Bool
    public var debug: Bool

    public init(
        pdfPath: String,
        backgroundDelta: Int = 8,
        borderPixels: Int = 64,
        marginPoints: Double = 1.0,
        maximumWidthRatio: Double = 0.80,
        maximumHeightRatio: Double = 0.80,
        minimumDensity: Double = 0.08,
        keepOriginalBoxes: Bool = false,
        debug: Bool = false
    ) {
        self.pdfPath = pdfPath
        self.backgroundDelta = backgroundDelta
        self.borderPixels = borderPixels
        self.marginPoints = marginPoints
        self.maximumWidthRatio = maximumWidthRatio
        self.maximumHeightRatio = maximumHeightRatio
        self.minimumDensity = minimumDensity
        self.keepOriginalBoxes = keepOriginalBoxes
        self.debug = debug
    }

    public var command: ExternalDocumentToolCommand {
        var arguments = [
            pdfPath,
            "--background-delta", String(backgroundDelta),
            "--border-px", String(borderPixels),
            "--margin-points", decimal(marginPoints, defaultValue: 1.0, defaultText: "1"),
            "--max-width-ratio", decimal(maximumWidthRatio, defaultValue: 0.80, defaultText: "0.80"),
            "--max-height-ratio", decimal(maximumHeightRatio, defaultValue: 0.80, defaultText: "0.80"),
            "--min-density", decimal(minimumDensity, defaultValue: 0.08, defaultText: "0.08"),
        ]
        if keepOriginalBoxes {
            arguments.append("--keep-original-boxes")
        }
        if debug {
            arguments.append("--debug")
        }
        return ExternalDocumentToolCommand(executable: "crop-pdf-pages", arguments: arguments)
    }
}

public struct SetPDFCreatorRequest: ExternalDocumentToolRequest, Equatable, Sendable {
    public var pdfPath: String
    public var creator: String

    public init(pdfPath: String, creator: String = "ScanSnap") {
        self.pdfPath = pdfPath
        self.creator = creator
    }

    public var command: ExternalDocumentToolCommand {
        ExternalDocumentToolCommand(
            executable: "set-pdf-creator",
            arguments: [pdfPath, "--creator", creator]
        )
    }
}

public struct SplitPDFPagesRequest: ExternalDocumentToolRequest, Equatable, Sendable {
    public var pdfPath: String
    public var outputDirectory: String
    public var prefix: ScanTimestamp

    public init(pdfPath: String, outputDirectory: String, prefix: ScanTimestamp) {
        self.pdfPath = pdfPath
        self.outputDirectory = outputDirectory
        self.prefix = prefix
    }

    public var command: ExternalDocumentToolCommand {
        ExternalDocumentToolCommand(
            executable: "split-pdf-pages",
            arguments: [pdfPath, outputDirectory, prefix.rawValue]
        )
    }

    public func outputName(for page: ScanPageNumber) -> ScanOutputFileName {
        ScanOutputFileName(
            generatedRawValue: "\(prefix.rawValue)-page-\(page.paddedValue).pdf"
        )
    }
}

public struct ExportScanImagesRequest: ExternalDocumentToolRequest, Equatable, Sendable {
    public var pdfPath: String
    public var outputDirectory: String
    public var prefix: ScanTimestamp

    public init(pdfPath: String, outputDirectory: String, prefix: ScanTimestamp) {
        self.pdfPath = pdfPath
        self.outputDirectory = outputDirectory
        self.prefix = prefix
    }

    public var command: ExternalDocumentToolCommand {
        ExternalDocumentToolCommand(
            executable: "export-scan-images",
            arguments: [pdfPath, outputDirectory, prefix.rawValue]
        )
    }

    public func outputName(for page: ScanPageNumber) -> ScanOutputFileName {
        ScanOutputFileName(
            generatedRawValue: "\(prefix.rawValue)-page-\(page.paddedValue).png"
        )
    }
}

private func decimal(_ value: Double, defaultValue: Double, defaultText: String) -> String {
    value == defaultValue ? defaultText : String(value)
}
