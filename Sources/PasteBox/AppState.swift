import AppKit
import Combine

/// View model behind the history panel.
final class AppState: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { limit = pageSize; reload(resetSelection: true) } }
    }
    @Published var categoryID: Int64? {
        didSet { if categoryID != oldValue { limit = pageSize; reload(resetSelection: true) } }
    }
    @Published private(set) var rows: [ClipRow] = [] {
        didSet { prefetchIDs = Set(rows.suffix(prefetch).map(\.id)) }
    }
    @Published var selection = 0
    @Published private(set) var categories: [Category] = []
    @Published private(set) var total = 0
    @Published var trusted = true
    @Published var toast: String?
    @Published var addingCategory = false
    /// Bumped whenever the search field should take focus again.
    @Published var focusToken = 0
    /// Bumped to scroll the list back to the top.
    @Published var scrollTopToken = 0

    let store: Store
    // Load the whole history up front (metadata only) so the list's total height is known
    // from the start; appending pages while scrolling would make the scroller jump.
    private let pageSize = 5000
    private var limit = 5000

    var onPaste: (ClipRow, Bool) -> Void = { _, _ in }
    var onCopy: (ClipRow) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}

    init(store: Store) {
        self.store = store
    }

    /// Called when the panel hides: everything the next show should start from.
    func resetForNextShow() {
        addingCategory = false
        toast = nil
        if query.isEmpty {
            reload(resetSelection: true)
        } else {
            query = "" // triggers reload
        }
        scrollTopToken += 1
    }

    /// Called right before the panel appears; only cheap checks, the content is already current.
    func prepareForShow() {
        trusted = Paster.isTrusted
        focusToken += 1
    }

    func reload(resetSelection: Bool = false) {
        rows = store.rows(query: query, categoryID: categoryID, limit: limit)
        total = store.count(query: query, categoryID: categoryID)
        categories = store.categories()
        if let categoryID, !categories.contains(where: { $0.id == categoryID }) {
            self.categoryID = nil
        }
        if resetSelection || selection >= rows.count { selection = 0 }
    }

    /// Fetches the next page in the background once the list gets within `prefetch` rows
    /// of the end, so fast scrolling never waits on the database.
    func loadMoreIfNeeded(_ row: ClipRow) {
        guard !loadingMore, rows.count >= limit, prefetchIDs.contains(row.id) else { return }
        loadingMore = true
        let (query, categoryID, offset, page) = (self.query, self.categoryID, rows.count, pageSize)
        DispatchQueue.global(qos: .userInitiated).async { [store] in
            let more = store.rows(query: query, categoryID: categoryID, limit: page, offset: offset)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loadingMore = false
                guard self.query == query, self.categoryID == categoryID, self.rows.count == offset else { return }
                let have = Set(self.rows.map(\.id))
                self.rows.append(contentsOf: more.filter { !have.contains($0.id) })
                self.limit += page
            }
        }
    }

    private var loadingMore = false
    private var prefetchIDs: Set<Int64> = []
    private let prefetch = 100

    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selection = min(max(selection + delta, 0), rows.count - 1)
    }

    func pasteSelected(plain: Bool) { paste(at: selection, plain: plain) }

    func paste(at index: Int, plain: Bool = false) {
        guard rows.indices.contains(index) else { return }
        selection = index
        onPaste(rows[index], plain)
    }

    func paste(_ row: ClipRow, plain: Bool) {
        if let index = rows.firstIndex(where: { $0.id == row.id }) { paste(at: index, plain: plain) }
    }

    func copy(_ row: ClipRow) { onCopy(row) }

    /// Card under the mouse; not @Published because nothing renders from it.
    private(set) var hoveredID: Int64?

    func hover(_ id: Int64, _ inside: Bool) {
        if inside {
            hoveredID = id
        } else if hoveredID == id {
            hoveredID = nil
        }
    }

    /// Selects the hovered card and returns it, for the right-click menu.
    func selectHovered() -> ClipRow? {
        guard let id = hoveredID, let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        selection = index
        return rows[index]
    }

    func delete(_ row: ClipRow) {
        store.delete(row.id)
        reload()
    }

    func deleteSelected() {
        guard rows.indices.contains(selection) else { return }
        delete(rows[selection])
    }

    func setCategory(_ row: ClipRow, _ id: Int64?) {
        store.setCategory(row.id, id)
        reload()
        if let id, let name = categories.first(where: { $0.id == id })?.name {
            showToast("已加入「\(name)」")
        }
    }

    func addCategory(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        addingCategory = false
        focusToken += 1
        guard !name.isEmpty else { return }
        let id = store.addCategory(name)
        reload()
        categoryID = id
    }

    func deleteCategory(_ category: Category) {
        if categoryID == category.id { categoryID = nil }
        store.deleteCategory(category.id)
        reload()
    }

    func cycleCategory(_ delta: Int) {
        let ids: [Int64?] = [nil] + categories.map(\.id)
        let idx = ids.firstIndex(of: categoryID) ?? 0
        categoryID = ids[(idx + delta + ids.count) % ids.count]
    }

    func showToast(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.toast == text { self?.toast = nil }
        }
    }
}
