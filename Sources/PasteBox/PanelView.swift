import AppKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var state: AppState
    @State private var newCategory = ""
    @FocusState private var focus: Field?

    private enum Field { case search, newCategory }

    var body: some View {
        VStack(spacing: 0) {
            header
            chips
            if !state.trusted { permissionBanner }
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            footer
        }
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .overlay(alignment: .bottom) { toast }
        .onChange(of: state.focusToken) { _ in focus = .search }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("输入开始搜索…", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focus, equals: .search)
                if !state.query.isEmpty {
                    Button { state.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.07)))

            Button { state.onOpenSettings() } label: {
                Image(systemName: "gearshape").font(.system(size: 15)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("设置 (⌘,)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(title: "全部", selected: state.categoryID == nil) { state.categoryID = nil }
                ForEach(state.categories) { c in
                    Chip(title: c.name, selected: state.categoryID == c.id) { state.categoryID = c.id }
                        .contextMenu {
                            Button("删除分类「\(c.name)」") { state.deleteCategory(c) }
                        }
                }
                if state.addingCategory {
                    TextField("分类名，回车确定", text: $newCategory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(width: 120)
                        .focused($focus, equals: .newCategory)
                        .onSubmit {
                            state.addCategory(newCategory)
                            newCategory = ""
                        }
                        .onAppear { focus = .newCategory }
                } else {
                    Button { state.addingCategory = true } label: {
                        Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("新建分类")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 8)
    }

    private var permissionBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("未授权「辅助功能」：选中后只复制，需手动 ⌘V")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("去授权") { Paster.openAccessibilitySettings() }
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let selectedID = state.rows.indices.contains(state.selection) ? state.rows[state.selection].id : nil
                let quickIndex = Dictionary(uniqueKeysWithValues: state.rows.prefix(9).enumerated().map { ($1.id, $0) })
                LazyVStack(spacing: 8) {
                    ForEach(state.rows) { row in
                        // Equatable: moving the selection only re-renders the two cards involved.
                        // No per-row .contextMenu: it was the single biggest scrolling cost.
                        // Right click is handled once for the whole panel (PanelController).
                        ClipCard(row: row, quickIndex: quickIndex[row.id], selected: row.id == selectedID,
                                 onHover: { [weak state] id, inside in state?.hover(id, inside) })
                            .equatable()
                            .id(row.id)
                            .onTapGesture {
                                state.paste(row, plain: NSEvent.modifierFlags.contains(.shift))
                            }
                            .onAppear { state.loadMoreIfNeeded(row) }
                    }
                }
                .padding(12)
            }
            .overlay { if state.rows.isEmpty { emptyState } }
            .onChange(of: state.selection) { sel in
                if state.rows.indices.contains(sel) { proxy.scrollTo(state.rows[sel].id) }
            }
            .onChange(of: state.focusToken) { _ in
                if let first = state.rows.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 28)).foregroundStyle(.tertiary)
            Text(state.query.isEmpty ? "还没有记录，复制点东西试试" : "没有匹配的内容")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Text("\(state.total) 个项目").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text("↩ 粘贴  ⇧↩ 纯文本  ⇥ 切换分类").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var toast: some View {
        if let text = state.toast {
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .padding(.bottom, 44)
                .transition(.opacity)
        }
    }
}

private struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One history entry. Header (source app + time) and body are stacked, never overlaid,
/// so text can't paint on top of other text.
///
/// Every card has the same height, like PasteNow's fixed cell height. The lazy list can
/// then compute the true content height before rows are rendered, so the scroller never
/// jumps while you scroll. Nothing touches the disk on the main thread, and the card is
/// Equatable so unrelated state changes don't re-render it.
struct ClipCard: View, Equatable {
    static let headerHeight: CGFloat = 15
    static let contentHeight: CGFloat = 64
    static let height: CGFloat = 10 + headerHeight + 6 + contentHeight + 10

    let row: ClipRow
    let quickIndex: Int?
    let selected: Bool
    var onHover: (Int64, Bool) -> Void = { _, _ in }
    @State private var hovering = false

    static func == (a: ClipCard, b: ClipCard) -> Bool {
        a.row == b.row && a.quickIndex == b.quickIndex && a.selected == b.selected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                let app = AppInfo.app(for: row.sourceBundle)
                if let icon = app?.icon {
                    Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                }
                Text(app?.name ?? "")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                if row.kind == .image, row.imageWidth > 0 {
                    Text("\(row.imageWidth)×\(row.imageHeight)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let quickIndex {
                    Text("⌘\(quickIndex + 1)").font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                }
                Text(TimeFormat.string(row.usedAt))
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(height: Self.headerHeight)
            content
                .frame(maxWidth: .infinity, minHeight: Self.contentHeight, maxHeight: Self.contentHeight, alignment: .topLeading)
                .clipped()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(background))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { inside in
            hovering = inside
            onHover(row.id, inside)
        }
    }

    private var background: Color {
        if selected { return Color.accentColor.opacity(0.14) }
        return Color(nsColor: .textBackgroundColor).opacity(hovering ? 0.95 : 0.7)
    }

    /// Aspect-fit inside the content box, from the stored pixel size.
    private var imageSize: CGSize {
        let maxH = Self.contentHeight
        guard row.imageWidth > 0, row.imageHeight > 0 else { return CGSize(width: maxH * 1.5, height: maxH) }
        let w = Double(row.imageWidth), h = Double(row.imageHeight)
        let scale = min(300 / w, maxH / h, 1)
        return CGSize(width: max(w * scale, 24), height: max(h * scale, 24))
    }

    @ViewBuilder
    private var content: some View {
        switch row.kind {
        case .text:
            Text(row.preview).font(.system(size: 13)).lineLimit(3)
        case .url:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Color.accentColor)
                Text(row.preview).font(.system(size: 13)).foregroundStyle(Color.accentColor).lineLimit(3)
            }
        case .image:
            Thumbnail(url: row.thumbURL, size: imageSize)
        case .file:
            HStack(spacing: 8) {
                if row.thumbURL != nil {
                    Thumbnail(url: row.thumbURL, size: CGSize(width: 48, height: 48))
                } else {
                    Image(nsImage: AppInfo.fileIcon(row.preview)).resizable().frame(width: 36, height: 36)
                }
                Text(row.preview.split(separator: "\n").map { ($0 as NSString).lastPathComponent }.joined(separator: "\n"))
                    .font(.system(size: 13)).lineLimit(3)
            }
        }
    }
}

