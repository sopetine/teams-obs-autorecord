import Cocoa
import Foundation

// Status written to disk for the Python OBS controller to read
struct MeetingStatus: Codable {
    var inMeeting: Bool
    var meetingName: String
    var timestamp: String
}

let statusFile = URL(fileURLWithPath: NSHomeDirectory() + "/.teams-obs-meeting.json")
let obsStatusFile = URL(fileURLWithPath: NSHomeDirectory() + "/.teams-obs-status.json")

// MARK: - Status Window

class StatusWindowController: NSWindowController {
    private var statusLabel: NSTextField!
    private var meetingLabel: NSTextField!
    private var pollTimer: Timer?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Teams OBS Auto-Record"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        setupUI()
        startPolling()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let cv = window?.contentView else { return }

        statusLabel = NSTextField(labelWithString: "Status: Starting...")
        statusLabel.frame = NSRect(x: 20, y: 70, width: 280, height: 24)
        statusLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        statusLabel.textColor = .systemGray
        statusLabel.alignment = .center
        cv.addSubview(statusLabel)

        meetingLabel = NSTextField(labelWithString: "Meeting: None")
        meetingLabel.frame = NSRect(x: 20, y: 40, width: 280, height: 24)
        meetingLabel.font = NSFont.systemFont(ofSize: 12)
        meetingLabel.textColor = .secondaryLabelColor
        meetingLabel.alignment = .center
        cv.addSubview(meetingLabel)

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitApp))
        quitButton.frame = NSRect(x: 120, y: 10, width: 80, height: 24)
        quitButton.bezelStyle = .rounded
        cv.addSubview(quitButton)
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        updateStatus()
    }

    func updateStatus() {
        guard let data = try? Data(contentsOf: obsStatusFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            statusLabel.stringValue = "Status: Starting..."
            statusLabel.textColor = .systemGray
            meetingLabel.stringValue = "Meeting: None"
            return
        }
        let recording = json["recording"] as? Bool ?? false
        let inMeeting = json["in_meeting"] as? Bool ?? false
        let name = json["meeting"] as? String ?? "None"

        if recording {
            statusLabel.stringValue = "Status: Recording"
            statusLabel.textColor = .systemRed
            meetingLabel.stringValue = "Meeting: \(name)"
            meetingLabel.textColor = .labelColor
        } else if inMeeting {
            statusLabel.stringValue = "Status: Starting recording..."
            statusLabel.textColor = .systemOrange
            meetingLabel.stringValue = "Meeting: \(name)"
            meetingLabel.textColor = .labelColor
        } else {
            statusLabel.stringValue = "Status: Monitoring Teams..."
            statusLabel.textColor = .systemGreen
            meetingLabel.stringValue = "Meeting: None"
            meetingLabel.textColor = .secondaryLabelColor
        }
    }

    @objc private func quitApp() {
        // Kill Python OBS controller
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "teams_obs_autorecord"]
        try? kill.run()
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Meeting Detector (runs in Swift, has Accessibility permission)

class MeetingDetector {
    private var timer: Timer?
    private let encoder = JSONEncoder()
    private var lastStatus: Bool? = nil

    func start() {
        let trusted = AXIsProcessTrusted()
        appendLog("AXIsProcessTrusted=\(trusted)")
        if !trusted {
            // Prompt with explanation
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)

            // Show dialog guiding user
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "Please add TeamsOBSAutoRecord to System Settings → Privacy & Security → Accessibility, then restart the app."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.detect()
        }
        detect()
    }

    private func detect() {
        appendLog("detect() called")
        // Use AX API directly - works without subprocess, no osascript permission issues
        let apps = NSWorkspace.shared.runningApplications
        appendLog("runningApplications count=\(apps.count)")
        let teamsApps = apps.filter { $0.bundleIdentifier?.contains("teams") == true }
        appendLog("teams apps: \(teamsApps.map { "\($0.bundleIdentifier ?? "nil")" })")
        guard let teams = apps.first(where: {
            $0.bundleIdentifier == "com.microsoft.teams2"
        }) else {
            writeMeetingStatus(inMeeting: false, name: "")
            return
        }

        let axApp = AXUIElementCreateApplication(teams.processIdentifier)
        var windowsRef: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef)
        appendLog("AX result=\(axResult.rawValue) windowsRef=\(windowsRef != nil ? "non-nil" : "nil")")
        guard axResult == .success, let windows = windowsRef as? [AXUIElement] else {
            writeMeetingStatus(inMeeting: false, name: "")
            return
        }

        var titles: [String] = []
        for win in windows {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String, !title.isEmpty {
                titles.append(title)
            }
        }

        appendLog("Found \(titles.count) windows: \(titles.map { String($0.prefix(40)) })")

        var meetingName: String? = nil
        for title in titles {
            if title.hasPrefix("Meeting compact view |") {
                meetingName = extractName(from: title)
                appendLog("Matched: \(title.prefix(60))")
                break
            }
            if title.hasPrefix("Stand-up |") || title.hasPrefix("Chat |") || title.hasPrefix("Call |") {
                continue
            }
            let parts = title.components(separatedBy: "|")
            if parts.first?.trimmingCharacters(in: CharacterSet.whitespaces) == "Meeting" {
                meetingName = extractName(from: title)
                appendLog("Matched (keyword): \(title.prefix(60))")
                break
            }
        }

        writeMeetingStatus(inMeeting: meetingName != nil, name: meetingName ?? "")
    }

    private func appendLog(_ msg: String) {
        let logFile = URL(fileURLWithPath: NSHomeDirectory() + "/.teams-obs-swift.log")
        let line = "[\(Date())] \(msg)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    private func extractName(from title: String) -> String {
        var name = title
        if name.hasPrefix("Meeting compact view | ") {
            name = String(name.dropFirst("Meeting compact view | ".count))
        }
        let parts = name.components(separatedBy: "|")
        return parts.first?.trimmingCharacters(in: .whitespaces) ?? name
    }

    private func writeMeetingStatus(inMeeting: Bool, name: String) {
        let dict: [String: Any] = [
            "in_meeting": inMeeting,
            "meeting_name": name,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted) {
            try? data.write(to: statusFile)
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: StatusWindowController?
    var detector = MeetingDetector()
    var pythonTask: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = StatusWindowController()
        windowController?.showWindow(nil)
        windowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Start meeting detection in Swift (has Accessibility permission)
        detector.start()

        // Launch Python OBS controller (reads meeting status, controls OBS)
        let bundlePath = Bundle.main.bundlePath + "/Contents/MacOS"
        let venv = bundlePath + "/venv/bin/python3"
        let script = bundlePath + "/teams_obs_autorecord.py"

        pythonTask = Process()
        pythonTask?.executableURL = URL(fileURLWithPath: venv)
        pythonTask?.arguments = [script]
        pythonTask?.currentDirectoryURL = URL(fileURLWithPath: bundlePath)
        pythonTask?.environment = ["PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin",
                                   "HOME": NSHomeDirectory()]
        try? pythonTask?.run()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        pythonTask?.terminate()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
