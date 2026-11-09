import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// One pasteboard representation: a UTI and its bytes.
struct Rep: Equatable {
    let type: String
    let data: Data
}

/// A clipboard snapshot is a list of pasteboard items, each a list of representations.
enum PayloadCodec {
    static func encode(_ items: [[Rep]]) -> Data? {
        let arr: [[[String: Any]]] = items.map { $0.map { ["t": $0.type, "d": $0.data] } }
        return try? PropertyListSerialization.data(fromPropertyList: arr, format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> [[Rep]]? {
        guard let arr = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [[[String: Any]]] else {
            return nil
        }
        return arr.map { item in
            item.compactMap { d in
                guard let t = d["t"] as? String, let v = d["d"] as? Data else { return nil }
                return Rep(type: t, data: v)
            }
        }
    }
}

enum ClipKind: String {
    case text, url, image, file
}

struct Clip {
    let items: [[Rep]]
    let kind: ClipKind
    /// Plain text used for search and plain-text paste (file paths for files).
    let text: String
    /// Content hash used to de-duplicate: copying the same thing again moves it to the top.
    let hash: String
    let imageData: Data?
    let fileURLs: [URL]

    var byteSize: Int { items.reduce(0) { $0 + $1.reduce(0) { $0 + $1.data.count } } }
}

enum ClipAnalyzer {
    static let imageTypes = [
        "public.png", "public.tiff", "public.jpeg", "com.compuserve.gif", "public.heic",
        "Apple PNG pasteboard type", "NeXT TIFF v4.0 pasteboard type",
    ]

    static func analyze(_ rawItems: [[Rep]]) -> Clip? {
        let items = rawItems.filter { !$0.isEmpty }
        guard !items.isEmpty else { return nil }
        let all = items.flatMap { $0 }

        let fileURLs = items.compactMap { item -> URL? in
            guard let rep = item.first(where: { $0.type == "public.file-url" }) else { return nil }
            return url(from: rep.data)
        }.filter(\.isFileURL)
        let plain = items.compactMap(text(in:)).joined(separator: "\n")
        let image = imageTypes.lazy.compactMap { t in all.first(where: { $0.type == t })?.data }.first

        if !fileURLs.isEmpty {
            let text = fileURLs.map(\.path).joined(separator: "\n")
            return Clip(items: items, kind: .file, text: text, hash: digest("file", Data(text.utf8)),
                        imageData: image, fileURLs: fileURLs)
        }

        let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty, let image {
            return Clip(items: items, kind: .image, text: "", hash: digest("image", image),
                        imageData: image, fileURLs: [])
        }
        if trimmed.isEmpty, let rep = all.first(where: { $0.type == "public.url" }), let u = url(from: rep.data) {
            let s = u.absoluteString
            return Clip(items: items, kind: .url, text: s, hash: digest("text", Data(s.utf8)), imageData: nil, fileURLs: [])
        }
        guard !trimmed.isEmpty else { return nil }
        let kind: ClipKind = isWebURL(trimmed) ? .url : .text
        return Clip(items: items, kind: kind, text: plain, hash: digest("text", Data(plain.utf8)),
                    imageData: nil, fileURLs: [])
    }

    static func text(in item: [Rep]) -> String? {
        for type in ["public.utf8-plain-text", "NSStringPboardType"] {
            if let rep = item.first(where: { $0.type == type }), let s = String(data: rep.data, encoding: .utf8) { return s }
        }
        for type in ["public.utf16-external-plain-text", "public.utf16-plain-text"] {
            guard let rep = item.first(where: { $0.type == type }) else { continue }
            // Without a BOM this is host byte order, i.e. little-endian on every current Mac.
            let bom = rep.data.starts(with: [0xFE, 0xFF]) || rep.data.starts(with: [0xFF, 0xFE])
            if let s = String(data: rep.data, encoding: bom ? .utf16 : .utf16LittleEndian) { return s }
        }
        return nil
    }

    static func url(from data: Data) -> URL? {
        guard let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))),
            !s.isEmpty else { return nil }
        return URL(string: s)
    }

    static func isWebURL(_ s: String) -> Bool {
        guard !s.contains(where: \.isWhitespace), let u = URL(string: s), let scheme = u.scheme?.lowercased() else {
            return false
        }
        return (scheme == "http" || scheme == "https") && u.host != nil
    }

    private static func digest(_ prefix: String, _ data: Data) -> String {
        var h = SHA256()
        h.update(data: Data(prefix.utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum Thumbnailer {
    struct Result {
        let png: Data
        let width: Int
        let height: Int
    }

    static func make(data: Data) -> Result? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap(make)
    }

    static func make(fileURL url: URL) -> Result? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return CGImageSourceCreateWithURL(url as CFURL, nil).flatMap(make)
    }

    private static func make(_ src: CGImageSource) -> Result? {
        guard CGImageSourceGetCount(src) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? cg.width
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? cg.height
        return Result(png: out as Data, width: w, height: h)
    }
}
