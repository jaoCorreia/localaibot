import Foundation

/// Client for the TypeScript brain process. Protocol: one JSON object per line
/// over stdio. Requests `{id, method, params}` get `{id, result}` or `{id, error}`;
/// the brain also pushes `{event, data}` notifications.
@MainActor
final class Brain: ObservableObject {
    struct Computer: Decodable, Identifiable, Hashable {
        struct Display: Decodable, Hashable {
            let kind: String          // "vnc" | "native-vz" | "none"
            let url: String?
            let password: String?
            let bundlePath: String?
        }

        let id: String
        let name: String
        let provider: String
        let os: String
        let state: String             // creating | stopped | starting | running | stopping | error
        let display: Display
        let bots: [String]

        var osLabel: String {
            switch os {
            case "macos": return "macOS"
            case "linux": return "Linux"
            case "windows": return "Windows"
            default: return os
            }
        }
    }

    struct Access: Decodable, Hashable {
        let botId: String
        let computerId: String
        let role: String              // owner | guest
        let expiresAt: String?
    }

    /// Face parts (see brain/src/bots/avatar.ts) for native drawing.
    struct Face: Decodable, Hashable {
        let color: String
        let eyes: String
        let mouth: String
        let accessory: String
        let fill: String
        let deep: String
    }

    struct Bot: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
        let role: String
        let instructions: String
        let provider: String
        let model: String
        let avatar: String            // SVG
        let avatarSeed: String        // catalog spec ("v1:…") or legacy seed
        let face: Face
        let memoryAuto: Bool?
        let computers: [Access]

