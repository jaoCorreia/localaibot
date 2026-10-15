import SwiftUI
import AppKit
import UserNotifications

/// The brain as a launchd agent, so routines run while Local Bot is closed.
/// The agent runs the app's bundled Node and brain with `--service`; it waits
/// while the app's own brain runs and takes over when the app quits (see
/// brain/src/index.ts). Only the packaged app can install it.
@MainActor
enum BackgroundService {
    static let label = "io.github.patrick-mns.localbot.brain"
    /// Opens the app in the menu bar at login (the service alone has no icon).
    static let appLabel = "io.github.patrick-mns.localbot.app"

    static var plistURL: URL { agentURL(label) }

    private static func agentURL(_ label: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Bundled Node and brain; nil when running from source.
    private static var runtime: (node: URL, brain: URL)? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let node = res.appendingPathComponent("node"), brain = res.appendingPathComponent("brain/brain.mjs")
        let fm = FileManager.default
        return fm.fileExists(atPath: node.path) && fm.fileExists(atPath: brain.path) ? (node, brain) : nil
    }

    static var available: Bool { runtime != nil }
    static var installed: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    private static var domain: String { "gui/\(getuid())" }

    static func install() throws {
        guard let runtime, let executable = Bundle.main.executableURL else { return }
        let path = ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin",
                    "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [runtime.node.path, runtime.brain.path, "--service"],
            "EnvironmentVariables": [
                "PATH": path,
                "NODE_NO_WARNINGS": "1",
                // With no app open, the service posts notifications through the app.
                "LOCALBOT_APP_EXECUTABLE": executable.path,
            ],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Background",
            "StandardErrorPath": Brain.logURL.path,
        ]
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: plistURL)
        launchctl("bootout", "\(domain)/\(label)")
        launchctl("bootstrap", domain, plistURL.path)

        // Loaded at the next login (not now: the app is open), once, no
        // KeepAlive; "open -g" so it doesn't take focus.
        let app: [String: Any] = [
            "Label": appLabel,
            "ProgramArguments": ["/usr/bin/open", "-g", Bundle.main.bundleURL.path, "--args", "--background"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        try PropertyListSerialization.data(fromPropertyList: app, format: .xml, options: 0).write(to: agentURL(appLabel))
    }

    static func uninstall() {
        launchctl("bootout", "\(domain)/\(label)")
        try? FileManager.default.removeItem(at: plistURL)
        try? FileManager.default.removeItem(at: agentURL(appLabel))
    }

    /// Picks up a new app version: the agent points into the app bundle, so
    /// reinstalling the plist and restarting is enough.
    static func refresh() {
        guard installed else { return }
        try? install()
    }

    @discardableResult
    private static func launchctl(_ args: String...) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Routine notifications. With the app open, they come from the brain's
/// `routine.finished` event; with it closed, the background service launches
/// the app's executable with `--notify` (see `postAndExit`).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Opens the chat of the bot a clicked notification is about.
    var openBot: ((String) -> Void)?

    /// Notifications need a bundled app (a bundle id).
    private var enabled: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.resourceURL.map {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("node").path)
    } == true }

    func setUp() {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func routineFinished(_ data: Any?) {
        guard enabled, let note = data as? [String: Any] else { return }
        Self.post(note)
    }

    nonisolated static func post(_ note: [String: Any], done: (() -> Void)? = nil) {
        let content = UNMutableNotificationContent()
        content.title = note["title"] as? String ?? "Local Bot"
        content.body = note["body"] as? String ?? ""
        if note["ok"] as? Bool == false { content.sound = .default }
        content.userInfo = ["botId": note["botId"] as? String ?? ""]
        let id = (note["routineId"] as? String ?? UUID().uuidString) + "-" + UUID().uuidString
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in
            done?()
        }
    }

    /// `LocalBot --notify '<json>'`: post one notification and quit, with no
    /// window or Dock icon. Returns false when not in that mode.
    nonisolated static func postAndExitIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--notify"), i + 1 < args.count else { return false }
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let data = args[i + 1].data(using: .utf8),
              let note = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { exit(1) }
        let done = DispatchSemaphore(value: 0)
        post(note) { done.signal() }
        _ = done.wait(timeout: .now() + 5)
        exit(0)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let botID = response.notification.request.content.userInfo["botId"] as? String
        Task { @MainActor in
            NSApplication.shared.activate(ignoringOtherApps: true)
            if let botID, !botID.isEmpty { self.openBot?(botID) }
            completionHandler()
        }
    }
}

