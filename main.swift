import Cocoa
import ApplicationServices

// ── Constants ─────────────────────────────────────────────────────────────────

let MEETING_STATUS_FILE = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".teams-obs-meeting.json")
let OBS_STATUS_FILE = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".teams-obs-status.json")
let SWIFT_LOG_FILE = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".teams-obs-swift.log")
let RECORDINGS_DIR = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Movies/OBS")

func swiftLog(_ msg: String) {
    let fmt = DateFormatter()
    fmt.dateFormat = "HH:mm:ss"
    let line = "[\(fmt.string(from: Date()))] \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let fh = try? FileHandle(forWritingTo: SWIFT_LOG_FILE) {
        fh.seekToEndOfFile()
        fh.write(data)
        try? fh.close()
    } else {
        try? data.write(to: SWIFT_LOG_FILE)
    }
}

// ── Recording model ───────────────────────────────────────────────────────────

struct Recording {
    let url: URL
    let name: String
    let size: Int64
    let modDate: Date

    var formattedSize: String {
        let mb = Double(size) / 1_048_576
        if mb >= 1000 { return String(format: "%.1f GB", mb / 1024) }
        return String(format: "%.1f MB", mb)
    }
}

// ── Recordings Table ──────────────────────────────────────────────────────────

class RecordingsDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var recordings: [Recording] = []
    weak var tableView: NSTableView?

    func reload() {
        recordings = loadRecordings()
        tableView?.reloadData()
    }

    private func loadRecordings() -> [Recording] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: RECORDINGS_DIR,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items
            .filter { ["mp4", "mkv", "mov"].contains($0.pathExtension.lowercased()) }
            .compactMap { url -> Recording? in
                guard
                    let res = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                    let size = res.fileSize,
                    let mod = res.contentModificationDate
                else { return nil }
                return Recording(url: url, name: url.lastPathComponent, size: Int64(size), modDate: mod)
            }
            .sorted { $0.modDate > $1.modDate }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { recordings.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rec = recordings[row]
        switch tableColumn?.identifier.rawValue {
        case "name":
            let cell = NSTextField(labelWithString: rec.name)
            cell.font = .systemFont(ofSize: 12)
            cell.textColor = .labelColor
            cell.lineBreakMode = .byTruncatingMiddle
            return cell
        case "size":
            let cell = NSTextField(labelWithString: rec.formattedSize)
            cell.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            cell.textColor = .secondaryLabelColor
            cell.alignment = .right
            return cell
        case "play":
            let btn = NSButton(title: "▶ Play", target: self, action: #selector(playClicked(_:)))
            btn.bezelStyle = .rounded
            btn.font = .systemFont(ofSize: 11)
            btn.tag = row
            return btn
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 26 }

    @objc func playClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row < recordings.count else { return }
        NSWorkspace.shared.open(recordings[row].url)
    }
}

// ── Status Window ─────────────────────────────────────────────────────────────

class StatusWindowController: NSWindowController {
    private var statusLabel: NSTextField!
    private var meetingLabel: NSTextField!
    private var recordingsDataSource = RecordingsDataSource()
    private var tableView: NSTableView!
    private var timer: Timer?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Teams OBS Auto-Record"
        window.center()
        window.setFrameAutosaveName("StatusWindow")
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        statusLabel = NSTextField(labelWithString: "Status: Starting...")
        statusLabel.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .systemGray
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(statusLabel)

        meetingLabel = NSTextField(labelWithString: "Meeting: None")
        meetingLabel.font = .systemFont(ofSize: 13)
        meetingLabel.textColor = .secondaryLabelColor
        meetingLabel.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(meetingLabel)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(divider)

        let recHeader = NSTextField(labelWithString: "Recordings")
        recHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        recHeader.textColor = .secondaryLabelColor
        recHeader.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(recHeader)

        tableView = NSTableView()
        if #available(macOS 11.0, *) { tableView.style = .plain }
        tableView.rowHeight = 26
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = true
        tableView.doubleAction = #selector(tableDoubleClicked)
        tableView.target = self

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 200
        nameCol.width = 320
        tableView.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.minWidth = 60
        sizeCol.width = 80
        sizeCol.resizingMask = .userResizingMask
        tableView.addTableColumn(sizeCol)

        let playCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("play"))
        playCol.title = ""
        playCol.minWidth = 70
        playCol.width = 70
        playCol.maxWidth = 70
        playCol.resizingMask = []
        tableView.addTableColumn(playCol)

        recordingsDataSource.tableView = tableView
        tableView.dataSource = recordingsDataSource
        tableView.delegate = recordingsDataSource

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(scrollView)

        let quitBtn = NSButton(title: "Quit", target: self, action: #selector(quitApp))
        quitBtn.bezelStyle = .rounded
        quitBtn.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(quitBtn)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: cv.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            meetingLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            meetingLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            meetingLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            divider.topAnchor.constraint(equalTo: meetingLabel.bottomAnchor, constant: 12),
            divider.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            recHeader.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            recHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),

            scrollView.topAnchor.constraint(equalTo: recHeader.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: quitBtn.topAnchor, constant: -12),

            quitBtn.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
            quitBtn.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
        ])
    }

    func startPolling() {
        updateStatus()
        recordingsDataSource.reload()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
            self?.recordingsDataSource.reload()
        }
    }

    private func updateStatus() {
        guard let data = try? Data(contentsOf: OBS_STATUS_FILE),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            statusLabel.stringValue = "Status: Starting..."
            statusLabel.textColor = .systemGray
            meetingLabel.stringValue = "Meeting: None"
            return
        }
        let recording = json["recording"] as? Bool ?? false
        let inMeeting = json["in_meeting"] as? Bool ?? false
        let meeting = json["meeting"] as? String ?? "None"
        if recording {
            statusLabel.stringValue = "Status: Recording"
            statusLabel.textColor = .systemGreen
        } else if inMeeting {
            statusLabel.stringValue = "Status: Starting recording..."
            statusLabel.textColor = .systemOrange
        } else {
            statusLabel.stringValue = "Status: Monitoring Teams..."
            statusLabel.textColor = .systemGray
        }
        meetingLabel.stringValue = "Meeting: \(meeting)"
    }

    @objc private func tableDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < recordingsDataSource.recordings.count else { return }
        NSWorkspace.shared.open(recordingsDataSource.recordings[row].url)
    }

    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}

