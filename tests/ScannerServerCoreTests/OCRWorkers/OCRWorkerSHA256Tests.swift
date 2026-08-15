import Foundation
import ScannerServerCore
import Testing

@Suite("OCR worker SHA-256")
struct OCRWorkerSHA256Tests {
    @Test("Known SHA-256 vectors match", arguments: [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("scannerserver", "5cd0367f1cef7cf1490ca1ce7d46ffdc31b91039cb3b68241c13b4db91545bbb"),
    ])
    func vectors(input: String, expected: String) {
        #expect(OCRWorkerSHA256.hexDigest(Data(input.utf8)) == expected)
    }
}
