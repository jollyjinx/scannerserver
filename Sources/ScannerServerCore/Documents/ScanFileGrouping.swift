import Foundation

public enum ScanFileVariant: String, Hashable, Sendable {
    case source
    case ocr
    case png

    public var rank: Int {
        switch self {
        case .source: 0
        case .ocr: 1
        case .png: 2
        }
    }
}

public enum ScanFileKind: Hashable, Sendable {
    case sourceScan
    case ocrPDF
    case pngPage(String)
    case pngImage

    public var label: String {
        switch self {
        case .sourceScan: "source scan"
        case .ocrPDF: "OCR PDF"
        case .pngPage(let page): "PNG page \(page)"
        case .pngImage: "PNG image"
        }
    }
}

public struct ScanFile: Hashable, Sendable {
    public let name: ScanOutputFileName
    public let modificationDate: Date

    public init(name: ScanOutputFileName, modificationDate: Date) {
        self.name = name
        self.modificationDate = modificationDate
    }

    public init(name: String, modificationDate: Date) throws {
        self.init(
            name: try ScanOutputFileName(rawValue: name),
            modificationDate: modificationDate
        )
    }

    public var variant: ScanFileVariant {
        if name.rawValue.hasSuffix(".ocr.pdf") {
            return .ocr
        }
        if URL(fileURLWithPath: name.rawValue).pathExtension.lowercased() == "png" {
            return .png
        }
        return .source
    }

    public var variantRank: Int {
        variant.rank
    }

    public var baseName: String {
        switch variant {
        case .ocr:
            return "\(name.rawValue.dropLast(8)).pdf"
        case .png:
            guard let pageMatch = pngPageMatch, name.rawValue.hasSuffix(".png") else {
                return name.rawValue
            }
            return "\(name.rawValue[..<pageMatch.marker.lowerBound]).png"
        case .source:
            return name.rawValue
        }
    }

    public var kind: ScanFileKind {
        switch variant {
        case .source:
            return .sourceScan
        case .ocr:
            return .ocrPDF
        case .png:
            guard let match = pngPageMatch else { return .pngImage }
            let digits = String(name.rawValue[match.digits])
            let normalized = digits.drop(while: { $0 == "0" })
            return .pngPage(normalized.isEmpty ? "0" : String(normalized))
        }
    }

    private var pngPageMatch: (marker: Range<String.Index>, digits: Range<String.Index>)? {
        guard name.rawValue.hasSuffix(".png"),
              let marker = name.rawValue.range(of: "-page-", options: .backwards)
        else {
            return nil
        }
        let extensionStart = name.rawValue.index(name.rawValue.endIndex, offsetBy: -4)
        guard marker.upperBound < extensionStart else { return nil }
        let digits = marker.upperBound..<extensionStart
        guard name.rawValue[digits].allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return nil
        }
        return (marker, digits)
    }
}

public struct ScanFileEntry: Hashable, Sendable {
    public let name: String
    public let kind: ScanFileKind
    public let variant: ScanFileVariant

    public init(file: ScanFile) {
        name = file.name.rawValue
        kind = file.kind
        variant = file.variant
    }
}

public struct ScanDocumentEntry: Hashable, Sendable {
    public let title: String
    public let day: String
    public let files: [ScanFileEntry]
    public let previewName: String
    public let viewName: String
    public let viewKind: ScanFileKind
    public let sortKey: String
}

public struct ScanDayGroup: Hashable, Sendable {
    public let day: String
    public let files: [ScanDocumentEntry]
}

public enum ScanFileGrouping {
    public static func groups(
        for files: [ScanFile],
        timeZone: TimeZone = .current
    ) -> [ScanDayGroup] {
        let grouped = Dictionary(grouping: files, by: \.baseName)
        let entries = grouped.map { baseName, paths in
            documentEntry(baseName: baseName, files: paths, timeZone: timeZone)
        }.sorted { lhs, rhs in
            lhs.sortKey > rhs.sortKey
        }

        var dayGroups: [ScanDayGroup] = []
        for entry in entries {
            if dayGroups.last?.day == entry.day {
                let previous = dayGroups.removeLast()
                dayGroups.append(ScanDayGroup(day: previous.day, files: previous.files + [entry]))
            } else {
                dayGroups.append(ScanDayGroup(day: entry.day, files: [entry]))
            }
        }
        return dayGroups
    }

    public static func day(for file: ScanFile, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEEE, yyyy-MM-dd"

        let name = file.name.rawValue
        if name.count >= 10 {
            let prefix = String(name.prefix(10))
            let parser = DateFormatter()
            parser.calendar = Calendar(identifier: .gregorian)
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = TimeZone(secondsFromGMT: 0)
            parser.dateFormat = "yyyy-MM-dd"
            parser.isLenient = false
            if let date = parser.date(from: prefix), parser.string(from: date) == prefix {
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                return formatter.string(from: date)
            }
        }
        return formatter.string(from: file.modificationDate)
    }

    private static func documentEntry(
        baseName: String,
        files: [ScanFile],
        timeZone: TimeZone
    ) -> ScanDocumentEntry {
        let sorted = files.sorted { lhs, rhs in
            if lhs.variantRank != rhs.variantRank {
                return lhs.variantRank < rhs.variantRank
            }
            return lhs.name.rawValue < rhs.name.rawValue
        }
        let source = sorted.first { $0.variant == .source }
        let ocr = sorted.first { $0.variant == .ocr }
        let png = sorted.first { $0.variant == .png }
        let view = ocr ?? source ?? png ?? sorted[0]
        let dayFile = source ?? png ?? view

        return ScanDocumentEntry(
            title: baseName,
            day: day(for: dayFile, timeZone: timeZone),
            files: sorted.map(ScanFileEntry.init(file:)),
            previewName: view.name.rawValue,
            viewName: view.name.rawValue,
            viewKind: view.kind,
            sortKey: sorted.map(\.name.rawValue).max()!
        )
    }
}