// ── Meeting Detector ──────────────────────────────────────────────────────────

class MeetingDetector {
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.detectMeeting()
        }
        detectMeeting()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func isMeetingWindow(_ title: String) -> Bool {
        // Explicit non-meeting prefixes — Teams navigation/activity views
        let nonMeetingPrefixes = [
            "Chat |", "Activity |", "Calendar |",
            "Teams and Channels |", "Calls |", "Files |", "Apps |",
            "Sharing Indicator", "Sharing control bar |"
        ]
        if nonMeetingPrefixes.contains(where: { title.hasPrefix($0) }) { return false }

        // Definitely a meeting
        if title.hasPrefix("Meeting compact view |") { return true }
        if title.hasPrefix("Call |") { return true }

        // Any other window ending with "| Microsoft Teams" is a meeting
        // (channel meetings, direct calls, etc.)
        if title.hasSuffix("| Microsoft Teams") { return true }

        return false
    }

    private func extractMeetingName(_ title: String) -> String {
        var name = title
        // Remove "Meeting compact view | " prefix
        if name.hasPrefix("Meeting compact view | ") {
            name = String(name.dropFirst("Meeting compact view | ".count))
        }
        // Take first segment before " | "
        let parts = name.components(separatedBy: " | ")
        return parts.first?.trimmingCharacters(in: .whitespaces) ?? name
    }

    private func detectMeeting() {
        var inMeeting = false
        var meetingName = ""

        let teamsApps = NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == "com.microsoft.teams2" }

        for app in teamsApps {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsVal: CFTypeRef?
            let axResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsVal)

            if axResult.rawValue == -25211 {
                swiftLog("AX error -25211: not trusted. Stopping detector.")
                stop()
                DispatchQueue.main.async {
                    AppDelegate.shared?.showAXResetAlert()
                }
                return
            }

            guard axResult == .success, let windows = windowsVal as? [AXUIElement] else { continue }

            swiftLog("Windows: \(windows.count)")
            for win in windows {
                var titleVal: CFTypeRef?
                guard AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleVal) == .success,
                      let title = titleVal as? String, !title.isEmpty else { continue }

                swiftLog("  Window: \(title.prefix(60))")
                if isMeetingWindow(title) {
                    inMeeting = true
                    meetingName = extractMeetingName(title)
                    swiftLog("  -> MEETING: \(meetingName)")
                    break
                }
            }
            if inMeeting { break }
        }

        let result: [String: Any] = ["in_meeting": inMeeting, "meeting_name": meetingName]
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            try? data.write(to: MEETING_STATUS_FILE)
        }
    }
}

// ── App Delegate ──────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate {
    // Weak-ref singleton so MeetingDetector can reach back without a retain cycle
    static weak var shared: AppDelegate?

    var windowController: StatusWindowController!
    let meetingDetector = MeetingDetector()
    var pythonTask: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        windowController = StatusWindowController()
        windowController.showWindow(nil)
        windowController.startPolling()

        // Check AX trust before starting detector
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        if AXIsProcessTrustedWithOptions(opts) {
            meetingDetector.start()
        } else {
            showAXResetAlert()
        }

        launchPython()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        pythonTask?.terminate()
    }

    func showAXResetAlert() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "TeamsOBSAutoRecord needs Accessibility access to detect Teams meetings.\n\nIn System Settings → Privacy & Security → Accessibility:\n• Remove the existing TeamsOBSAutoRecord entry (if present)\n• Click + and add it again\n\nThen quit and relaunch the app."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Quit App")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        } else if response == .alertSecondButtonReturn {
            NSApplication.shared.terminate(nil)
        }
    }

    private func launchPython() {
        // Guard: don't launch if already running
        if let task = pythonTask, task.isRunning { return }

        // Derive macOS dir from the executable path (more reliable than Bundle.main)
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let macOSDir = execURL.deletingLastPathComponent()
        let pythonPath = macOSDir.appendingPathComponent("venv/bin/python3").path
        let scriptPath = macOSDir.appendingPathComponent("teams_obs_autorecord.py").path

        guard FileManager.default.fileExists(atPath: pythonPath),
              FileManager.default.fileExists(atPath: scriptPath) else {
            swiftLog("Python or script not found at \(macOSDir.path)")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [scriptPath]
        task.environment = [
            "PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path
        ]
        task.currentDirectoryURL = macOSDir
        task.launch()
        pythonTask = task
        swiftLog("Python launched (pid \(task.processIdentifier))")
    }
}

// ── Entry point ───────────────────────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
