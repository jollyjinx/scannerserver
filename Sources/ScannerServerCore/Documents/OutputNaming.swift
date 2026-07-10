import Foundation

public enum ScanTimestampError: Error, Equatable, Sendable {
    case invalidFormat(String)
}

public struct ScanTimestamp: Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard Self.isValid(rawValue) else {
            throw ScanTimestampError.invalidFormat(rawValue)
        }
        self.rawValue = rawValue
    }

    public init(date: Date, timeZone: TimeZone = .current) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd.HHmmss"
        rawValue = formatter.string(from: date)
    }

    private static func isValid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 17,
              bytes[4] == Character("-").asciiValue,
              bytes[7] == Character("-").asciiValue,
              bytes[10] == Character(".").asciiValue
        else {
            return false
        }

        let digitIndexes = (0..<17).filter { ![4, 7, 10].contains($0) }
        guard digitIndexes.allSatisfy({ bytes[$0].isASCIIDigit }) else {
            return false
        }

        func integer(_ range: Range<Int>) -> Int {
            range.reduce(into: 0) { result, index in
                result = result * 10 + Int(bytes[index] - Character("0").asciiValue!)
            }
        }

        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(secondsFromGMT: 0),
            year: integer(0..<4),
            month: integer(5..<7),
            day: integer(8..<10),
            hour: integer(11..<13),
            minute: integer(13..<15),
            second: integer(15..<17)
        )
        guard let date = components.date else { return false }

        let calendar = Calendar(identifier: .gregorian)
        let resolved = calendar.dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        return resolved.year == components.year
            && resolved.month == components.month
            && resolved.day == components.day
            && resolved.hour == components.hour
            && resolved.minute == components.minute
            && resolved.second == components.second
    }
}

public enum ScanPageNumberError: Error, Equatable, Sendable {
    case mustBePositive(Int)
}

public struct ScanPageNumber: Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) throws {
        guard rawValue > 0 else {
            throw ScanPageNumberError.mustBePositive(rawValue)
        }
        self.rawValue = rawValue
    }

    public var paddedValue: String {
        String(format: "%04d", rawValue)
    }
}

public enum ScanOutputNameError: Error, Equatable, Sendable {
    case pngRequiresPageNumber
    case ocrRequiresPDF
}

public struct ScanOutputName: Hashable, Sendable {
    public enum Format: String, Hashable, Sendable {
        case pdf
        case png
    }

    public let timestamp: ScanTimestamp
    public let format: Format
    public let pageNumber: ScanPageNumber?
    public let isOCR: Bool

    public init(
        timestamp: ScanTimestamp,
        format: Format,
        pageNumber: ScanPageNumber? = nil,
        isOCR: Bool = false
    ) throws {
        guard format != .png || pageNumber != nil else {
            throw ScanOutputNameError.pngRequiresPageNumber
        }
        guard !isOCR || format == .pdf else {
            throw ScanOutputNameError.ocrRequiresPDF
        }
        self.timestamp = timestamp
        self.format = format
        self.pageNumber = pageNumber
        self.isOCR = isOCR
    }

    public var fileName: ScanOutputFileName {
        var value = timestamp.rawValue
        if let pageNumber {
            value += "-page-\(pageNumber.paddedValue)"
        }
        if isOCR {
            value += ".ocr"
        }
        value += ".\(format.rawValue)"
        return ScanOutputFileName(generatedRawValue: value)
    }
}

public enum ScanOutputFileNameError: Error, Equatable, Sendable {
    case invalidComponent(String)
    case unsupportedExtension(String)
}

/// A direct child of the scan output directory that the existing service would expose.
public struct ScanOutputFileName: Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue != ".",
              rawValue != "..",
              !rawValue.contains("/"),
              !rawValue.contains("\0")
        else {
            throw ScanOutputFileNameError.invalidComponent(rawValue)
        }

        let fileExtension = URL(fileURLWithPath: rawValue).pathExtension.lowercased()
        guard fileExtension == "pdf" || fileExtension == "png" else {
            throw ScanOutputFileNameError.unsupportedExtension(fileExtension)
        }
        self.rawValue = rawValue
    }

    init(generatedRawValue: String) {
        rawValue = generatedRawValue
    }
}

public struct PreviewOutputName: Hashable, Sendable {
    public static let directoryName = ".previews"

    public let sourceFileName: ScanOutputFileName

    public init(sourceFileName: ScanOutputFileName) {
        self.sourceFileName = sourceFileName
    }

    public var fileName: String {
        "\(sourceFileName.rawValue).jpg"
    }

    public var relativePath: String {
        "\(Self.directoryName)/\(fileName)"
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool {
        self >= Character("0").asciiValue! && self <= Character("9").asciiValue!
    }
}
