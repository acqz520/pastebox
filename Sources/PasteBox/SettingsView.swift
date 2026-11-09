import AppKit
import ServiceManagement
import SwiftUI

final class SettingsModel: ObservableObject {
    @Published var shortcut = Prefs.hotKey
    @Published var hotKeyOK = true
    @Published var recording = false
    @Published var autoPaste = Prefs.autoPaste { didSet { Prefs.autoPaste = autoPaste } }
    @Published var paused = Prefs.paused { didSet { Prefs.paused = paused } }
    @Published var historyLimit = Prefs.historyLimit { didSet { Prefs.historyLimit = historyLimit; onPrune() } }
    @Published var excludedText = Prefs.excludedApps.joined(separator: "\n") {
        didSet {
            Prefs.excludedApps = excludedText.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
    }
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var trusted = Paster.isTrusted
    @Published var importStatus: String?
    @Published var importing = false
    @Published var itemCount = 0

    var onShortcut: (Shortcut?) -> Bool = { _ in true }
    var onImport: () -> Void = {}
    var onClear: () -> Void = {}
    var onPrune: () -> Void = {}
    var countItems: () -> Int = { 0 }
    var dataDirectory: URL?

    private var recorder: Any?

    func refresh() {
        paused = Prefs.paused
        trusted = Paster.isTrusted
        launchAtLogin = SMAppService.mainApp.status == .enabled
        itemCount = countItems()
    }

    func startRecording() {
        guard recorder == nil else { return }
        recording = true
        _ = onShortcut(nil) // release the current combo so it can be pressed again
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // Esc
                self.stopRecording(with: nil)
            } else if let s = Shortcut(event: event) {
                self.stopRecording(with: s)
            }
            return nil
        }
    }

    func stopRecording(with shortcut: Shortcut?) {
        if let recorder { NSEvent.removeMonitor(recorder) }
        recorder = nil
        recording = false
        if let shortcut { self.shortcut = shortcut }
        hotKeyOK = onShortcut(self.shortcut)
        if hotKeyOK { Prefs.hotKey = self.shortcut }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("呼出快捷键")
                    Spacer()
                    Button(model.recording ? "请按下新组合键…" : model.shortcut.display) {
                        model.recording ? model.stopRecording(with: nil) : model.startRecording()
                    }
                    .frame(minWidth: 120)
                }
                if !model.hotKeyOK {
                    Text("快捷键注册失败，可能被其它应用（如 PasteNow）占用，请换一个或先退出它。")
                        .font(.caption).foregroundStyle(.red)
                }
                Toggle("选中后自动粘贴到当前应用", isOn: $model.autoPaste)
                Toggle("暂停记录剪贴板", isOn: $model.paused)
                Toggle("开机自动启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            }

            Section("辅助功能权限") {
                HStack {
                    Image(systemName: model.trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.trusted ? .green : .orange)
                    Text(model.trusted ? "已授权，可以自动粘贴" : "未授权：只能复制，不能自动粘贴")
                    Spacer()
                    if !model.trusted {
                        Button("去授权") { Paster.openAccessibilitySettings() }
                    }
                    Button("重新检测") { model.refresh() }
                }
            }

            Section("历史") {
                Picker("最多保留", selection: $model.historyLimit) {
                    ForEach([1000, 5000, 10000, 50000], id: \.self) { Text("\($0) 条").tag($0) }
                }
                Text("加入了分类的条目不受上限影响，不会被自动清理。当前共 \(model.itemCount) 条。")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("不记录这些应用里的复制（每行一个 Bundle ID）")
                    TextEditor(text: $model.excludedText)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(height: 70)
                }
            }

            Section("数据") {
                HStack {
                    Button(model.importing ? "导入中…" : "从 PasteNow 导入历史") { model.onImport() }
                        .disabled(model.importing || !PasteNowImporter.isAvailable)
                    if let status = model.importStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("在访达中显示数据目录") {
                        if let dir = model.dataDirectory { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                    }
                    Spacer()
                    Button("清空历史…", role: .destructive) { confirmClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("清空所有未分类的历史？", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { model.onClear() }
        } message: {
            Text("已加入分类的条目会保留。此操作不能撤销。")
        }
    }
}
