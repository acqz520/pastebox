import AppKit
import SwiftUI

// Headless import check: PasteBox --import-test <empty dir>
if let i = CommandLine.arguments.firstIndex(of: "--import-test"), i + 1 < CommandLine.arguments.count {
    let store = try Store(root: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    let start = Date()
    let summary = try PasteNowImporter.run(into: store) { done, total in
        if done % 500 == 0 || done == total { print("progress \(done)/\(total)") }
    }
    print("summary", summary, String(format: "%.1fs", Date().timeIntervalSince(start)))
    print("kinds", store.kindCounts())
    for row in store.rows(query: "", categoryID: nil, limit: 5) {
        print(row.kind, row.usedAt, row.sourceBundle ?? "-", row.preview.prefix(50).replacingOccurrences(of: "\n", with: "⏎"),
              row.thumbURL != nil ? "thumb \(row.imageWidth)x\(row.imageHeight)" : "")
    }
    exit(0)
}

// Layout check without screen-recording permission: PasteBox --render <out.png> [query]
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    _ = NSApplication.shared
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PasteBox", isDirectory: true)
    let state = AppState(store: try Store(root: root))
    state.trusted = false // show the permission banner too
    if i + 2 < CommandLine.arguments.count { state.query = CommandLine.arguments[i + 2] }
    state.reload(resetSelection: true)
    state.selection = 1
    let host = NSHostingView(rootView: PanelView(state: state))
    host.frame = NSRect(x: 0, y: 0, width: 380, height: 640)
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    host.cacheDisplay(in: host.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    exit(0)
}

// Scroll benchmark on the real history: PasteBox --scroll-bench [steps] [points per step]
if let i = CommandLine.arguments.firstIndex(of: "--scroll-bench") {
    let args = CommandLine.arguments
    let steps = i + 1 < args.count ? Int(args[i + 1]) ?? 300 : 300
    let delta = i + 2 < args.count ? Double(args[i + 2]) ?? 200 : 200
    _ = NSApplication.shared
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PasteBox", isDirectory: true)
    let state = AppState(store: try Store(root: root))
    let r0 = CFAbsoluteTimeGetCurrent()
    state.reload(resetSelection: true)
    let r1 = CFAbsoluteTimeGetCurrent()
    let host = NSHostingView(rootView: PanelView(state: state))
    host.frame = NSRect(x: 0, y: 0, width: 380, height: 640)
    host.layoutSubtreeIfNeeded()
    print(String(format: "open: reload %.1fms  first layout %.1fms  ", (r1 - r0) * 1000, (CFAbsoluteTimeGetCurrent() - r1) * 1000),
          terminator: "")
    let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    func findScroll(_ v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView, s.hasVerticalScroller || s.documentView != nil, s.frame.height > 200 { return s }
        for sub in v.subviews { if let s = findScroll(sub) { return s } }
        return nil
    }
    guard let scroll = findScroll(host) else { print("no scroll view"); exit(1) }
    let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
    var times: [Double] = []
    func cpu() -> Double {
        var u = rusage(); getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    let cpu0 = cpu()
    var heights: [Double] = []
    for _ in 0..<steps {
        let t0 = CFAbsoluteTimeGetCurrent()
        let clip = scroll.contentView
        var p = clip.bounds.origin
        p.y += (scroll.documentView?.isFlipped ?? true) ? delta : -delta
        clip.scroll(to: p)
        scroll.reflectScrolledClipView(clip)
        RunLoop.main.run(until: Date())
        host.layoutSubtreeIfNeeded()
        if ProcessInfo.processInfo.environment["BENCH_DRAW"] != nil { host.cacheDisplay(in: host.bounds, to: rep) }
        times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        heights.append(Double(scroll.documentView?.frame.height ?? 0))
        if ProcessInfo.processInfo.environment["BENCH_TRACE"] != nil, let last = times.last, last > 30 { print(String(format: "  step %d %.0fms rows %d", times.count, last, state.rows.count)) }
    }
    let sorted = times.sorted()
    func pct(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
    // Scroller jumps = the content height changing while scrolling.
    let jumps = zip(heights, heights.dropFirst()).filter { abs($0 - $1) > 0.5 }.count
    print(String(format: "height %.0f→%.0f changed %d times  ", heights.first ?? 0, heights.last ?? 0, jumps), terminator: "")
    print(String(format: "cpu %.0fms  ", (cpu() - cpu0) * 1000), terminator: "")
    print(String(format: "steps %d  p50 %.1fms  p90 %.1fms  p99 %.1fms  max %.1fms  >16ms %d  rows %d  y %.0f",
                 steps, pct(0.5), pct(0.9), pct(0.99), sorted.last ?? 0, times.filter { $0 > 16.7 }.count,
                 state.rows.count, scroll.contentView.bounds.origin.y))
    exit(0)
}

// Write one stored clip back to the pasteboard: PasteBox --write-test <item id>
if let i = CommandLine.arguments.firstIndex(of: "--write-test"), i + 1 < CommandLine.arguments.count,
   let id = Int64(CommandLine.arguments[i + 1]) {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PasteBox", isDirectory: true)
    let store = try Store(root: root)
    guard let row = store.rows(query: "", categoryID: nil, limit: 100_000).first(where: { $0.id == id }) else {
        print("not found")
        exit(1)
    }
    let t0 = CFAbsoluteTimeGetCurrent()
    guard let items = store.payload(row.uuid) else { print("payload missing"); exit(1) }
    let t1 = CFAbsoluteTimeGetCurrent()
    let change = Paster.write(items, plainText: nil)
    let t2 = CFAbsoluteTimeGetCurrent()
    print(String(format: "read %.1fms  write %.1fms", (t1 - t0) * 1000, (t2 - t1) * 1000),
          "changeCount", change, row.kind, items.map { $0.map { "\($0.type):\($0.data.count)" } })
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
