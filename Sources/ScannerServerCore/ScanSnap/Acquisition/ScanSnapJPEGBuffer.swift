import Foundation

struct ScanSnapJPEGBuffer: Sendable {
    private(set) var bytes: [UInt8]
    let maximumBytes: Int

    init(bytes: [UInt8] = [], maximumBytes: Int = ScanSnapAcquisitionPacketBuilder.maximumImageBytes) {
        self.bytes = bytes
        self.maximumBytes = maximumBytes
    }

    mutating func append(_ additionalBytes: [UInt8]) throws {
        guard additionalBytes.count <= maximumBytes - bytes.count else {
            throw ScanSnapAcquisitionError.imageTooLarge(maximumBytes: maximumBytes)
        }
        bytes.append(contentsOf: additionalBytes)
    }

    mutating func extractJPEG() throws -> Data? {
        guard let start = marker([0xFF, 0xD8], from: bytes.startIndex) else {
            if bytes.count >= maximumBytes {
                throw ScanSnapAcquisitionError.invalidJPEG
            }
            return nil
        }
        guard let end = marker([0xFF, 0xD9], from: start + 2) else {
            return nil
        }

        let jpeg = Data(bytes[start..<(end + 2)])
        bytes.removeSubrange(bytes.startIndex..<(end + 2))
        return jpeg
    }

    private func marker(_ marker: [UInt8], from start: Int) -> Int? {
        guard marker.count == 2, bytes.count >= start + marker.count else { return nil }
        for index in start...(bytes.count - marker.count) where bytes[index] == marker[0] {
            if bytes[index + 1] == marker[1] { return index }
        }
        return nil
    }
}
