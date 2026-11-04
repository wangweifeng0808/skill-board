import Cocoa
import WebKit

// MARK: - Locations

let home = NSHomeDirectory()
let fm = FileManager.default
let defaults = UserDefaults.standard
let launchAgentLabel = "com.skillboard.skillbar"
let launchAgentPath = home + "/Library/LaunchAgents/\(launchAgentLabel).plist"

// Saved preference, then a few usual spots, then ask.
func resolveToolDir() -> String {
    if let saved = defaults.string(forKey: "toolDir"),
       fm.fileExists(atPath: saved + "/scan_skills.py") {
        return saved
    }
    let candidates = [
        home + "/WorkBuddy/skill-board",
        home + "/skill-board",
        home + "/projects/skill-board",
        home + "/dev/skill-board",
        home + "/code/skill-board",
    ]
    for c in candidates where fm.fileExists(atPath: c + "/scan_skills.py") {
        defaults.set(c, forKey: "toolDir")
        return c
    }
    let panel = NSOpenPanel()
    panel.message = "Choose the skill-board folder (the one containing scan_skills.py)"
    panel.prompt = "Choose"
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
        defaults.set(url.path, forKey: "toolDir")
        return url.path
    }
    return home + "/WorkBuddy/skill-board"
}

let toolDir = resolveToolDir()
let scriptPath = toolDir + "/scan_skills.py"

// board path comes from config.json
func boardOutputPath() -> String {
    guard let data = fm.contents(atPath: toolDir + "/config.json"),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let outputs = obj["outputs"] as? [String: Any],
          let raw = outputs["board"] as? String
    else { return home + "/Desktop/Skill Board.html" }
    let expanded = (raw as NSString).expandingTildeInPath
    return expanded.hasPrefix("/") ? expanded : toolDir + "/" + expanded
}

let popPath = toolDir + "/dist/popover.html"
let fullPath = boardOutputPath()
let pyPath: String = {
    for p in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
    where FileManager.default.isExecutableFile(atPath: p) { return p }
    return "/usr/bin/python3"
}()

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var web: WKWebView!
    var scanning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        if !fm.fileExists(atPath: popPath) { scan(notify: false) }
        if !fm.fileExists(atPath: launchAgentPath) { installLaunchAgent() }

        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.togglePopover(nil) }
        }
    }

    // MARK: Menu bar

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let img = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Skill Board")?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        button.image = img
        button.toolTip = "Skill Board"
        button.target = self
        button.action = #selector(statusClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover(sender)
        }
    }

    func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Rescan", action: #selector(refreshAction), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open full board", action: #selector(openFull), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Open project folder", action: #selector(openFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Change project folder…", action: #selector(chooseFolder), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let launch = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        launch.target = self
        launch.state = fm.fileExists(atPath: launchAgentPath) ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    // MARK: Popover

    func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        let conf = WKWebViewConfiguration()
        conf.userContentController.add(self, name: "board")
        conf.preferences.setValue(true, forKey: "developerExtrasEnabled")

        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 620, height: 600), configuration: conf)
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.underPageBackgroundColor = .windowBackgroundColor

        popover.contentSize = NSSize(width: 620, height: 600)
        let vc = NSViewController()
        vc.view = web
        vc.preferredContentSize = NSSize(width: 620, height: 600)
        popover.contentViewController = vc
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            loadPopover()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            scan(notify: true)
        }
    }

    func loadPopover() {
        let url = URL(fileURLWithPath: popPath)
        web.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: toolDir))
    }

    func popoverDidClose(_ notification: Notification) {}

    // MARK: Scan

    func scan(notify: Bool) {
        guard !scanning else { return }
        scanning = true
        let before = fileModDate(popPath)
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pyPath)
            p.arguments = [scriptPath, "--quiet"]
            p.currentDirectoryURL = URL(fileURLWithPath: toolDir)
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            do { try p.run(); p.waitUntilExit() } catch { }
            DispatchQueue.main.async {
                self.scanning = false
                let after = self.fileModDate(popPath)
                if notify, let b = before, let a = after, a > b {
                    self.loadPopover()
                }
            }
        }
    }

    func fileModDate(_ path: String) -> Date? {
        (try? fm.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    // MARK: Actions

    @objc func refreshAction() { scan(notify: true) }

    @objc func openFull() { NSWorkspace.shared.open(URL(fileURLWithPath: fullPath)) }

    @objc func openFolder() { NSWorkspace.shared.open(URL(fileURLWithPath: toolDir)) }

    @objc func chooseFolder() {
        let panel = NSOpenPanel()
        panel.message = "Choose the skill-board folder (the one containing scan_skills.py)"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            defaults.set(url.path, forKey: "toolDir")
            let alert = NSAlert()
            alert.messageText = "Folder updated"
            alert.informativeText = "Restart the app to apply."
            alert.runModal()
        }
    }

    @objc func toggleLogin() {
        if fm.fileExists(atPath: launchAgentPath) {
            try? fm.removeItem(atPath: launchAgentPath)
        } else {
            installLaunchAgent()
        }
    }

    func installLaunchAgent() {
        let exe = Bundle.main.executablePath ?? (home + "/Applications/SkillBar.app/Contents/MacOS/SkillBar")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(launchAgentLabel)</string>
          <key>ProgramArguments</key><array><string>\(exe)</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><false/>
        </dict>
        </plist>
        """
        try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
    }

    // MARK: JS bridge

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let cmd = message.body as? String else { return }
        switch cmd {
        case "refresh": scan(notify: true)
        case "open-full": openFull()
        case "close": popover.performClose(nil)
        default: break
        }
    }
}

// Prevent LaunchAgent + manual launch from running two copies
let selfPid = ProcessInfo.processInfo.processIdentifier
let twins = NSRunningApplication.runningApplications(withBundleIdentifier: "com.skillboard.skillbar")
    .filter { $0.processIdentifier != selfPid }
if !twins.isEmpty { exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
