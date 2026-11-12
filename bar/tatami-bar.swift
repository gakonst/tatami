// tatami-bar: an optional bar for tatami that sits over the macOS menu bar.
//
// Left: an optional logo, the workspaces (click one to switch) and the focused window's
// title. Right: menu-bar apps of your choice, the battery and the clock. Hover anywhere
// but a workspace or an icon for a moment and the bar fades out to show the real menu bar
// underneath; move the mouse away and it comes back. Hidden while the focused window is
// native fullscreen.
//
// It talks to tatami only through its command line: "tatami events --json" for instant
// redraws and "tatami query ... --json" for the rest. Configuration is read from
// ~/.config/tatami/bar.conf (see bar/README.md); without one it follows the system
// appearance. "tatami-bar check" validates the file; SIGHUP reloads it.
import Cocoa
import IOKit.ps

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: Configuration

enum FontDesign: String { case system, rounded, monospaced, serif }

struct BarConfig {
    var background: NSColor = .windowBackgroundColor
    var foreground: NSColor = .labelColor
    var muted: NSColor = .secondaryLabelColor
    var accent: NSColor = .controlAccentColor
    var accentText: NSColor = .white
    var hairline: NSColor = .separatorColor
    var batteryColor: NSColor? = nil      // foreground when unset
    var clockColor: NSColor? = nil        // foreground when unset
    var logoColor: NSColor? = nil         // accent when unset
    var fontSize: CGFloat = 12.5
    var design: FontDesign = .system
    var logo = ""
    var clockFormat = "EEE d MMM  HH:mm"
    var battery = true
    var title = true
    var hoverReveal = true
    var tray: [String] = []
    var tatami = ""

    func font(_ weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: fontSize, weight: weight)
        let d: NSFontDescriptor.SystemDesign
        switch design {
        case .system: return base
        case .rounded: d = .rounded
        case .monospaced: d = .monospaced
        case .serif: d = .serif
        }
        guard let desc = base.fontDescriptor.withDesign(d) else { return base }
        return NSFont(descriptor: desc, size: fontSize) ?? base
    }

    static var path: String { NSHomeDirectory() + "/.config/tatami/bar.conf" }

    // Line-based like tatami.conf: "<key> <value>", "#" starts a comment. A line with an
    // error is reported and skipped; the rest of the file still applies.
    static func load() -> (BarConfig, [String]) {
        var c = BarConfig()
        var errors: [String] = []
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return (c, []) }
        for (n, raw) in text.components(separatedBy: "\n").enumerated() {
            // A comment is a line starting with "#", or " # ..." after a value: "#f8f3ea" is a colour.
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if let c = line.range(of: #"\s#(\s|$)"#, options: .regularExpression) { line = String(line[..<c.lowerBound]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let key = parts[0]
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            if let e = c.set(key, value) { errors.append("\(path):\(n + 1): \(e)") }
        }
        return (c, errors)
    }

    static func color(_ v: String) -> NSColor?? {
        if v == "system" { return .some(nil) }
        var h = v.hasPrefix("#") ? String(v.dropFirst()) : v
        if h.count == 6 { h += "ff" }
        guard h.count == 8, let n = UInt32(h, radix: 16) else { return nil }
        return .some(NSColor(srgbRed: CGFloat((n >> 24) & 0xff) / 255, green: CGFloat((n >> 16) & 0xff) / 255,
                             blue: CGFloat((n >> 8) & 0xff) / 255, alpha: CGFloat(n & 0xff) / 255))
    }

    static func flag(_ v: String) -> Bool? { ["on": true, "off": false, "yes": true, "no": false, "true": true, "false": false][v] }

    mutating func set(_ key: String, _ v: String) -> String? {
        let defaults = BarConfig()
        func col(_ apply: (NSColor?) -> Void) -> String? {
            guard let c = BarConfig.color(v) else { return "\(key): expected #rrggbb, #rrggbbaa or system, got '\(v)'" }
            apply(c); return nil
        }
        func bool(_ apply: (Bool) -> Void) -> String? {
            guard let b = BarConfig.flag(v) else { return "\(key): expected on or off, got '\(v)'" }
            apply(b); return nil
        }
        switch key {
        case "background": return col { background = $0 ?? defaults.background }
        case "foreground": return col { foreground = $0 ?? defaults.foreground }
        case "muted": return col { muted = $0 ?? defaults.muted }
        case "accent": return col { accent = $0 ?? defaults.accent }
        case "accent-text": return col { accentText = $0 ?? defaults.accentText }
        case "hairline": return col { hairline = $0 ?? defaults.hairline }
        case "battery-color": return col { batteryColor = $0 }
        case "clock-color": return col { clockColor = $0 }
        case "logo-color": return col { logoColor = $0 }
        case "font-size":
            guard let s = Double(v), s >= 8, s <= 24 else { return "font-size: expected a number from 8 to 24, got '\(v)'" }
            fontSize = CGFloat(s)
        case "font":
            guard let d = FontDesign(rawValue: v) else { return "font: expected system, rounded, monospaced or serif, got '\(v)'" }
            design = d
        case "logo": logo = v
        case "clock": clockFormat = v
        case "battery": return bool { battery = $0 }
        case "title": return bool { title = $0 }
        case "hover-reveal": return bool { hoverReveal = $0 }
        case "tray":
            guard !v.isEmpty, !v.contains(" ") else { return "tray: expected one bundle identifier or tailscale, got '\(v)'" }
            tray.append(v)
        case "tatami": tatami = (v as NSString).expandingTildeInPath
        default: return "unknown key '\(key)'"
        }
        return nil
    }
}

