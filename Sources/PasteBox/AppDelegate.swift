import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: Store!
    /// The hotkey panel opens at the mouse; the status bar panel opens under the menu bar icon.
    /// They are separate windows with separate state, so one never shows up looking like the other.
    private var hotkeyPanel: PanelController!
    private var statusPanel: PanelController!
    private var panels: [PanelController] { [hotkeyPanel, statusPanel].compactMap { $0 } }
    private let monitor = ClipboardMonitor()
    private let ingestQueue = DispatchQueue(label: "pastebox.ingest", qos: .userInitiated)
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var pauseItem: NSMenuItem!
    private var openItem: NSMenuItem!
    private var settingsWindow: NSWindow?
    private let settings = SettingsModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Prefs.registerDefaults()

        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PasteBox", isDirectory: true)
        do {
            store = try Store(root: root)
        } catch {
            let alert = NSAlert()
            alert.messageText = "PasteBox 无法打开数据目录"
            alert.informativeText = "\(root.path)\n\(error)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        hotkeyPanel = makePanel()
        statusPanel = makePanel()

        monitor.onCapture = { [weak self] items, bundle in self?.capture(items, bundle: bundle) }
        monitor.start()

        setupSettings()
        setupStatusItem()
        HotKey.shared.action = { [weak self] in self?.hotkeyPanel.toggle() }
        // Lets scripts trigger exactly what the hotkey does (window tracing without keystroke access).
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.liuhaofeng.pastebox.debug.hotkey"), object: nil, queue: .main
        ) { _ in HotKey.shared.action?() }
        settings.hotKeyOK = HotKey.shared.register(Prefs.hotKey)

        if !Paster.isTrusted { Paster.requestTrust() }
        if !settings.hotKeyOK { openSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        hotkeyPanel.show()
        return false
    }

    private func makePanel() -> PanelController {
        let state = AppState(store: store)
        let panel = PanelController(state: state)
        state.onPaste = { [weak self, weak panel] row, plain in
            if let panel { self?.paste(row, plain: plain, from: panel) }
        }
        state.onCopy = { [weak self, weak panel] row in
            if let panel { self?.copy(row, from: panel) }
        }
        state.onOpenSettings = { [weak self] in self?.openSettings() }
        state.reload(resetSelection: true)
        return panel
    }

    private func reloadAll() {
        panels.forEach { $0.state.reload() }
    }

    // MARK: - Clipboard

    private func capture(_ items: [[Rep]], bundle: String?) {
        ingestQueue.async { [weak self, store] in
            guard let store, let clip = ClipAnalyzer.analyze(items) else { return }
            store.ingest(clip, at: Date(), sourceBundle: bundle)
            store.prune(limit: max(Prefs.historyLimit, 100))
            DispatchQueue.main.async { self?.reloadAll() }
        }
    }

    private func write(_ row: ClipRow, plain: Bool, from panel: PanelController) -> Bool {
        guard let items = store.payload(row.uuid) else {
            panel.state.showToast("这条内容的数据已丢失")
            return false
        }
        var text: String?
        if plain && row.kind != .image {
            text = store.fullText(row.id)
        }
        monitor.ignore(changeCount: Paster.write(items, plainText: text?.isEmpty == false ? text : nil))
        store.touch(row.id)
        return true
    }

    private func paste(_ row: ClipRow, plain: Bool, from panel: PanelController) {
        guard write(row, plain: plain, from: panel) else { return }
        let state = panel.state
        guard Prefs.autoPaste else {
            panel.hide()
            return
        }
        guard Paster.isTrusted else {
            // Still useful: the clip is on the clipboard, the user can ⌘V by hand.
            state.trusted = false
            state.reload()
            state.showToast("已复制，请手动 ⌘V（授权辅助功能后可自动粘贴）")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak panel] in panel?.hide() }
            return
        }
        panel.hide()
        // Give the previous app a moment to get keyboard focus back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { Paster.pressCmdV() }
    }

    private func copy(_ row: ClipRow, from panel: PanelController) {
        guard write(row, plain: false, from: panel) else { return }
        reloadAll()
        panel.state.showToast("已复制到剪贴板")
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PasteBox")

        let menu = NSMenu()
        menu.delegate = self
        openItem = NSMenuItem(title: "打开剪贴板历史", action: #selector(openPanel), keyEquivalent: "")
        pauseItem = NSMenuItem(title: "暂停记录", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(openItem)
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(openSettingsAction), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "退出 PasteBox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusMenu = menu

        // Left click opens the history; right click (two-finger tap) or ⌃-click shows the menu.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusPanel.hide()
            // Attach the menu only for this click, otherwise every click would open it.
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            return
        }
        if statusPanel.isVisible {
            statusPanel.hide()
        } else if !statusPanel.hidJustNow {
            statusPanel.show(below: statusItem.button?.window?.frame)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        pauseItem.state = Prefs.paused ? .on : .off
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    @objc private func openPanel() {
        DispatchQueue.main.async { self.statusPanel.show(below: self.statusItem.button?.window?.frame) }
    }

    @objc private func togglePause() {
        Prefs.paused.toggle()
        settings.paused = Prefs.paused
        statusItem.button?.appearsDisabled = Prefs.paused
    }

    @objc private func openSettingsAction() { openSettings() }

    // MARK: - Settings

    private func setupSettings() {
        settings.dataDirectory = store.root
        settings.countItems = { [weak self] in self?.store.count() ?? 0 }
        settings.onShortcut = { [weak self] shortcut in
            guard let shortcut else {
                HotKey.shared.unregister()
                return true
            }
            let ok = HotKey.shared.register(shortcut)
            if !ok { HotKey.shared.register(Prefs.hotKey) }
            return ok
        }
        settings.onPrune = { [weak self] in
            guard let self else { return }
            self.store.prune(limit: max(Prefs.historyLimit, 100))
            self.settings.itemCount = self.store.count()
        }
        settings.onClear = { [weak self] in
            guard let self else { return }
            self.store.clearHistory()
            self.reloadAll()
            self.settings.itemCount = self.store.count()
        }
        settings.onImport = { [weak self] in self?.importPasteNow() }
    }

    private func openSettings() {
        panels.forEach { $0.hide() }
        settings.refresh()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: settings)))
            window.title = "PasteBox 设置"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func importPasteNow() {
        settings.importing = true
        settings.importStatus = "准备中…"
        let store = self.store!
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> PasteNowImporter.Summary in
                try PasteNowImporter.run(into: store) { done, total in
                    DispatchQueue.main.async { self?.settings.importStatus = "\(done)/\(total)" }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.settings.importing = false
                switch result {
                case .success(let s):
                    self.settings.importStatus = "完成：新增 \(s.imported) 条，重复 \(s.duplicates) 条，失败 \(s.failed) 条"
                case .failure(let error):
                    self.settings.importStatus = "失败：\(error)"
                }
                self.store.prune(limit: max(Prefs.historyLimit, 100))
                self.settings.itemCount = self.store.count()
                self.reloadAll()
            }
        }
    }
}
