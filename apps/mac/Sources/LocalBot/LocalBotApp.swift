import SwiftUI
import AppKit

@main
struct LocalBotApp: App {
    init() {
        // Running as a bare executable (swift run) has no bundle; make it a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Appearance.current.apply()
    }

    var body: some Scene {
        WindowGroup("Local Bot") {
            ContentView()
                .frame(minWidth: 760, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
    }
}

enum Selection: Hashable {
    case bot(String)
    case computer(String)
}

enum Sheet: Identifiable {
    case newBot
    case editBot(String)
    case settings
    case newDevice
    case addBots(String)   // device id
    case routine(botID: String, routineID: String?)

    var id: String {
        switch self {
        case .newDevice: return "new-device"
        case .addBots(let id): return "add-bots-\(id)"
        case .routine(let bot, let routine): return "routine-\(bot)-\(routine ?? "new")"
        case .newBot: return "new"
        case .editBot(let id): return "edit-\(id)"
        case .settings: return "settings"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    let brain = Brain()
    @Published var selection: Selection?
    @Published var sheet: Sheet?
    @Published var showSidebar = true
    @Published var showChat = true
    /// Device preselected when "New bot" is opened from a device.
    var newBotDevice: String?
    /// macOS VMs are booted in-process; one host per Lume bundle.
    private var vmHosts: [String: VMHost] = [:]

    func host(for path: String) -> VMHost {
        if let host = vmHosts[path] { return host }
        let url = URL(fileURLWithPath: path)
        let host = VMHost(bundle: VMBundle(name: url.lastPathComponent, url: url))
        vmHosts[path] = host
        return host
    }
}

struct ContentView: View {
    @StateObject private var model = AppModel()

    var body: some View {
        MainView(model: model, brain: model.brain)
    }
}

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var brain: Brain

    var body: some View {
        HStack(spacing: 0) {
            if model.showSidebar {
                Sidebar(model: model, brain: brain)
                    .frame(width: 248)
                    .transition(.move(edge: .leading))
                Rectangle().fill(Theme.border).frame(width: 1)
            }
            center
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showChat {
                Rectangle().fill(Theme.border).frame(width: 1)
                trailing
                    .frame(width: 380)
                    .transition(.move(edge: .trailing))
            }
        }
        .environmentObject(model)
        .animation(.easeInOut(duration: 0.18), value: model.showSidebar)
        .animation(.easeInOut(duration: 0.18), value: model.showChat)
        .background(Theme.window)
        .background(WindowChrome())
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.text)
        .tint(Theme.text)
        .onAppear { brain.start() }
        .onReceive(brain.$bots) { _ in fixSelection() }
        .onReceive(brain.$computers) { _ in fixSelection() }
        .sheet(item: $model.sheet) { sheet in
            switch sheet {
            case .newBot: BotEditor(model: model, brain: brain, botID: nil)
            case .editBot(let id): BotEditor(model: model, brain: brain, botID: id)
            case .settings: SettingsSheet(brain: brain)
            case .newDevice: NewDeviceSheet(model: model, brain: brain)
            case .addBots(let id): AddBotsSheet(model: model, brain: brain, deviceID: id)
            case .routine(let bot, let routine): RoutineEditor(brain: brain, botID: bot, routineID: routine)
            }
        }
        .overlay(alignment: .bottom) { ErrorToast(brain: brain) }
    }

    @ViewBuilder private var center: some View {
        switch model.selection {
        case .bot(let id):
            if let bot = brain.bots.first(where: { $0.id == id }) {
                if let computer = brain.computers.first(where: { $0.id == bot.ownedComputer }) {
                    ComputerStage(model: model, brain: brain, computer: computer, caption: "\(bot.name)’s device")
                } else {
                    VStack(spacing: 0) {
                        StageHeader(title: bot.name, subtitle: "No device", state: "stopped") { EmptyView() }
                        Placeholder(icon: "desktopcomputer", text: "\(bot.name) has no device yet",
                                    detail: "Assign a device in the bot settings.")
                            .overlay(alignment: .center) {
                                PillButton(title: "Bot settings", systemImage: "slider.horizontal.3") {
                                    model.sheet = .editBot(bot.id)
                                }
                                .offset(y: 70)
                            }
                    }
                }
            }
        case .computer(let id):
            if let computer = brain.computers.first(where: { $0.id == id }) {
                ComputerStage(model: model, brain: brain, computer: computer, caption: nil)
            }
        case nil:
            VStack(spacing: 0) {
                StageHeader(title: "Local Bot", subtitle: "", state: "stopped") { EmptyView() }
                Placeholder(icon: "sparkles", text: brain.connected ? "Create your first bot" : (brain.lastError ?? "Connecting…"),
                        detail: "Bots work on devices. A bot can have its own device or share one.")
            }
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.selection {
        case .bot(let id):
            if let bot = brain.bots.first(where: { $0.id == id }) {
                ChatView(model: model, brain: brain, bot: bot).id(bot.id)
            }
        case .computer(let id):
            if let computer = brain.computers.first(where: { $0.id == id }) {
                ComputerBots(model: model, brain: brain, computer: computer)
            }
        case nil:
            Color.clear.background(Theme.sidebar)
        }
    }

    private func fixSelection() {
        switch model.selection {
        case .bot(let id) where brain.bots.contains { $0.id == id }: return
        case .computer(let id) where brain.computers.contains { $0.id == id }: return
        default:
            if let bot = brain.bots.first { model.selection = .bot(bot.id) }
            else if let computer = brain.computers.first { model.selection = .computer(computer.id) }
            else { model.selection = nil }
        }
    }
}

struct ErrorToast: View {
    @ObservedObject var brain: Brain

    var body: some View {
        if let error = brain.lastError, brain.connected {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn)
                Text(error).font(.system(size: 12)).lineLimit(2)
                IconButton(systemImage: "xmark", help: "Close") { brain.lastError = nil }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.raised))
            .hairline(10)
            .padding(.bottom, 18)
            .task(id: error) {
                try? await Task.sleep(for: .seconds(6))
                if brain.lastError == error { brain.lastError = nil }
            }
        }
    }
}
