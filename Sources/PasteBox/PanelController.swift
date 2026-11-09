import AppKit
import Carbon
import SwiftUI

/// Borderless, non-activating panel: it can take keyboard focus for the search field
/// while the app you were typing in stays frontmost, so ⌘V lands back there.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let panel: KeyPanel
    private let state: AppState
    private var keyMonitor: Any?

    var isVisible: Bool { panel.isVisible }

    init(state: AppState) {
        self.state = state
        panel = KeyPanel(
            contentRect: NSRect(origin: .zero, size: Prefs.panelSize),
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.minSize = NSSize(width: 300, height: 360)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PanelView(state: state))
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    private var lastHide = Date.distantPast

    /// True right after the panel closed. Clicking the status item while the panel is open
    /// first makes the panel lose focus (which hides it); the click itself must not reopen it.
    var hidJustNow: Bool { Date().timeIntervalSince(lastHide) < 0.3 }

    /// Opens at the mouse, or under `anchor` (a screen rect such as the status item).
    func show(below anchor: NSRect? = nil) {
        state.prepareForShow()
        position(below: anchor)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        installKeyMonitor()
        DispatchQueue.main.async { [weak self] in self?.focusSearchField() }
    }

    func hide() {
        guard panel.isVisible else { return }
        Prefs.panelSize = panel.frame.size
        panel.orderOut(nil)
        removeKeyMonitor()
        lastHide = Date()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func position(below anchor: NSRect?) {
        let mouse = NSEvent.mouseLocation
        let point = anchor.map { NSPoint(x: $0.midX, y: $0.minY - 1) } ?? mouse
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var size = Prefs.panelSize
        size.width = min(max(size.width, panel.minSize.width), vf.width - 16)
        size.height = min(max(size.height, panel.minSize.height), vf.height - 16)
        var origin: NSPoint
        if let anchor {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - 6 - size.height)
        } else {
            origin = NSPoint(x: mouse.x - 24, y: mouse.y - size.height + 24)
        }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func focusSearchField() {
        func find(_ view: NSView) -> NSTextField? {
            if let tf = view as? NSTextField, tf.isEditable { return tf }
            for sub in view.subviews { if let tf = find(sub) { return tf } }
            return nil
        }
        if let content = panel.contentView, let tf = find(content) {
            panel.makeFirstResponder(tf)
        }
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown: return self.handle(event)
            case .rightMouseDown: return self.showContextMenu(event)
            case .leftMouseDown where event.modifierFlags.contains(.control): return self.showContextMenu(event)
            default: return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func showContextMenu(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel, let row = state.selectHovered(), let view = panel.contentView else { return event }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionItem("粘贴") { [state] in state.paste(row, plain: false) })
        menu.addItem(ActionItem("粘贴为纯文本", enabled: row.kind != .image) { [state] in state.paste(row, plain: true) })
        menu.addItem(ActionItem("仅复制") { [state] in state.copy(row) })
        menu.addItem(.separator())
        let categories = NSMenu()
        categories.autoenablesItems = false
        if state.categories.isEmpty {
            categories.addItem(ActionItem("先点「+」新建分类", enabled: false) {})
        }
        for c in state.categories {
            categories.addItem(ActionItem(c.name, enabled: row.categoryID != c.id) { [state] in state.setCategory(row, c.id) })
        }
        let add = NSMenuItem(title: "添加到分类", action: nil, keyEquivalent: "")
        add.submenu = categories
        menu.addItem(add)
        if row.categoryID != nil {
            menu.addItem(ActionItem("移出分类") { [state] in state.setCategory(row, nil) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("删除") { [state] in state.delete(row) })
        NSMenu.popUpContextMenu(menu, with: event, for: view)
        return nil
    }

    /// Returns nil when the key was consumed.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard panel.isKeyWindow else { return event }
        // While an input method is composing (e.g. pinyin), every key belongs to it.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return event }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let code = Int(event.keyCode)

        if state.addingCategory {
            if code == kVK_Escape {
                state.addingCategory = false
                state.focusToken += 1
                return nil
            }
            return event
        }

        switch code {
        case kVK_DownArrow:
            state.move(1)
            return nil
        case kVK_UpArrow:
            state.move(-1)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            state.pasteSelected(plain: mods.contains(.shift))
            return nil
        case kVK_Escape:
            if state.query.isEmpty { hide() } else { state.query = "" }
            return nil
        case kVK_Tab:
            state.cycleCategory(mods.contains(.shift) ? -1 : 1)
            return nil
        case kVK_Delete where mods == .command:
            state.deleteSelected()
            return nil
        case kVK_ANSI_Comma where mods == .command:
            state.onOpenSettings()
            return nil
        case kVK_ANSI_C where mods == .command:
            // ⌘C with nothing selected in the search field copies the highlighted clip.
            if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return event }
            if state.rows.indices.contains(state.selection) { state.copy(state.rows[state.selection]) }
            return nil
        default:
            break
        }

        if mods == .command || mods == [.command, .shift],
           let chars = event.characters(byApplyingModifiers: []), let n = Int(chars), (1...9).contains(n) {
            state.paste(at: n - 1, plain: mods.contains(.shift))
            return nil
        }
        return event
    }
}

/// NSMenuItem that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler() }
}
