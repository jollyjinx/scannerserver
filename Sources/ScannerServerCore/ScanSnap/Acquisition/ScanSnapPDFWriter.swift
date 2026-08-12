import Foundation

public struct ScanSnapPDFWriter: Sendable {
    public init() {}

    @concurrent
    public func write(pages: [Data], to outputURL: URL) async throws {
        guard !pages.isEmpty else { throw ScanSnapAcquisitionError.noPages }
        let fileManager = FileManager.default
        guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
            throw ScanSnapAcquisitionError.couldNotWritePDF("could not create \(outputURL.path)")
        }

        do {
            let handle = try FileHandle(forWritingTo: outputURL)
            defer { try? handle.close() }
            var offsets = [UInt64](repeating: 0, count: 3 + pages.count * 3)

            try write("%PDF-1.4\n", to: handle)
            offsets[1] = handle.offsetInFile
            try write("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n", to: handle)
            offsets[2] = handle.offsetInFile
            let kids = pages.indices.map { "\(3 + $0 * 3) 0 R" }.joined(separator: " ")
            try write("2 0 obj\n<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>\nendobj\n", to: handle)

            for (index, jpeg) in pages.enumerated() {
                let dimensions = Self.jpegDimensions(jpeg) ?? (width: 2_480, height: 3_507)
                let widthPoints = Double(dimensions.width) / 300 * 72
                let heightPoints = Double(dimensions.height) / 300 * 72
                let widthText = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), widthPoints)
                let heightText = String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), heightPoints)
                let pageObject = 3 + index * 3
                let contentObject = pageObject + 1
                let imageObject = pageObject + 2
                let content = "q \(widthText) 0 0 \(heightText) 0 0 cm /Im0 Do Q"

                offsets[pageObject] = handle.offsetInFile
                try write(
                    "\(pageObject) 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(widthText) \(heightText)] "
                        + "/Contents \(contentObject) 0 R /Resources << /XObject << /Im0 \(imageObject) 0 R >> >> >>\nendobj\n",
                    to: handle
                )
                offsets[contentObject] = handle.offsetInFile
                try write(
                    "\(contentObject) 0 obj\n<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream\nendobj\n",
                    to: handle
                )
                offsets[imageObject] = handle.offsetInFile
                try write(
                    "\(imageObject) 0 obj\n<< /Type /XObject /Subtype /Image /Width \(dimensions.width) /Height \(dimensions.height) "
                        + "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length \(jpeg.count) >>\nstream\n",
                    to: handle
                )
                try handle.write(contentsOf: jpeg)
                try write("\nendstream\nendobj\n", to: handle)
            }

            let xrefOffset = handle.offsetInFile
            try write("xref\n0 \(offsets.count)\n0000000000 65535 f \n", to: handle)
            for offset in offsets.dropFirst() {
                try write(String(format: "%010llu 00000 n \n", offset), to: handle)
            }
            try write(
                "trailer\n<< /Size \(offsets.count) /Root 1 0 R >>\nstartxref\n\(xrefOffset)\n%%EOF\n",
                to: handle
            )
            try handle.synchronize()
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        } catch {
            try? fileManager.removeItem(at: outputURL)
            if let acquisitionError = error as? ScanSnapAcquisitionError { throw acquisitionError }
            throw ScanSnapAcquisitionError.couldNotWritePDF(error.localizedDescription)
        }
    }

    static func jpegDimensions(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data)
        var index = 0
        while index + 1 < bytes.count {
            guard bytes[index] == 0xFF else {
                index += 1
                continue
            }
            let marker = bytes[index + 1]
            index += 2
            if marker == 0xD8 { continue }
            if marker == 0xC0 || marker == 0xC2 {
                guard index + 7 <= bytes.count else { return nil }
                let height = Int(bytes[index + 3]) << 8 | Int(bytes[index + 4])
                let width = Int(bytes[index + 5]) << 8 | Int(bytes[index + 6])
                return width > 0 && height > 0 ? (width, height) : nil
            }
            if marker == 0xD9 { return nil }
            guard index + 2 <= bytes.count else { return nil }
            let segmentLength = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            guard segmentLength >= 2, index + segmentLength <= bytes.count else { return nil }
            index += segmentLength
        }
        return nil
    }

    private func write(_ text: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data(text.utf8))
    }
}
