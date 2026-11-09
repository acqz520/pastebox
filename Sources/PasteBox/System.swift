import AppKit
import ApplicationServices
import Carbon

// MARK: - Preferences

enum Prefs {
    private static let d = UserDefaults.standard

    static let defaultExcludedApps = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
    ]

    static func registerDefaults() {
        d.register(defaults: [
            "autoPaste": true,
            "historyLimit": 5000,
            "paused": false,
            "excludedApps": defaultExcludedApps,
            "panelWidth": 380.0,
            "panelHeight": 640.0,
        ])
    }

    static var autoPaste: Bool {
        get { d.bool(forKey: "autoPaste") }
        set { d.set(newValue, forKey: "autoPaste") }
    }

    static var historyLimit: Int {
        get { d.integer(forKey: "historyLimit") }
        set { d.set(newValue, forKey: "historyLimit") }
    }

    static var paused: Bool {
        get { d.bool(forKey: "paused") }
        set { d.set(newValue, forKey: "paused") }
    }

    static var excludedApps: [String] {
        get { d.stringArray(forKey: "excludedApps") ?? [] }
        set { d.set(newValue, forKey: "excludedApps") }
    }

    static var panelSize: NSSize {
        get { NSSize(width: d.double(forKey: "panelWidth"), height: d.double(forKey: "panelHeight")) }
        set {
            d.set(Double(newValue.width), forKey: "panelWidth")
            d.set(Double(newValue.height), forKey: "panelHeight")
        }
    }

    static var hotKey: Shortcut {
        get {
            guard let dict = d.dictionary(forKey: "hotKey"),
                  let code = dict["keyCode"] as? Int, let mods = dict["modifiers"] as? Int,
                  let key = dict["key"] as? String else { return .default }
            return Shortcut(keyCode: UInt32(code), modifiers: UInt32(mods), key: key)
        }
        set {
            d.set(["keyCode": Int(newValue.keyCode), "modifiers": Int(newValue.modifiers), "key": newValue.key], forKey: "hotKey")
        }
    }
}

// MARK: - Global hotkey

struct Shortcut: Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, shiftKey, ...).
    var modifiers: UInt32
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), key: "V")

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + key
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Builds a shortcut from a key press; requires at least one of ⌘ ⌃ ⌥.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        guard mods != 0 else { return nil }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let code = Int(event.keyCode)
        let name = Shortcut.specialKeys[code] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? ""
        guard !name.isEmpty else { return nil }
        self.init(keyCode: UInt32(code), modifiers: mods, key: name)
    }

    init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }
}

final class HotKey {
    static let shared = HotKey()

    var action: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.action?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        let id = EventHotKeyID(signature: OSType(0x5042_5853), id: 1) // 'PBXS'
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

// MARK: - Pasting

enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Puts the clip on the general pasteboard and returns the resulting change count.
    static func write(_ items: [[Rep]], plainText: String?) -> Int {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let plainText {
            pb.setString(plainText, forType: .string)
        } else {
            let objects: [NSPasteboardItem] = items.map { reps in
                let item = NSPasteboardItem()
                for rep in reps { item.setData(rep.data, forType: NSPasteboard.PasteboardType(rep.type)) }
                return item
            }
            pb.writeObjects(objects)
        }
        return pb.changeCount
    }

    /// Sends ⌘V to whatever app is frontmost. Needs Accessibility permission.
    static func pressCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        // Ignore keys the user is still physically holding (e.g. ⇧ from the hotkey).
        src?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                        state: .eventSuppressionStateSuppressionInterval)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}

// MARK: - Clipboard watching

final class ClipboardMonitor: NSObject {
    /// Markers set by password managers and other apps that ask not to be recorded
    /// (see nspasteboard.org).
    static let skipMarkers: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
        "com.typeit4me.clipping",
        "Pasteboard generator type",
    ]
    static let maxBytes = 100 * 1024 * 1024

    var onCapture: (([[Rep]], String?) -> Void)?
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    private var ignoredChange = -1

    func start() {
        let t = Timer(timeInterval: 0.4, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Our own writes should not show up as new history entries.
    func ignore(changeCount: Int) {
        ignoredChange = changeCount
        lastChange = changeCount
    }

    @objc private func tick() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        guard lastChange != ignoredChange, !Prefs.paused else { return }

        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.skipMarkers) else { return }
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let bundle, bundle == Bundle.main.bundleIdentifier || Prefs.excludedApps.contains(bundle) { return }

        var total = 0
        let items: [[Rep]] = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                if type.rawValue.hasPrefix("dyn.") && data.isEmpty { return nil }
                total += data.count
                return Rep(type: type.rawValue, data: data)
            }
        }
        guard total <= Self.maxBytes else { return }
        onCapture?(items, bundle)
    }
}