/// Fixed-size thumbnail, decoded off the main thread at display resolution.
private struct Thumbnail: View {
    let url: URL?
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let shown = image ?? url.flatMap(ThumbCache.cached) {
                Image(nsImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: url) {
            guard let url, ThumbCache.cached(url) == nil else { return }
            image = await ThumbCache.load(url, maxPixel: Int(max(size.width, size.height) * 2))
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Caches

enum ThumbCache {
    private static let cache: NSCache<NSURL, NSImage> = {
        let c = NSCache<NSURL, NSImage>()
        c.countLimit = 400
        return c
    }()
    private static let queue = DispatchQueue(label: "pastebox.thumbs", qos: .userInitiated, attributes: .concurrent)

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// Reads and fully decodes the PNG on a background queue, downsampled to `maxPixel`.
    static func load(_ url: URL, maxPixel: Int) async -> NSImage? {
        await withCheckedContinuation { cont in
            queue.async {
                var result: NSImage?
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let opts: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                        kCGImageSourceShouldCacheImmediately: true,
                    ]
                    if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
                        cache.setObject(img, forKey: url as NSURL)
                        result = img
                    }
                }
                cont.resume(returning: result)
            }
        }
    }
}

/// App name/icon lookups hit LaunchServices and the disk; resolve each bundle ID once.
enum AppInfo {
    struct App {
        let name: String
        let icon: NSImage
    }

    private static var apps: [String: App?] = [:]
    private static var fileIcons: [String: NSImage] = [:]

    static func app(for bundle: String?) -> App? {
        guard let bundle else { return nil }
        if let hit = apps[bundle] { return hit }
        var url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
        // Helper processes (e.g. "com.electron.lark.helper") belong to their parent app.
        var parts = bundle.split(separator: ".")
        while url == nil && parts.count > 2 {
            parts.removeLast()
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: "."))
        }
        let app = url.map {
            App(name: FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: ""),
                icon: NSWorkspace.shared.icon(forFile: $0.path))
        }
        apps[bundle] = app
        return app
    }

    static func fileIcon(_ paths: String) -> NSImage {
        let first = paths.split(separator: "\n").first.map(String.init) ?? ""
        let ext = (first as NSString).pathExtension
        if let hit = fileIcons[ext] { return hit }
        let icon = NSWorkspace.shared.icon(forFile: first)
        fileIcons[ext] = icon
        return icon
    }
}

enum TimeFormat {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let date: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/M/d"
        return f
    }()

    static func string(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return time.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天 " + time.string(from: d) }
        return date.string(from: d)
    }
}

