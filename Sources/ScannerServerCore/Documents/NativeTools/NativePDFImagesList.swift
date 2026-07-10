import Foundation

struct NativePDFImagesListRow: Equatable, Sendable {
    let page: Int
    let number: Int
    let type: String
    let width: Int
    let height: Int
    let objectReference: String
}

enum NativePDFImagesListError: Error, Equatable, LocalizedError {
    case malformed

    var errorDescription: String? {
        "pdfimages -list returned malformed output."
    }
}

struct NativePDFImagesList {
    let rows: [NativePDFImagesListRow]

    init(output: String) throws {
        var rows: [NativePDFImagesListRow] = []
        var sawHeader = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("page") {
                sawHeader = true
                continue
            }
            if line.allSatisfy({ $0 == "-" || $0.isWhitespace }) { continue }

            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 16,
                  let page = Int(fields[0]), page > 0,
                  let number = Int(fields[1]), number >= 0,
                  ["image", "mask", "smask", "stencil"].contains(String(fields[2])),
                  let width = Int(fields[3]), width > 0,
                  let height = Int(fields[4]), height > 0,
                  let object = Int(fields[10]), object > 0,
                  let generation = Int(fields[11]), generation >= 0
            else {
                throw NativePDFImagesListError.malformed
            }
            rows.append(NativePDFImagesListRow(
                page: page,
                number: number,
                type: String(fields[2]),
                width: width,
                height: height,
                objectReference: "\(object) \(generation) R"
            ))
        }
        guard sawHeader else { throw NativePDFImagesListError.malformed }
        guard Set(rows.map(\.number)).count == rows.count else {
            throw NativePDFImagesListError.malformed
        }
        self.rows = rows
    }
}