/// Settings → Background.
struct BackgroundPage: View {
    @State private var on = BackgroundService.installed
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Background", subtitle: "Routines and notifications while Local Bot is closed.")
            Card {
                SettingRow(label: "Keep routines running when Local Bot is closed",
                           detail: BackgroundService.available
                               ? "A small background service keeps the brain running, so routines run on time and you get notified. Devices still need Docker running."
                               : "Available in the installed app.") {
                    Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden()
                        .disabled(!BackgroundService.available)
                }
                SettingRow(label: "Notifications",
                           detail: "A notification when a routine finishes or fails. Choose how they show in System Settings.") {
                    PillButton(title: "Open", systemImage: "bell") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            }
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).padding(.top, 10)
            }
        }
        .onChange(of: on) { _, enable in
            do {
                if enable { try BackgroundService.install() } else { BackgroundService.uninstall() }
                UserDefaults.standard.set(enable, forKey: MenuBar.key)
                error = nil
            } catch {
                self.error = "Couldn’t \(enable ? "turn on" : "turn off") the background service: \(error.localizedDescription)"
                on = BackgroundService.installed
            }
        }
    }
}

/// The menu bar icon while the background service is on: which bots are
/// working, and the way back to the window. Closing the window leaves the app
/// here (no Dock icon); Quit leaves routines to the service.
enum MenuBar {
    static let key = "menuBarIcon"
    static let windowID = "main"
    /// Set when the app should really quit (menu bar Quit, update, log out).
    static var quitting = false

    static var keepsRunning: Bool { UserDefaults.standard.bool(forKey: key) && !quitting }

    /// Closes the windows and drops the Dock icon; the menu bar icon stays.
    static func hide() {
        for window in NSApplication.shared.windows where window.canBecomeMain { window.close() }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// No Dock icon once the last window closes; it comes back with the window.
    static func windowClosed() {
        guard UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.main.async {
            let visible = NSApplication.shared.windows.contains { $0.isVisible && $0.canBecomeMain }
            if !visible { NSApplication.shared.setActivationPolicy(.accessory) }
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var brain: Brain

    var body: some View {
        Image(systemName: brain.thinking.isEmpty ? "face.smiling" : "face.smiling.inverse")
            .accessibilityLabel(brain.thinking.isEmpty ? "Local Bot" : "Local Bot · bots working")
            // Opened at login without a window: the brain starts from here.
            .task { brain.start() }
    }
}

struct MenuBarMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var brain: Brain
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let working = brain.bots.filter { brain.thinking.contains($0.id) }
        Text(working.isEmpty ? "No bots working" : "\(working.count) bot\(working.count == 1 ? "" : "s") working")
        if !brain.bots.isEmpty {
            Divider()
            ForEach(brain.bots) { bot in
                Button {
                    model.selection = .bot(bot.id)
                    open()
                } label: {
                    Text(brain.thinking.contains(bot.id) ? "\(bot.name) — working" : bot.name)
                }
            }
        }
        Divider()
        Button("Open Local Bot") { open() }
        Button("Settings…") {
            model.sheet = .settings
            open()
        }
        Divider()
        Button("Quit Local Bot") {
            MenuBar.quitting = true
            NSApplication.shared.terminate(nil)
        }
    }

    private func open() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: MenuBar.windowID)
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
