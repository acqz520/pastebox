import Foundation

struct ClipRow: Identifiable, Equatable {
    let id: Int64
    let uuid: String
    let kind: ClipKind
    let preview: String
    let usedAt: Date
    let sourceBundle: String?
    let categoryID: Int64?
    let imageWidth: Int
    let imageHeight: Int
    let thumbURL: URL?
}

struct Category: Identifiable, Hashable {
    let id: Int64
    let name: String
}

/// History storage: metadata in SQLite, clipboard payloads and thumbnails as files.
/// All access goes through one serial queue, so it is safe from any thread.
final class Store {
    let root: URL
    private let db: Database
    private let q = DispatchQueue(label: "pastebox.store")
    private let payloadDir: URL
    private let thumbDir: URL

    init(root: URL) throws {
        self.root = root
        payloadDir = root.appendingPathComponent("payloads", isDirectory: true)
        thumbDir = root.appendingPathComponent("thumbs", isDirectory: true)
        for dir in [root, payloadDir, thumbDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        db = try Database(path: root.appendingPathComponent("history.sqlite").path)
        try db.exec("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            uuid TEXT NOT NULL,
            kind TEXT NOT NULL,
            text TEXT NOT NULL DEFAULT '',
            hash TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL,
            used_at REAL NOT NULL,
            source_bundle TEXT,
            category_id INTEGER,
            img_w INTEGER NOT NULL DEFAULT 0,
            img_h INTEGER NOT NULL DEFAULT 0,
            byte_size INTEGER NOT NULL DEFAULT 0,
            has_thumb INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_items_used ON items(used_at DESC);
        CREATE INDEX IF NOT EXISTS idx_items_cat ON items(category_id, used_at DESC);
        CREATE TABLE IF NOT EXISTS categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            sort INTEGER NOT NULL DEFAULT 0
        );
        """)
    }

    func thumbURL(_ uuid: String) -> URL { thumbDir.appendingPathComponent(uuid + ".png") }
    private func payloadURL(_ uuid: String) -> URL { payloadDir.appendingPathComponent(uuid + ".plist") }

    // MARK: - Writing

    /// Saves a clip. If the same content already exists it is moved to the top instead
    /// (only when `date` is newer, so an import never reorders fresher history).
    @discardableResult
    func ingest(_ clip: Clip, at date: Date, sourceBundle: String?) -> Int64? {
        guard let payload = PayloadCodec.encode(clip.items) else { return nil }
        let ts = date.timeIntervalSince1970

        let hit: (id: Int64, uuid: String, usedAt: Double)? = q.sync {
            var found: (Int64, String, Double)?
            try? db.query("SELECT id, uuid, used_at FROM items WHERE hash = ?", [clip.hash]) {
                found = ($0.int(0), $0.string(1) ?? "", $0.double(2))
            }
            if let found, ts > found.2 {
                try? db.run("UPDATE items SET used_at = ?, source_bundle = coalesce(?, source_bundle) WHERE id = ?",
                            [ts, sourceBundle, found.0])
                try? payload.write(to: payloadURL(found.1), options: .atomic)
            }
            return found
        }
        if let hit { return hit.id }

        // Thumbnail work happens outside the queue so the UI never waits on it.
        let uuid = UUID().uuidString
        do { try payload.write(to: payloadURL(uuid), options: .atomic) } catch { return nil }
        let thumb = clip.imageData.flatMap(Thumbnailer.make(data:)) ?? clip.fileURLs.first.flatMap(Thumbnailer.make(fileURL:))
        if let thumb { try? thumb.png.write(to: thumbURL(uuid), options: .atomic) }

        return q.sync {
            let id = try? db.run("""
            INSERT OR IGNORE INTO items (uuid, kind, text, hash, created_at, used_at, source_bundle, img_w, img_h, byte_size, has_thumb)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [uuid, clip.kind.rawValue, clip.text, clip.hash, ts, ts, sourceBundle,
                  thumb?.width ?? 0, thumb?.height ?? 0, clip.byteSize, thumb != nil])
            if db.changes == 0 { // lost a race with an identical clip
                removeFiles(uuid)
                return nil
            }
            return id
        }
    }

    func touch(_ id: Int64) {
        q.sync { _ = try? db.run("UPDATE items SET used_at = ? WHERE id = ?", [Date().timeIntervalSince1970, id]) }
    }

    func delete(_ id: Int64) {
        q.sync {
            var uuid: String?
            try? db.query("SELECT uuid FROM items WHERE id = ?", [id]) { uuid = $0.string(0) }
            try? db.run("DELETE FROM items WHERE id = ?", [id])
            if let uuid { removeFiles(uuid) }
        }
    }

    func setCategory(_ id: Int64, _ categoryID: Int64?) {
        q.sync { _ = try? db.run("UPDATE items SET category_id = ? WHERE id = ?", [categoryID, id]) }
    }

    /// Keeps at most `limit` uncategorized items; items filed into a category are never pruned.
    func prune(limit: Int) {
        q.sync {
            var victims: [(Int64, String)] = []
            try? db.query("SELECT id, uuid FROM items WHERE category_id IS NULL ORDER BY used_at DESC LIMIT -1 OFFSET ?", [limit]) {
                victims.append(($0.int(0), $0.string(1) ?? ""))
            }
            for (id, uuid) in victims {
                try? db.run("DELETE FROM items WHERE id = ?", [id])
                removeFiles(uuid)
            }
        }
    }

    func clearHistory() {
        q.sync {
            var victims: [String] = []
            try? db.query("SELECT uuid FROM items WHERE category_id IS NULL") { victims.append($0.string(0) ?? "") }
            try? db.run("DELETE FROM items WHERE category_id IS NULL")
            victims.forEach(removeFiles)
        }
    }

    private func removeFiles(_ uuid: String) {
        try? FileManager.default.removeItem(at: payloadURL(uuid))
        try? FileManager.default.removeItem(at: thumbURL(uuid))
    }

    // MARK: - Categories

    func categories() -> [Category] {
        q.sync {
            var out: [Category] = []
            try? db.query("SELECT id, name FROM categories ORDER BY sort, id") {
                out.append(Category(id: $0.int(0), name: $0.string(1) ?? ""))
            }
            return out
        }
    }

    @discardableResult
    func addCategory(_ name: String) -> Int64? {
        q.sync { try? db.run("INSERT INTO categories (name) VALUES (?)", [name]) }
    }

    func deleteCategory(_ id: Int64) {
        q.sync {
            try? db.run("UPDATE items SET category_id = NULL WHERE category_id = ?", [id])
            try? db.run("DELETE FROM categories WHERE id = ?", [id])
        }
    }

    // MARK: - Reading

    func rows(query: String, categoryID: Int64?, limit: Int, offset: Int = 0) -> [ClipRow] {
        let (whereSQL, args) = filter(query, categoryID)
        let sql = """
        SELECT id, uuid, kind, substr(text, 1, 300), used_at, source_bundle, category_id, img_w, img_h, has_thumb
        FROM items\(whereSQL) ORDER BY used_at DESC LIMIT ? OFFSET ?
        """
        return q.sync {
            var out: [ClipRow] = []
            try? db.query(sql, args + [limit, offset]) { r in
                let uuid = r.string(1) ?? ""
                out.append(ClipRow(
                    id: r.int(0),
                    uuid: uuid,
                    kind: ClipKind(rawValue: r.string(2) ?? "") ?? .text,
                    preview: (r.string(3) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    usedAt: Date(timeIntervalSince1970: r.double(4)),
                    sourceBundle: r.string(5),
                    categoryID: r.isNull(6) ? nil : r.int(6),
                    imageWidth: Int(r.int(7)),
                    imageHeight: Int(r.int(8)),
                    thumbURL: r.int(9) != 0 ? thumbURL(uuid) : nil
                ))
            }
            return out
        }
    }

    func count(query: String = "", categoryID: Int64? = nil) -> Int {
        let (whereSQL, args) = filter(query, categoryID)
        return q.sync { Int((try? db.scalar("SELECT count(*) FROM items\(whereSQL)", args)) ?? 0) }
    }

    func kindCounts() -> [String: Int] {
        q.sync {
            var out: [String: Int] = [:]
            try? db.query("SELECT kind, count(*) FROM items GROUP BY kind") { out[$0.string(0) ?? ""] = Int($0.int(1)) }
            return out
        }
    }

    func payload(_ uuid: String) -> [[Rep]]? {
        (try? Data(contentsOf: payloadURL(uuid))).flatMap(PayloadCodec.decode)
    }

    func fullText(_ id: Int64) -> String {
        q.sync {
            var s = ""
            try? db.query("SELECT text FROM items WHERE id = ?", [id]) { s = $0.string(0) ?? "" }
            return s
        }
    }

    private func filter(_ query: String, _ categoryID: Int64?) -> (String, [Any?]) {
        var conds: [String] = []
        var args: [Any?] = []
        if let categoryID {
            conds.append("category_id = ?")
            args.append(categoryID)
        }
        for term in query.split(whereSeparator: \.isWhitespace) {
            let escaped = term.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            conds.append("text LIKE ? ESCAPE '\\'")
            args.append("%\(escaped)%")
        }
        return (conds.isEmpty ? "" : " WHERE " + conds.joined(separator: " AND "), args)
    }
}
