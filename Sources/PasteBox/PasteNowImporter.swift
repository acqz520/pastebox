import Compression
import Foundation

/// Imports history from PasteNow (app.pastenow.PasteNow).
///
/// PasteNow keeps a Core Data store; each item's payload sits in ZPASTEITEMDATA.ZDATA as
/// either `0x01` + LZFSE stream (inline) or `0x02` + UUID of a file under `_EXTERNAL_DATA`
/// (itself a raw LZFSE stream). The decompressed bytes are a binary plist array of
/// `{type, data}` dictionaries — one pasteboard item.
enum PasteNowImporter {
    static let documents = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/KAQ3M6FSM7.app.pastenow.PasteNow/Documents", isDirectory: true)

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: documents.appendingPathComponent("PasteNow.sqlite").path)
    }

    struct Summary {
        var total = 0
        var imported = 0
        var duplicates = 0
        var failed = 0
    }

    static func run(into store: Store, progress: (Int, Int) -> Void) throws -> Summary {
        // Work on a copy so we never touch PasteNow's live database.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pastebox-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        for suffix in ["", "-wal", "-shm"] {
            let src = documents.appendingPathComponent("PasteNow.sqlite" + suffix)
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: tmp.appendingPathComponent("PasteNow.sqlite" + suffix))
            }
        }
        let db = try Database(path: tmp.appendingPathComponent("PasteNow.sqlite").path)

        struct Source {
            let date: Date
            let bundle: String?
            let text: String?
            let blob: Data?
        }
        var sources: [Source] = []
        // Oldest first, so newer duplicates win the "moved to top" position.
        try db.query("""
        SELECT p.ZTIMESTAMP, p.ZAPPBUNDLEID, p.ZTEXT, d.ZDATA
        FROM ZPASTEITEM p LEFT JOIN ZPASTEITEMDATA d ON d.ZPASTEITEM = p.Z_PK
        WHERE ifnull(p.ZREMOVEDFROMALL, 0) = 0
        ORDER BY p.ZTIMESTAMP ASC
        """) { r in
            sources.append(Source(
                date: Date(timeIntervalSinceReferenceDate: r.double(0)),
                bundle: r.string(1),
                text: r.string(2),
                blob: r.data(3)
            ))
        }

        var summary = Summary(total: sources.count)
        let before = store.count()
        for (i, src) in sources.enumerated() {
            autoreleasepool {
                var reps = src.blob.flatMap(decodeItem) ?? []
                if reps.isEmpty, let text = src.text, !text.isEmpty {
                    reps = [Rep(type: "public.utf8-plain-text", data: Data(text.utf8))]
                }
                if let clip = ClipAnalyzer.analyze([reps]), store.ingest(clip, at: src.date, sourceBundle: src.bundle) != nil {
                    summary.imported += 1
                } else {
                    summary.failed += 1
                    if ProcessInfo.processInfo.environment["PASTEBOX_DEBUG"] != nil {
                        print("failed:", src.bundle ?? "-", src.blob?.count ?? -1, reps.map { "\($0.type)(\($0.data.count))" })
                    }
                }
            }
            if i % 25 == 0 || i == sources.count - 1 { progress(i + 1, sources.count) }
        }
        let added = store.count() - before
        summary.duplicates = summary.imported - added
        summary.imported = added
        return summary
    }

    static func decodeItem(_ blob: Data) -> [Rep]? {
        guard let marker = blob.first else { return nil }
        let compressed: Data?
        switch marker {
        case 0x01:
            compressed = blob.dropFirst()
        case 0x02:
            let name = String(decoding: blob.dropFirst().prefix { $0 != 0 }, as: UTF8.self)
            compressed = try? Data(contentsOf: documents.appendingPathComponent(".PasteNow_SUPPORT/_EXTERNAL_DATA/\(name)"))
        default:
            compressed = blob
        }
        guard let compressed else { return nil }
        let raw = compressed.starts(with: Array("bvx".utf8)) ? lzfseDecode(compressed) : compressed
        guard let raw,
              let arr = (try? PropertyListSerialization.propertyList(from: raw, format: nil)) as? [[String: Any]] else {
            return nil
        }
        return arr.compactMap { d in
            guard let t = d["type"] as? String, let v = d["data"] as? Data else { return nil }
            return Rep(type: t, data: v)
        }
    }

    /// One-shot decode with a growing buffer. (compression_stream fails on some
    /// multi-block PasteNow payloads over ~1 MB; compression_decode_buffer handles them.)
    static func lzfseDecode(_ input: Data) -> Data? {
        var capacity = max(input.count * 4, 1 << 20)
        while capacity <= 1 << 30 {
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { dst.deallocate() }
            let n = input.withUnsafeBytes { src -> Int in
                guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, capacity, base, src.count, nil, COMPRESSION_LZFSE)
            }
            if n == 0 { return nil }
            if n < capacity { return Data(bytes: dst, count: n) }
            capacity *= 4 // output filled the buffer: it may be truncated, retry bigger
        }
        return nil
    }
}