// MARK: Drawing

struct Workspace { let index: Int; let focused: Bool; let label: String }
// A menu-bar app shown in the bar: its icon, an optional status dot and text.
struct TrayItem { let id: String; let icon: NSImage; let dot: NSColor?; let text: String }

final class BarView: NSView {
    var cfg = BarConfig()
    var workspaces: [Workspace] = []
    var title = ""
    var status = ""
    var battery = ""
    var leftLimit: CGFloat = 800
    var boxes: [(NSRect, Int)] = []
    var tray: [TrayItem] = []
    var trayRects: [(NSRect, String)] = []
    var onPick: ((Int) -> Void)?
    var onHover: ((Bool) -> Void)?
    var onTray: ((String) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    func overBox(_ event: NSEvent) -> Int? {
        let p = convert(event.locationInWindow, from: nil)
        return boxes.first { $0.0.insetBy(dx: -2, dy: -6).contains(p) }?.1
    }
    func overTray(_ event: NSEvent) -> String? {
        let p = convert(event.locationInWindow, from: nil)
        return trayRects.first { $0.0.insetBy(dx: -4, dy: -6).contains(p) }?.1
    }
    func outside(_ event: NSEvent) -> Bool { overBox(event) == nil && overTray(event) == nil }
    override func mouseEntered(with event: NSEvent) { onHover?(outside(event)) }
    override func mouseMoved(with event: NSEvent) { onHover?(outside(event)) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func mouseDown(with event: NSEvent) {
        if let n = overBox(event) { onPick?(n) } else if let id = overTray(event) { onTray?(id) }
    }

    func midY(_ h: CGFloat) -> CGFloat { ((bounds.height - h) / 2).rounded() }

    override func draw(_ dirty: NSRect) {
        let bold = cfg.font(.bold), text = cfg.font(.medium)
        cfg.background.setFill()
        bounds.fill()
        cfg.hairline.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        boxes = []
        let bh: CGFloat = min(bounds.height - 10, 22)
        let by = midY(bh)
        var x: CGFloat = 12
        if !cfg.logo.isEmpty {
            let logo = NSAttributedString(string: cfg.logo, attributes: [.font: bold, .foregroundColor: cfg.logoColor ?? cfg.accent])
            let ls = logo.size()
            logo.draw(at: NSPoint(x: x, y: midY(ls.height)))
            x += ls.width + 12
        }
        for w in workspaces {
            let name = w.label.isEmpty ? "\(w.index)" : "\(w.index):\(w.label)"
            let s = NSAttributedString(string: name, attributes: [
                .font: bold, .foregroundColor: w.focused ? cfg.accentText : cfg.foreground])
            let size = s.size()
            let rect = NSRect(x: x, y: by, width: max(bh + 4, (size.width + 16).rounded()), height: bh)
            let pill = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)
            if w.focused {
                cfg.accent.setFill()
                pill.fill()
            } else {
                cfg.muted.setStroke()
                pill.lineWidth = 1.5
                pill.stroke()
            }
            s.draw(at: NSPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded()))
            boxes.append((rect, w.index))
            x = rect.maxX + 5
        }
        x += 12
        if cfg.title {
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byTruncatingTail
            let t = NSAttributedString(string: title, attributes: [
                .font: text, .foregroundColor: cfg.foreground, .paragraphStyle: para])
            let th = t.size().height
            let maxW = leftLimit - x - 16
            if maxW > 30 {
                t.draw(with: NSRect(x: x, y: midY(th), width: maxW, height: th),
                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
        let r = NSMutableAttributedString()
        if cfg.battery && !battery.isEmpty {
            r.append(NSAttributedString(string: battery, attributes: [.font: text, .foregroundColor: cfg.batteryColor ?? cfg.foreground]))
            if !status.isEmpty { r.append(NSAttributedString(string: "   ·   ", attributes: [.font: text, .foregroundColor: cfg.muted])) }
        }
        r.append(NSAttributedString(string: status, attributes: [.font: bold, .foregroundColor: cfg.clockColor ?? cfg.foreground]))
        let rs = r.size()
        r.draw(at: NSPoint(x: bounds.width - rs.width - 12, y: midY(rs.height)))
        trayRects = []
        var limit = bounds.width - rs.width - 12 - (rs.width > 0 ? 18 : 0)
        for item in tray.reversed() {
            let label = NSAttributedString(string: item.text, attributes: [.font: text, .foregroundColor: cfg.muted])
            let lw = item.text.isEmpty ? 0 : label.size().width + 5
            let dw: CGFloat = item.dot == nil ? 0 : 9
            let w = 16 + dw + lw
            let x0 = limit - w
            let icon = NSRect(x: x0, y: midY(16), width: 16, height: 16)
            item.icon.draw(in: icon)
            if let dot = item.dot {
                dot.setFill()
                NSBezierPath(ovalIn: NSRect(x: icon.maxX + 3, y: (bounds.height / 2 - 3).rounded(), width: 6, height: 6)).fill()
            }
            if lw > 0 { label.draw(at: NSPoint(x: icon.maxX + dw + 5, y: midY(label.size().height))) }
            trayRects.append((NSRect(x: x0, y: 0, width: w, height: bounds.height), item.id))
            limit = x0 - 14
        }
    }
}

final class ActionItem: NSMenuItem {
    let run: () -> Void
    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { DispatchQueue.global().async { self.run() } }
}

// MARK: Tray

// "tray tailscale" gets its own menu built from the Tailscale CLI, with a status dot and
// the exit node in use. Any other entry is a bundle identifier: its icon, and a click
// presses that app's real menu-bar item (needs the Accessibility permission).
final class Tray {
    static let tailscaleBundles = ["io.tailscale.ipn.macsys", "io.tailscale.ipn.macos"]
    var icons: [String: NSImage] = [:]
    var tsStatus: [String: Any] = [:]

    lazy var tsCLI: String? = {
        let candidates = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    func bundle(_ id: String) -> String {
        if id != "tailscale" { return id }
        return Tray.tailscaleBundles.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? Tray.tailscaleBundles[0]
    }

    func icon(_ id: String) -> NSImage {
        let b = bundle(id)
        if let i = icons[b] { return i }
        var i = NSImage(size: NSSize(width: 16, height: 16))
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: b) { i = NSWorkspace.shared.icon(forFile: url.path) }
        icons[b] = i
        return i
    }

    func extrasItem(_ bundle: String) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXExtrasMenuBar" as CFString, &bar) == .success, let b = bar else { return nil }
        var kids: CFTypeRef?
        AXUIElementCopyAttributeValue(b as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
        return (kids as? [AXUIElement])?.first
    }

    func pressReal(_ bundle: String, then: @escaping () -> Void) {
        if let item = extrasItem(bundle) {
            // Pressing a menu-bar item can block until its menu closes: keep it off the main thread.
            DispatchQueue.global().async {
                _ = AXUIElementPerformAction(item, kAXPressAction as CFString)
                DispatchQueue.main.async(execute: then)
            }
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    func tsRun(_ args: [String]) -> Data {
        guard let cli = tsCLI else { return Data() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cli)
        p.arguments = args
        // The app's binary is the GUI unless told to act as the CLI.
        p.environment = ["TAILSCALE_BE_CLI": "1"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return Data() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    // Called off the main thread.
    func tailscaleState(_ cfg: BarConfig) -> (NSColor?, String) {
        guard let d = (try? JSONSerialization.jsonObject(with: tsRun(["status", "--json"]))) as? [String: Any] else {
            tsStatus = [:]
            return (cfg.muted, "")
        }
        tsStatus = d
        let peers = (d["Peer"] as? [String: [String: Any]] ?? [:]).values
        let exit = peers.first { $0["ExitNode"] as? Bool ?? false }?["HostName"] as? String ?? ""
        if d["BackendState"] as? String != "Running" { return (cfg.muted, "off") }
        return (NSColor.systemGreen, exit.isEmpty ? "" : "↗ \(exit)")
    }

    func tailscaleMenu(in view: NSView, at rect: NSRect, refresh: @escaping () -> Void) {
        let d = tsStatus
        let running = d["BackendState"] as? String == "Running"
        let me = d["Self"] as? [String: Any] ?? [:]
        let ip = (me["TailscaleIPs"] as? [String])?.first ?? ""
        let tailnet = (d["CurrentTailnet"] as? [String: Any])?["Name"] as? String ?? ""
        let peers = Array((d["Peer"] as? [String: [String: Any]] ?? [:]).values)
        let menu = NSMenu()
        menu.autoenablesItems = false
        let head = NSMenuItem(title: running ? "Connected · \(tailnet)" : "Disconnected", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(ActionItem(running ? "Disconnect" : "Connect") {
            _ = self.tsRun([running ? "down" : "up"]); DispatchQueue.main.async(execute: refresh)
        })
        menu.addItem(.separator())
        if !ip.isEmpty {
            menu.addItem(ActionItem("This device: \(me["HostName"] as? String ?? "") (\(ip))") {
                DispatchQueue.main.async { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ip, forType: .string) }
            })
        }
        let exits = peers.filter { $0["ExitNodeOption"] as? Bool ?? false }
            .sorted { ($0["HostName"] as? String ?? "") < ($1["HostName"] as? String ?? "") }
        let current = peers.first { $0["ExitNode"] as? Bool ?? false }
        let exitMenu = NSMenu()
        exitMenu.autoenablesItems = false
        let none = ActionItem("None") { _ = self.tsRun(["set", "--exit-node="]); DispatchQueue.main.async(execute: refresh) }
        none.state = current == nil ? .on : .off
        exitMenu.addItem(none)
        if !exits.isEmpty { exitMenu.addItem(.separator()) }
        for e in exits {
            let name = e["HostName"] as? String ?? "?"
            let target = (e["TailscaleIPs"] as? [String])?.first ?? name
            let item = ActionItem(name + ((e["Online"] as? Bool ?? false) ? "" : "  (offline)")) {
                _ = self.tsRun(["set", "--exit-node=\(target)"]); DispatchQueue.main.async(execute: refresh)
            }
            item.state = (e["ExitNode"] as? Bool ?? false) ? .on : .off
            exitMenu.addItem(item)
        }
        let exitItem = NSMenuItem(title: "Exit node" + (current.map { ": \($0["HostName"] as? String ?? "")" } ?? ""), action: nil, keyEquivalent: "")
        exitItem.submenu = exitMenu
        menu.addItem(exitItem)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Admin console") { NSWorkspace.shared.open(URL(string: "https://login.tailscale.com/admin/machines")!) })
        menu.addItem(ActionItem("Tailscale's own menu…") { DispatchQueue.main.async { self.pressReal(self.bundle("tailscale"), then: refresh) } })
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: -4), in: view)
    }
}

// MARK: The bar

final class Bar: NSObject, NSApplicationDelegate {
    var cfg = BarConfig()
    var tatami = ""
    var panel: NSPanel!
    var view: BarView!
    let tray = Tray()
    var pending = false
    var hoverHidden = false
    var fullscreenHidden = false
    var hoverTimer: Timer?
    var barHeight: CGFloat = 32
    var screenTop: CGFloat = 0
    var hup: DispatchSourceSignal?

    func loadConfig() {
        let (c, errors) = BarConfig.load()
        for e in errors { log(e) }
        cfg = c
        let candidates = [cfg.tatami, NSHomeDirectory() + "/.local/bin/tatami",
                          (CommandLine.arguments[0] as NSString).deletingLastPathComponent + "/tatami",
                          "/opt/homebrew/bin/tatami", "/usr/local/bin/tatami"]
        tatami = candidates.first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[1]
        view?.cfg = cfg
        view?.needsDisplay = true
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        view = BarView()
        loadConfig()
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = view
        view.onPick = { n in self.show(n); DispatchQueue.global().async { _ = self.run(["workspace", "\(n)"]) } }
        view.onHover = { outside in self.hover(outside) }
        view.onTray = { id in self.pressTray(id) }
        layout()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { _ in self.layout() }
        // Light and dark mode: the default colours are the system's dynamic ones.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                            object: nil, queue: .main) { _ in self.view.needsDisplay = true }
        signal(SIGHUP, SIG_IGN)
        hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        hup?.setEventHandler { self.loadConfig(); self.updateStatus(); self.updateTray(); self.refresh() }
        hup?.resume()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in self.tick() }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in self.updateStatus() }
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in self.updateTray() }
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in self.schedule() }
        updateStatus()
        updateTray()
        refresh()
        Thread { self.follow() }.start()
    }

    func layout() {
        guard let s = NSScreen.screens.first else { return }
        var h = s.frame.maxY - s.visibleFrame.maxY
        if h < 20 { h = 32 }
        barHeight = h
        screenTop = s.frame.maxY
        panel.setFrame(NSRect(x: s.frame.minX, y: s.frame.maxY - h, width: s.frame.width, height: h), display: true)
        view.leftLimit = s.auxiliaryTopLeftArea?.width ?? s.frame.width * 0.5
        view.needsDisplay = true
    }

    func apply() {
        let hide = hoverHidden || fullscreenHidden
        panel.alphaValue = hide ? 0 : 1
        panel.ignoresMouseEvents = hide
    }

    func hover(_ outside: Bool) {
        guard cfg.hoverReveal else { return }
        if !outside { hoverTimer?.invalidate(); hoverTimer = nil; return }
        if hoverTimer != nil || hoverHidden { return }
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in
            self.hoverTimer = nil
            self.hoverHidden = true
            self.apply()
        }
    }

