import Foundation
import CoreFoundation

enum NativePDFJSONError: Error, Equatable, LocalizedError {
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .malformed(let detail):
            "qpdf returned malformed JSON v2 output: \(detail)"
        }
    }
}

struct NativePDFJSONDocument {
    private let header: [String: Any]
    private let objects: [String: Any]
    private let pagesRootReference: String
    let pageReferences: [String]

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let qpdf = root["qpdf"] as? [Any],
              qpdf.count == 2,
              let header = qpdf[0] as? [String: Any],
              Self.integer(header["jsonversion"]) == 2,
              let objects = qpdf[1] as? [String: Any]
        else {
            throw NativePDFJSONError.malformed("missing qpdf JSON version 2 object table")
        }
        self.header = header
        self.objects = objects
        let pageTree = try Self.collectPages(in: objects)
        self.pagesRootReference = pageTree.root
        self.pageReferences = pageTree.pages
    }

    func mediaBox(forPageAt index: Int) throws -> NativePDFBox {
        guard pageReferences.indices.contains(index) else {
            throw NativePDFJSONError.malformed("page index is out of bounds")
        }

        var reference = pageReferences[index]
        var visited: Set<String> = []
        while visited.insert(reference).inserted {
            let dictionary = try objectDictionary(reference: reference, objects: objects)
            if let value = dictionary["/MediaBox"] {
                return try box(from: value)
            }
            guard let parent = try Self.reference(dictionary["/Parent"]) else {
                throw NativePDFJSONError.malformed("page \(index + 1) has no inherited MediaBox")
            }
            reference = parent
        }
        throw NativePDFJSONError.malformed("cycle while resolving page \(index + 1) MediaBox")
    }

    func directImageReferences(forPageAt index: Int) throws -> Set<String> {
        guard pageReferences.indices.contains(index) else {
            throw NativePDFJSONError.malformed("page index is out of bounds")
        }
        guard let resources = try inheritedValue("/Resources", forPageAt: index) else {
            return []
        }
        let resourcesDictionary = try dictionary(from: resources, name: "Resources")
        guard let xObjects = resourcesDictionary["/XObject"] else { return [] }
        let xObjectDictionary = try dictionary(from: xObjects, name: "XObject")

        var references: Set<String> = []
        for value in xObjectDictionary.values {
            guard let reference = try Self.reference(value) else {
                throw NativePDFJSONError.malformed("XObject contains a direct object")
            }
            let dictionary = try streamDictionary(reference: reference)
            guard dictionary["/Subtype"] as? String == "/Image" else { continue }
            if let imageMask = dictionary["/ImageMask"] as? Bool, imageMask { continue }
            references.insert(reference)
        }
        return references
    }

    func updateData(cropBoxes: [Int: NativePDFBox], keepOriginalBoxes: Bool) throws -> Data {
        var updates: [String: Any] = [:]
        for (index, cropBox) in cropBoxes {
            guard pageReferences.indices.contains(index) else {
                throw NativePDFJSONError.malformed("crop update page index is out of bounds")
            }
            let reference = pageReferences[index]
            var dictionary = try objectDictionary(reference: reference, objects: objects)
            dictionary["/CropBox"] = cropBox.jsonArray
            if !keepOriginalBoxes {
                dictionary["/MediaBox"] = cropBox.jsonArray
            }
            updates[Self.objectKey(reference)] = ["value": dictionary]
        }

        return try updateData(objects: updates)
    }

    func emptyPagesUpdateData() throws -> Data {
        var pagesRoot = try Self.objectDictionary(
            reference: pagesRootReference,
            objects: objects
        )
        pagesRoot["/Kids"] = []
        pagesRoot["/Count"] = 0
        return try updateData(objects: [
            Self.objectKey(pagesRootReference): ["value": pagesRoot],
        ])
    }

    private static func collectPages(
        in objects: [String: Any]
    ) throws -> (root: String, pages: [String]) {
        let trailer = try objectDictionary(key: "trailer", objects: objects)
        guard let root = try Self.reference(trailer["/Root"]) else {
            throw NativePDFJSONError.malformed("trailer has no indirect Root")
        }
        let catalog = try objectDictionary(reference: root, objects: objects)
        guard let pagesRoot = try Self.reference(catalog["/Pages"]) else {
            throw NativePDFJSONError.malformed("catalog has no indirect Pages root")
        }

        var pages: [String] = []
        var visited: Set<String> = []
        try appendPages(reference: pagesRoot, objects: objects, visited: &visited, pages: &pages)
        return (pagesRoot, pages)
    }

    private static func appendPages(
        reference: String,
        objects: [String: Any],
        visited: inout Set<String>,
        pages: inout [String]
    ) throws {
        guard visited.insert(reference).inserted else {
            throw NativePDFJSONError.malformed("cycle or duplicate in page tree at \(reference)")
        }
        let dictionary = try objectDictionary(reference: reference, objects: objects)
        switch dictionary["/Type"] as? String {
        case "/Page":
            pages.append(reference)
        case "/Pages":
            guard let kids = dictionary["/Kids"] as? [Any] else {
                throw NativePDFJSONError.malformed("Pages node has no Kids array")
            }
            for kid in kids {
                guard let kidReference = try Self.reference(kid) else {
                    throw NativePDFJSONError.malformed("page tree contains a direct child")
                }
                try appendPages(
                    reference: kidReference,
                    objects: objects,
                    visited: &visited,
                    pages: &pages
                )
            }
        default:
            throw NativePDFJSONError.malformed("page tree node has an invalid Type")
        }
    }

    private func objectDictionary(reference: String, objects: [String: Any]) throws -> [String: Any] {
        try Self.objectDictionary(reference: reference, objects: objects)
    }

    private static func objectDictionary(
        reference: String,
        objects: [String: Any]
    ) throws -> [String: Any] {
        try objectDictionary(key: objectKey(reference), objects: objects)
    }

    private static func objectDictionary(
        key: String,
        objects: [String: Any]
    ) throws -> [String: Any] {
        guard let wrapper = objects[key] as? [String: Any],
              let value = wrapper["value"] as? [String: Any]
        else {
            throw NativePDFJSONError.malformed("object \(key) is missing or is not a dictionary")
        }
        return value
    }

    private func box(from value: Any) throws -> NativePDFBox {
        let resolved: Any
        if let reference = try Self.reference(value) {
            resolved = try Self.objectValue(reference: reference, objects: objects)
        } else {
            resolved = value
        }
        guard let values = resolved as? [Any], values.count == 4,
              let left = Self.number(values[0]),
              let bottom = Self.number(values[1]),
              let right = Self.number(values[2]),
              let top = Self.number(values[3]),
              right > left,
              top > bottom
        else {
            throw NativePDFJSONError.malformed("MediaBox is not a valid four-number rectangle")
        }
        return NativePDFBox(left: left, bottom: bottom, right: right, top: top)
    }

    private func inheritedValue(_ key: String, forPageAt index: Int) throws -> Any? {
        var reference = pageReferences[index]
        var visited: Set<String> = []
        while visited.insert(reference).inserted {
            let dictionary = try objectDictionary(reference: reference, objects: objects)
            if let value = dictionary[key] { return value }
            guard let parent = try Self.reference(dictionary["/Parent"]) else { return nil }
            reference = parent
        }
        throw NativePDFJSONError.malformed(
            "cycle while resolving page \(index + 1) inherited \(key)"
        )
    }

    private func dictionary(from value: Any, name: String) throws -> [String: Any] {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let reference = try Self.reference(value) {
            return try objectDictionary(reference: reference, objects: objects)
        }
        throw NativePDFJSONError.malformed("\(name) is not a dictionary")
    }

    private func streamDictionary(reference: String) throws -> [String: Any] {
        let key = Self.objectKey(reference)
        guard let wrapper = objects[key] as? [String: Any],
              let stream = wrapper["stream"] as? [String: Any],
              let dictionary = stream["dict"] as? [String: Any]
        else {
            throw NativePDFJSONError.malformed("image object \(key) is not a stream")
        }
        return dictionary
    }

    private static func objectValue(reference: String, objects: [String: Any]) throws -> Any {
        let key = objectKey(reference)
        guard let wrapper = objects[key] as? [String: Any], let value = wrapper["value"] else {
            throw NativePDFJSONError.malformed("referenced object \(key) has no value")
        }
        return value
    }

    private static func reference(_ value: Any?) throws -> String? {
        guard let string = value as? String else { return nil }
        let components = string.split(separator: " ")
        guard components.count == 3,
              Int(components[0]) != nil,
              Int(components[1]) != nil,
              components[2] == "R"
        else {
            return nil
        }
        return components.joined(separator: " ")
    }

    private static func objectKey(_ reference: String) -> String {
        "obj:\(reference)"
    }

    private func updateData(objects updates: [String: Any]) throws -> Data {
        let update: [String: Any] = ["qpdf": [header, updates]]
        guard JSONSerialization.isValidJSONObject(update) else {
            throw NativePDFJSONError.malformed("update is not valid JSON")
        }
        return try JSONSerialization.data(withJSONObject: update, options: [.sortedKeys])
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.intValue
    }

    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }
}
