import Foundation

public enum OCRWorkerBonjourService {
    public static let type = "_scannerserver._tcp"
    public static let domain = "local."

    public static func serverURL(fromTXTRecord values: [String: String]) -> URL? {
        guard values["api"] == String(OCRWorkerProtocol.currentVersion),
              let text = values["url"],
              let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            return nil
        }
        return url
    }
}