    func tick() {
        guard hoverHidden else { return }
        if NSEvent.mouseLocation.y < screenTop - barHeight - 6 {
            hoverHidden = false
            apply()
        }
    }

    func updateTray() {
        let cfg = self.cfg
        DispatchQueue.global().async {
            let ts = cfg.tray.contains("tailscale") ? self.tray.tailscaleState(cfg) : (nil, "")
            DispatchQueue.main.async {
                self.view.tray = cfg.tray.map { id in
                    id == "tailscale" ? TrayItem(id: id, icon: self.tray.icon(id), dot: ts.0, text: ts.1)
                                      : TrayItem(id: id, icon: self.tray.icon(id), dot: nil, text: "")
                }
                self.view.needsDisplay = true
            }
        }
    }

    func pressTray(_ id: String) {
        if id == "tailscale", let r = view.trayRects.first(where: { $0.1 == id })?.0 {
            tray.tailscaleMenu(in: view, at: r) { self.updateTray() }
            return
        }
        tray.pressReal(tray.bundle(id)) { self.updateTray() }
    }

    func battery() -> String {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return "" }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let cap = d[kIOPSCurrentCapacityKey] as? Int else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            return "\(charging ? "⚡︎ " : "")\(cap)%"
        }
        return ""
    }

    func updateStatus() {
        let f = DateFormatter()
        f.dateFormat = cfg.clockFormat
        view.battery = battery()
        view.status = cfg.clockFormat.isEmpty ? "" : f.string(from: Date())
        view.needsDisplay = true
    }

    func run(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tatami)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    func json(_ args: [String]) -> [String: Any]? {
        guard let d = run(args) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    // Follows "tatami events --json" and redraws on every event; restarts it if it exits.
    func follow() {
        while true {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tatami)
            p.arguments = ["events", "--json"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            var buffer = Data()
            out.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { return }
                buffer.append(chunk)
                var lines: [Data] = []
                while let nl = buffer.firstIndex(of: 0x0a) {
                    lines.append(buffer.subdata(in: buffer.startIndex..<nl))
                    buffer.removeSubrange(buffer.startIndex...nl)
                }
                let events = lines.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
                DispatchQueue.main.async {
                    for e in events { self.handle(e) }
                    self.schedule()
                }
            }
            if (try? p.run()) != nil { p.waitUntilExit() }
            out.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { self.schedule() }
            sleep(2)
        }
    }

    func schedule() {
        if pending { return }
        pending = true
        DispatchQueue.main.async {
            self.pending = false
            self.refresh()
        }
    }

    // Draw the new workspace at once from the event itself; refresh() fills in the rest.
    func handle(_ event: [String: Any]) {
        guard event["type"] as? String == "workspace_changed", let n = event["workspace"] as? Int else { return }
        show(n)
    }

    func show(_ n: Int) {
        var list = view.workspaces.map { Workspace(index: $0.index, focused: $0.index == n, label: $0.label) }
        if !list.contains(where: { $0.index == n }) {
            list.append(Workspace(index: n, focused: true, label: ""))
            list.sort { $0.index < $1.index }
        }
        view.workspaces = list
        view.display()
    }

    func refresh() {
        guard let ws = json(["query", "workspaces", "--json"])?["workspaces"] as? [[String: Any]] else {
            view.workspaces = []
            view.title = "tatami is not running"
            fullscreenHidden = false
            apply()
            view.needsDisplay = true
            return
        }
        view.workspaces = ws.map {
            Workspace(index: $0["index"] as? Int ?? 0, focused: $0["focused"] as? Bool ?? false,
                      label: $0["label"] as? String ?? "")
        }.sorted { $0.index < $1.index }
        var title = ""
        var fullscreen = false
        if let windows = json(["query", "windows", "--json"])?["windows"] as? [[String: Any]],
           let w = windows.first(where: { $0["focused"] as? Bool ?? false }) {
            let app = w["app"] as? String ?? ""
            let t = w["title"] as? String ?? ""
            title = t.isEmpty ? app : (t.contains(app) ? t : "\(app) — \(t)")
            fullscreen = w["fullscreen"] as? Bool ?? false
        }
        view.title = title
        fullscreenHidden = fullscreen
        apply()
        view.display()
    }
}

if CommandLine.arguments.count > 1 {
    switch CommandLine.arguments[1] {
    case "check":
        let (_, errors) = BarConfig.load()
        for e in errors { print(e) }
        print(errors.isEmpty ? "\(BarConfig.path): ok" : "\(errors.count) error(s); those lines are skipped")
        exit(errors.isEmpty ? 0 : 1)
    default:
        print("usage: tatami-bar [check]\n  reads \(BarConfig.path); kill -HUP reloads it")
        exit(CommandLine.arguments[1] == "help" || CommandLine.arguments[1] == "--help" ? 0 : 2)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let bar = Bar()
app.delegate = bar
app.run()