        var ownedComputer: String? { computers.first { $0.role == "owner" }?.computerId }
        /// Where the bot works: its own device, else the first one it's a guest on
        /// (the brain picks devices in this same order).
        var workDevice: String? { ownedComputer ?? computers.first?.computerId }
        var isGuestOnly: Bool { ownedComputer == nil && workDevice != nil }
    }

    struct Message: Decodable, Identifiable, Hashable {
        let id: String
        let botId: String
        let role: String              // user | assistant
        var text: String
        let at: String
        var error: String?
        /// Technical detail behind `error`, shown only on request.
        var detail: String?
        /// Set when a routine posted this prompt.
        var routine: RoutineRef?
        /// Set when another bot sent this prompt (ask_bot).
        var from: FromRef?

        struct FromRef: Decodable, Hashable { let botId: String; let name: String }

        struct RoutineRef: Decodable, Hashable { let id: String; let name: String }
    }

    /// Mirrors brain/src/routines/schedule.ts.
    enum Schedule: Codable, Hashable {
        case interval(every: Int, unit: String)            // "minutes" | "hours"
        case daily(time: String, days: [Int])               // "HH:MM", 0=Sun…6=Sat
        case once(at: Date)

        private enum Keys: String, CodingKey { case kind, every, unit, time, days, at }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch try c.decode(String.self, forKey: .kind) {
            case "interval": self = .interval(every: try c.decode(Int.self, forKey: .every), unit: try c.decode(String.self, forKey: .unit))
            case "daily": self = .daily(time: try c.decode(String.self, forKey: .time), days: try c.decode([Int].self, forKey: .days))
            default:
                let iso = try c.decode(String.self, forKey: .at)
                self = .once(at: ISO8601DateFormatter.withFractions.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) ?? .now)
            }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .interval(let every, let unit):
                try c.encode("interval", forKey: .kind); try c.encode(every, forKey: .every); try c.encode(unit, forKey: .unit)
            case .daily(let time, let days):
                try c.encode("daily", forKey: .kind); try c.encode(time, forKey: .time); try c.encode(days, forKey: .days)
            case .once(let at):
                try c.encode("once", forKey: .kind); try c.encode(ISO8601DateFormatter().string(from: at), forKey: .at)
            }
        }

        var json: [String: Any] {
            let data = (try? JSONEncoder().encode(self)) ?? Data()
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
    }

    struct Routine: Decodable, Identifiable, Hashable {
        let id: String
        let botId: String
        let name: String
        let task: String
        let schedule: Schedule
        let enabled: Bool
        let nextRunAt: String?
        let lastRunAt: String?
        let lastStatus: String?      // ok | failed | running | skipped
        let lastError: String?
        let scheduleText: String
    }

    struct ProviderStatus: Decodable {
        struct Preset: Decodable, Identifiable, Hashable {
            let id: String
            let label: String
            let baseURL: String
            let envKey: String?
            let keyless: Bool?
            let local: Bool?
            let editableURL: Bool?
            let suggestedModel: String?
            let keyURL: String?
        }

        struct Entry: Decodable, Identifiable, Hashable {
            let id: String
            let preset: String
            let label: String
            let baseURL: String
            let local: Bool
            let keyless: Bool
            let configured: Bool
            let keySource: String?     // "config" | "env" | nil
            let keyHint: String?
        }

        let defaultProvider: String
        let defaultModel: String
        let presets: [Preset]
        let providers: [Entry]

        var configured: Bool { providers.contains { $0.configured } }
        var defaultEntry: Entry? { providers.first { $0.id == defaultProvider } }
        func entry(_ id: String) -> Entry? { providers.first { $0.id == id } }
        func preset(_ id: String) -> Preset? { presets.first { $0.id == id } }
    }

    struct TestResult: Decodable {
        let ok: Bool
        let models: Int?
        let error: String?
    }

    struct Model: Decodable, Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published private(set) var connected = false
    /// True once bots, providers and routines have been read after startup.
    @Published private(set) var loaded = false
    @Published private(set) var computers: [Computer] = []
    @Published private(set) var bots: [Bot] = []
    @Published private(set) var messages: [String: [Message]] = [:]
    @Published private(set) var thinking: Set<String> = []
    @Published private(set) var routines: [Routine] = []
    @Published private(set) var memories: [String: [Memory]] = [:]
    @Published private(set) var providerStatus: ProviderStatus?
    /// Model lists per provider id.
    @Published private(set) var models: [String: [Model]] = [:]
    @Published private(set) var busy: Set<String> = []
    @Published var lastError: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Any?, Error>] = [:]

    /// Brain lives at <repo>/brain. Set LOCALBOT_BRAIN_DIR to override.
    private var brainDir: URL {
        if let dir = ProcessInfo.processInfo.environment["LOCALBOT_BRAIN_DIR"] {
            return URL(fileURLWithPath: dir)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("brain")
    }

    // MARK: Lifecycle

    private var restarts = 0
    private var stopping = false

    /// Where the brain's stderr goes: ~/Library/Logs/LocalBot/brain.log.
    static let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/LocalBot/brain.log")

    /// The packaged app ships Node and a bundled brain in Resources; a dev
    /// checkout runs the TypeScript sources through tsx.
    private func launchCommand() -> (URL, [String], URL?) {
        if let res = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: res.appendingPathComponent("node").path),
           FileManager.default.fileExists(atPath: res.appendingPathComponent("brain/brain.mjs").path) {
            return (res.appendingPathComponent("node"), [res.appendingPathComponent("brain/brain.mjs").path], nil)
        }
        // GUI apps don't inherit the login shell PATH; zsh -l finds node in a dev setup.
        return (URL(fileURLWithPath: "/bin/zsh"), ["-lc", "exec node --import tsx src/index.ts"], brainDir)
    }

    func start() {
        guard process == nil else { return }
        let p = Process()
        let (exe, args, cwd) = launchCommand()
        p.executableURL = exe
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        // Docker's CLI lives outside the default GUI PATH.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/usr/local/bin", "/opt/homebrew/bin", "/Applications/Docker.app/Contents/Resources/bin",
                       env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"].joined(separator: ":")
        env["NODE_NO_WARNINGS"] = "1"
        p.environment = env

        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = Self.logHandle() ?? FileHandle.standardError
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        p.terminationHandler = { [weak self] proc in
            Task { @MainActor in self?.brainExited(code: proc.terminationStatus) }
        }
        do {
            try p.run()
            process = p
            stdin = inPipe.fileHandleForWriting
            connected = true
            lastError = nil
            Task {
                await refreshBots()
                await refreshProviders()
                await refreshRoutines()
                loaded = true
                // Computers change outside the app too (docker, lume); poll for state.
                while !Task.isCancelled && self.connected && self.process === p {
                    await refreshComputers()
                    try? await Task.sleep(for: .seconds(4))
                }
            }
        } catch {
            lastError = "Couldn’t start the brain: \(error.localizedDescription)"
        }
    }

    func stop() {
        stopping = true
        process?.terminate()
    }

    /// Restarts a crashed brain a few times, backing off, before giving up.
    private func brainExited(code: Int32) {
        connected = false
        process = nil
        stdin = nil
        for (_, cont) in pending { cont.resume(throwing: NSError(domain: "Brain", code: 3, userInfo: [NSLocalizedDescriptionKey: "Brain restarted"])) }
        pending = [:]
        guard !stopping else { return }
        guard restarts < 5 else {
            lastError = "The brain keeps stopping (code \(code)). See \(Self.logURL.path)."
            return
        }
        restarts += 1
        lastError = "The brain stopped (code \(code)); restarting…"
        Task {
            try? await Task.sleep(for: .seconds(Double(restarts) * 1.5))
            self.start()
        }
    }

    private static func logHandle() -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        // Keep the log from growing forever: start over past 5 MB.
        if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int, size > 5_000_000 {
            try? Data().write(to: logURL)
        }
        guard let h = try? FileHandle(forWritingTo: logURL) else { return nil }
        h.seekToEndOfFile()
        h.write(Data("\n--- \(Date()) brain starting ---\n".utf8))
        return h
    }

    // MARK: Computers

    func refreshComputers() async {
        if let list: [Computer] = try? await request("computers.list") { computers = list }
    }

    struct DeviceKind: Decodable, Identifiable, Hashable {
        let id: String
        let label: String
        let detail: String
        let available: Bool
        let reason: String?
    }

    func deviceKinds() async -> [DeviceKind] {
        (try? await request("computers.kinds")) ?? []
    }

    /// Returns the new device id, or nil (error in `lastError`).
    func createDevice(kind: String, name: String) async -> String? {
        do {
            let raw = try await call("computers.create", ["kind": kind, "name": name])
            await refreshComputers()
            return (raw as? [String: Any])?["id"] as? String
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func renameDevice(_ id: String, to name: String) async {
        await perform("computers.rename", ["id": id, "name": name])
        await refreshComputers()
    }

    func removeDevice(_ id: String) async {
        busy.insert(id)
        defer { busy.remove(id) }
        await perform("computers.remove", ["id": id])
        await refreshComputers()
        await refreshBots()
    }

    func setPower(_ on: Bool, computer id: String) async {
        busy.insert(id)
        defer { busy.remove(id) }
        await perform(on ? "computers.start" : "computers.stop", ["id": id])
        await refreshComputers()
    }

    // MARK: Bots

    func refreshBots() async {
        if let list: [Bot] = try? await request("bots.list") { bots = list }
    }

    struct BotDraft {
        var name = ""
        var role = ""
        var instructions = ""
        var provider = ""
        var model = ""
        var computerId: String?
        var avatarSeed = UUID().uuidString   // replaced by a catalog spec once the editor loads
    }

    func createBot(_ d: BotDraft) async -> Bot? {
        var params: [String: Any] = ["name": d.name, "role": d.role, "instructions": d.instructions,
                                     "provider": d.provider, "model": d.model, "avatarSeed": d.avatarSeed]
        if let c = d.computerId { params["computerId"] = c }
        do {
            let bot: Bot = try await request("bots.create", params)
            await refreshBots()
            return bot
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func updateBot(_ id: String, _ d: BotDraft) async {
        var patch: [String: Any] = ["id": id, "name": d.name, "role": d.role,
                                    "instructions": d.instructions, "provider": d.provider, "model": d.model]
        if !d.avatarSeed.isEmpty { patch["avatarSeed"] = d.avatarSeed }
        await perform("bots.update", patch)
        let current = bots.first { $0.id == id }?.ownedComputer
        if current != d.computerId {
            if let old = current { await perform("access.revoke", ["botId": id, "computerId": old]) }
            if let new = d.computerId {
                await perform("access.grant", ["botId": id, "computerId": new, "role": "owner"])
            }
        }
        await refreshBots()
    }

    /// role: "owner" (the bot's main device) or "guest" (shared access).
    func grantAccess(bot: String, device: String, role: String) async {
        await perform("access.grant", ["botId": bot, "computerId": device, "role": role])
    }

    func revokeAccess(bot: String, device: String) async {
        await perform("access.revoke", ["botId": bot, "computerId": device])
    }

    func regenerateAvatar(_ id: String) async { await perform("bots.regenerateAvatar", ["id": id]) }

    func deleteBot(_ id: String) async {
        await perform("bots.delete", ["id": id])
        messages[id] = nil
        await refreshBots()
    }

    struct AvatarOption: Decodable, Identifiable, Hashable {
        let id: String
        let label: String
        let value: String
        let svg: String
        let fill: String?
    }

    struct AvatarOptions: Decodable {
        let value: String
        let svg: String
        let face: Face
        let colors: [AvatarOption]
        let eyes: [AvatarOption]
        let mouths: [AvatarOption]
        let accessories: [AvatarOption]
    }

    /// Every catalog option rendered on top of `value` (a spec or legacy seed).
    func avatarOptions(_ value: String) async -> AvatarOptions? {
        try? await request("bots.avatarOptions", ["value": value])
    }

    func randomAvatar() async -> String? {
        try? await request("bots.randomAvatar")
    }

    func previewAvatar(seed: String) async -> String? {
        try? await request("bots.previewAvatar", ["seed": seed])
    }

    // MARK: Reset

    /// Back to a fresh install (see brain `app.reset`). Returns false on failure.
    func resetApp(removeDevices: Bool) async -> Bool {
        do {
            _ = try await call("app.reset", ["removeDevices": removeDevices])
        } catch {
            lastError = error.localizedDescription
            return false
        }
        messages = [:]
        memories = [:]
        models = [:]
        await refreshBots()
        await refreshProviders()
        await refreshRoutines()
        await refreshComputers()
        return true
    }

    // MARK: Memory

    struct Memory: Decodable, Identifiable, Hashable {
        let id: String
        let botId: String?          // nil = shared with the team
        let kind: String            // core | fact | procedure | episode
        let text: String
        let topic: String?
        let source: String          // bot | user | learned
        let importance: Int
        let createdAt: String
        let updatedAt: String
        let validTo: String?
        let useCount: Int
    }

    func refreshMemory(_ botID: String) async {
        if let list: [Memory] = try? await request("memory.list", ["botId": botID]) { memories[botID] = list }
    }

    func addMemory(bot: String, kind: String, text: String, topic: String?, team: Bool) async {
        var params: [String: Any] = ["botId": bot, "kind": kind, "text": text, "scope": team ? "team" : "me"]
        if let topic, !topic.isEmpty { params["topic"] = topic }
        await perform("memory.add", params)
        await refreshMemory(bot)
    }

    func editMemory(_ id: String, bot: String, text: String? = nil, kind: String? = nil) async {
        var params: [String: Any] = ["id": id, "botId": bot]
        if let text { params["text"] = text }
        if let kind { params["kind"] = kind }
        await perform("memory.edit", params)
        await refreshMemory(bot)
    }

    func forgetMemory(_ id: String, bot: String) async {
        await perform("memory.forget", ["id": id, "botId": bot])
        await refreshMemory(bot)
    }

    func deleteMemory(_ id: String, bot: String) async {
        await perform("memory.delete", ["id": id, "botId": bot])
        await refreshMemory(bot)
    }

    func setMemoryAuto(_ on: Bool, bot: String) async {
        await perform("bots.update", ["id": bot, "memoryAuto": on])
        await refreshBots()
    }

    // MARK: Routines

    func refreshRoutines() async {
        if let list: [Routine] = try? await request("routines.list") { routines = list }
    }

    func saveRoutine(id: String?, botId: String, name: String, task: String, schedule: Schedule, enabled: Bool) async -> Bool {
        do {
            var params: [String: Any] = ["name": name, "task": task, "schedule": schedule.json, "enabled": enabled]
            if let id { params["id"] = id } else { params["botId"] = botId }
            _ = try await call(id == nil ? "routines.create" : "routines.update", params)
            await refreshRoutines()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setRoutineEnabled(_ id: String, _ enabled: Bool) async {
        await perform("routines.update", ["id": id, "enabled": enabled])
        await refreshRoutines()
    }

    func runRoutineNow(_ id: String) async {
        await perform("routines.runNow", ["id": id])
        await refreshRoutines()
    }

    func deleteRoutine(_ id: String) async {
        await perform("routines.delete", ["id": id])
        await refreshRoutines()
    }

    // MARK: Chat

    func loadHistory(_ botID: String) async {
        if let list: [Message] = try? await request("chat.history", ["botId": botID]) { messages[botID] = list }
    }

    func send(_ text: String, to botID: String) async { await perform("chat.send", ["botId": botID, "text": text]) }
    func stop(_ botID: String) async { await perform("chat.stop", ["botId": botID]) }

    func clearChat(_ botID: String) async {
        await perform("chat.clear", ["botId": botID])
        messages[botID] = []
    }

    // MARK: Providers

    func refreshProviders() async {
        providerStatus = try? await request("providers.status")
    }

    func loadModels(_ provider: String, fresh: Bool = false) async {
        guard fresh || (models[provider] ?? []).isEmpty else { return }
        do {
            let list: [Model] = try await request("providers.models", ["provider": provider])
            models[provider] = list
        } catch {
            models[provider] = []
        }
    }

    @discardableResult
    func addProvider(preset: String, label: String, baseURL: String, apiKey: String) async -> String? {
        do {
            let raw = try await call("providers.add", ["preset": preset, "label": label, "baseURL": baseURL, "apiKey": apiKey])
            await refreshProviders()
            return (raw as? [String: Any])?["id"] as? String
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// `apiKey == nil` keeps the stored key; an empty string removes it.
    func updateProvider(_ id: String, label: String, baseURL: String, apiKey: String?) async {
        var params: [String: Any] = ["id": id, "label": label, "baseURL": baseURL]
        if let apiKey { params["apiKey"] = apiKey }
        await perform("providers.update", params)
        models[id] = nil
        await refreshProviders()
    }

    func removeProvider(_ id: String) async {
        await perform("providers.remove", ["id": id])
        models[id] = nil
        await refreshProviders()
    }

    func testProvider(_ id: String) async -> TestResult {
        (try? await request("providers.test", ["id": id])) ?? TestResult(ok: false, models: nil, error: "No response from the brain")
    }

    func setDefault(provider: String, model: String) async {
        await perform("providers.setDefault", ["provider": provider, "model": model])
        await refreshProviders()
    }

    // MARK: Transport

    private func perform(_ method: String, _ params: [String: Any] = [:]) async {
        do { _ = try await call(method, params) } catch { lastError = error.localizedDescription }
    }

    private func request<T: Decodable>(_ method: String, _ params: [String: Any] = [:]) async throws -> T {
        let raw = try await call(method, params)
        let data = try JSONSerialization.data(withJSONObject: raw ?? NSNull(), options: .fragmentsAllowed)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func call(_ method: String, _ params: [String: Any] = [:]) async throws -> Any? {
        guard let stdin else {
            throw NSError(domain: "Brain", code: 1, userInfo: [NSLocalizedDescriptionKey: "Brain disconnected"])
        }
        let id = nextID
        nextID += 1
        var line = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        line.append(0x0A)
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            stdin.write(line)
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = obj["id"] as? Int, let cont = pending.removeValue(forKey: id) {
                if let err = obj["error"] as? String {
                    cont.resume(throwing: NSError(domain: "Brain", code: 2, userInfo: [NSLocalizedDescriptionKey: err]))
                } else {
                    cont.resume(returning: obj["result"] is NSNull ? nil : obj["result"])
                }
            } else if let event = obj["event"] as? String {
                handle(event: event, data: obj["data"])
            }
        }
    }

    private func decode<T: Decodable>(_ value: Any?) -> T? {
        guard let value, !(value is NSNull),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func handle(event: String, data: Any?) {
        switch event {
        case "message", "message.done":
            guard let msg: Message = decode(data) else { return }
            var list = messages[msg.botId] ?? []
            // A reply that was only tool calls has no text; drop its placeholder.
            if event == "message.done", (data as? [String: Any])?["empty"] as? Bool == true {
                list.removeAll { $0.id == msg.id }
                messages[msg.botId] = list
                return
            }
            if let i = list.firstIndex(where: { $0.id == msg.id }) {
                // The final message carries the full text; keep streamed text if it's empty.
                if !msg.text.isEmpty || msg.error != nil { list[i] = msg }
            } else {
                list.append(msg)
            }
            messages[msg.botId] = list
        case "message.delta":
            guard let d = data as? [String: Any], let id = d["id"] as? String,
                  let botID = d["botId"] as? String, let delta = d["delta"] as? String,
                  let i = messages[botID]?.firstIndex(where: { $0.id == id }) else { return }
            messages[botID]?[i].text += delta
        case "bot.status":
            guard let d = data as? [String: Any], let id = d["botId"] as? String else { return }
            if d["status"] as? String == "thinking" { thinking.insert(id) } else { thinking.remove(id) }
        case "bots":
            Task { await refreshBots(); await refreshComputers() }
        case "computers":
            Task { await refreshComputers() }
        case "routines":
            Task { await refreshRoutines() }
        case "memory":
            if let botID = (data as? [String: Any])?["botId"] as? String, memories[botID] != nil {
                Task { await refreshMemory(botID) }
            }
        case "providers":
            Task { await refreshProviders() }
        default:
            break
        }
    }
}

extension ISO8601DateFormatter {
    /// The brain writes dates with milliseconds (JavaScript's toISOString).
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
