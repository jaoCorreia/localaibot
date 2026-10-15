import SwiftUI

/// Settings → MCP Servers: add a server, see its tools, test, remove.

extension Brain.McpServer {
    var stateColor: Color {
        switch state {
        case "connected": return Theme.live
        case "error": return Theme.danger
        case "signin": return Theme.warn
        case "connecting": return Theme.warn
        default: return Theme.tertiary
        }
    }

    var stateLabel: String {
        switch state {
        case "connected": return "\(tools?.count ?? 0) tools"
        case "error": return "Error"
        case "connecting": return "Connecting…"
        case "off": return "Off"
        case "signin": return "Sign-in needed"
        default: return "Not connected yet"
        }
    }
}

/// Ready-made servers for Add server: a click fills the form.
struct McpPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let icon: String
    var url: String?
    var command: String?
    /// What the user still has to fill in, shown under the form.
    var note: String?
    var envKeys: [String] = []

    var isRemote: Bool { url != nil }

    static let catalog: [McpPreset] = [
        McpPreset(id: "deepwiki", name: "DeepWiki", detail: "Docs for any GitHub repo", icon: "books.vertical",
                  url: "https://mcp.deepwiki.com/mcp"),
        McpPreset(id: "context7", name: "Context7", detail: "Up-to-date library docs", icon: "doc.text.magnifyingglass",
                  url: "https://mcp.context7.com/mcp"),
        McpPreset(id: "github", name: "GitHub", detail: "Issues, PRs, code", icon: "chevron.left.forwardslash.chevron.right",
                  url: "https://api.githubcopilot.com/mcp/",
                  note: "Paste a GitHub personal access token in Token."),
        McpPreset(id: "files", name: "Files", detail: "A folder on this Mac", icon: "folder",
                  command: "npx -y @modelcontextprotocol/server-filesystem ~/Documents",
                  note: "Change ~/Documents to the folder bots may use; they can't see anything else."),
        McpPreset(id: "memory", name: "Knowledge graph", detail: "Notes bots keep as a graph", icon: "point.3.connected.trianglepath.dotted",
                  command: "npx -y @modelcontextprotocol/server-memory"),
        McpPreset(id: "thinking", name: "Sequential thinking", detail: "Step-by-step reasoning", icon: "list.number",
                  command: "npx -y @modelcontextprotocol/server-sequential-thinking"),
        McpPreset(id: "everything", name: "Everything", detail: "MCP's test server", icon: "testtube.2",
                  command: "npx -y @modelcontextprotocol/server-everything"),
    ]
}

/// Add (server == nil) or edit a server.
struct McpServerForm: View {
    @ObservedObject var brain: Brain
    var server: Brain.McpServer?
    /// Values to start a new server from (the catalog).
    var preset: McpPreset?
    let onSaved: (String) -> Void
    var onCancel: (() -> Void)?

    fileprivate struct EnvRow: Identifiable { let id = UUID(); var key = ""; var value = "" }

    @State private var remote = true
    @State private var name = ""
    @State private var url = ""
    @State private var token = ""
    @State private var commandLine = ""
    @State private var env: [EnvRow] = []
    @State private var envEdited = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card {
                SettingRow(label: "Type", detail: remote ? "A server on the internet (Streamable HTTP)." : "A program on this Mac, started by Local Bot (stdio).") {
                    Picker("", selection: $remote) {
                        Text("Remote").tag(true)
                        Text("Local").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                    .disabled(server != nil)
                }
                SettingRow(label: "Name", detail: "Bots see its tools as name__tool.") {
                    InlineField(text: $name, placeholder: remote ? "GitHub" : "Filesystem", width: 260)
                }
                if remote {
                    SettingRow(label: "URL") {
                        InlineField(text: $url, placeholder: "https://example.com/mcp", monospaced: true, width: 260)
                    }
                    SettingRow(label: "Token", detail: server?.hasToken == true ? "Saved in the Keychain. Leave empty to keep it." : "Optional. Sent as a Bearer token; kept in the Keychain.") {
                        InlineField(text: $token, placeholder: server?.hasToken == true ? "••••••••" : "Optional", secure: true, width: 260)
                    }
                } else {
                    SettingRow(label: "Command", detail: "Runs with your PATH, like in Terminal.") {
                        InlineField(text: $commandLine, placeholder: "npx -y @modelcontextprotocol/server-filesystem ~/Documents", monospaced: true, width: 300)
                    }
                }
            }
            if !remote {
                Card(title: "Environment variables") {
                    if env.isEmpty {
                        SettingRow(label: server?.envKeys?.isEmpty == false && !envEdited
                                   ? "\(server!.envKeys!.joined(separator: ", ")) (saved)"
                                   : "None", detail: "Values are kept in the Keychain.") {
                            PillButton(title: "Add", systemImage: "plus") { env.append(EnvRow()); envEdited = true }
                        }
                    } else {
                        ForEach($env) { $row in
                            HStack(spacing: 8) {
                                InlineField(text: $row.key, placeholder: "API_KEY", monospaced: true, width: 150)
                                InlineField(text: $row.value, placeholder: "value", secure: true, width: 230)
                                Spacer(minLength: 0)
                                IconButton(systemImage: "minus.circle", help: "Remove") { env.removeAll { $0.id == row.id } }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                        }
                        HStack {
                            PillButton(title: "Add variable", systemImage: "plus") { env.append(EnvRow()) }
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                    }
                }
            }
            if server == nil, let note = preset?.note {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 12)
            }
            HStack {
                Spacer()
                if let onCancel { PillButton(title: "Cancel", systemImage: "xmark", action: onCancel) }
                PillButton(title: saving ? "Connecting…" : (server == nil ? "Add server" : "Save"),
                           systemImage: "checkmark", prominent: true) { save() }
                    .disabled(saving)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        if server == nil, let preset {
            remote = preset.isRemote
            name = preset.name
            url = preset.url ?? ""
            commandLine = preset.command ?? ""
            env = preset.envKeys.map { EnvRow(key: $0) }
            envEdited = !env.isEmpty
            return
        }
        guard let server else { return }
        remote = server.isRemote
        name = server.name
        url = server.url ?? ""
        commandLine = server.commandLine
    }

    private func save() {
        var params: [String: Any] = ["name": name, "transport": remote ? "http" : "stdio"]
        if remote {
            params["url"] = url
            if !token.isEmpty { params["token"] = token }
        } else {
            let parts = Self.split(commandLine)
            guard let command = parts.first else { error = "Enter the command that starts the server"; return }
            params["command"] = command
            params["args"] = Array(parts.dropFirst())
            if server == nil || envEdited {
                let filled = env.filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
                params["env"] = Dictionary(filled.map { ($0.key.trimmingCharacters(in: .whitespaces), $0.value) }, uniquingKeysWith: { _, b in b })
            }
        }
        saving = true
        error = nil
        Task {
            let result = await brain.saveMcpServer(id: server?.id, params)
            if let id = result.id {
                // Connect right away so the tools (or the problem) show up.
                error = await brain.testMcpServer(id)
                if error == nil || server == nil { onSaved(id) }
            } else {
                error = result.error
            }
            saving = false
        }
    }

    /// Splits a command line like a shell: spaces separate, quotes group, ~ expands.
    static func split(_ line: String) -> [String] {
        var parts: [String] = [], current = "", quote: Character?, any = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; any = true
            } else if ch == " " || ch == "\t" {
                if any || !current.isEmpty { parts.append(current); current = ""; any = false }
            } else {
                current.append(ch)
            }
        }
        if any || !current.isEmpty { parts.append(current) }
        return parts.map { $0.hasPrefix("~/") ? NSHomeDirectory() + $0.dropFirst() : $0 }
    }
}

struct AddMcpServerPage: View {
    @ObservedObject var brain: Brain
    let onAdded: (String) -> Void
    @State private var preset: McpPreset?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Add MCP server", subtitle: "Give bots more tools: GitHub, files, search, your own services. Then choose which bots can use it.", icon: "puzzlepiece.extension")
            Text("Popular").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                .padding(.leading, 4).padding(.bottom, 8)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8)], spacing: 8) {
                ForEach(McpPreset.catalog) { p in
                    McpPresetTile(preset: p, selected: preset?.id == p.id) { preset = preset?.id == p.id ? nil : p }
                }
            }
            .padding(.bottom, 20)
            Text(preset == nil ? "Or add your own" : preset!.name)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                .padding(.leading, 4).padding(.bottom, 8)
            McpServerForm(brain: brain, preset: preset, onSaved: onAdded)
                .id(preset?.id ?? "custom")
        }
    }
}

private struct McpPresetTile: View {
    let preset: McpPreset
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: preset.icon).font(.system(size: 14))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(preset.isRemote ? "Remote" : "Local") · \(preset.detail)")
                        .font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.raised : (hovering ? Theme.surface : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Theme.text.opacity(0.6) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(preset.name), \(preset.detail)")
    }
}

struct McpServerPage: View {
    @ObservedObject var brain: Brain
    let server: Brain.McpServer
    let onRemoved: () -> Void
    @State private var editing = false
    @State private var testing = false
    @State private var confirmRemove = false

    private var botsUsing: [Brain.Bot] {
        server.allBots == true ? brain.bots : brain.bots.filter { $0.mcpServers?.contains(server.id) == true }
    }
    private var isConnector: Bool { server.connector != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let connector = server.connector {
                HStack(alignment: .center, spacing: 14) {
                    ConnectorLogo(id: connector, name: server.name, size: 44)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(server.name).font(.system(size: 20, weight: .semibold))
                            HStack(spacing: 5) {
                                Circle().fill(server.stateColor).frame(width: 6, height: 6)
                                Text(server.stateLabel).font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.surface)).overlay(Capsule().stroke(Theme.border))
                        }
                        Text("Connector · signed in through the browser").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.bottom, 24)
            } else {
                PageHeader(title: server.name,
                           subtitle: server.isRemote ? (server.url ?? "") : server.commandLine,
                           icon: server.isRemote ? "globe" : "terminal",
                           badge: (server.stateLabel, server.stateColor))
            }
            if editing {
                McpServerForm(brain: brain, server: server, onSaved: { _ in editing = false }, onCancel: { editing = false })
            } else {
                Card {
                    SettingRow(label: "Enabled", detail: "Off: no bot gets its tools.") {
                        Toggle("", isOn: Binding(
                            get: { server.enabled },
                            set: { on in Task { _ = await brain.saveMcpServer(id: server.id, ["enabled": on]) } }
                        )).toggleStyle(.switch).labelsHidden()
                    }
                    SettingRow(label: "Available to",
                               detail: server.allBots == true ? "Every bot can use it when a task needs it."
                                   : botsUsing.isEmpty ? "No bot yet. Pick them below." : botsUsing.map(\.name).joined(separator: ", ")) {
                        Picker("", selection: Binding(
                            get: { server.allBots == true },
                            set: { all in Task { _ = await brain.saveMcpServer(id: server.id, ["allBots": all]) } }
                        )) {
                            Text("All bots").tag(true)
                            Text("Some bots").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                    }
                    if server.allBots != true {
                        ForEach(brain.bots) { bot in
                            SettingRow(label: bot.name) {
                                Toggle("", isOn: Binding(
                                    get: { bot.mcpServers?.contains(server.id) == true },
                                    set: { on in Task { await brain.setBotMcpServer(bot.id, server.id, on: on) } }
                                )).toggleStyle(.switch).controlSize(.small).labelsHidden()
                            }
                        }
                    }
                }
                Card(title: "Tools") {
                    if let tools = server.tools, !tools.isEmpty {
                        ForEach(tools) { t in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.system(size: 12, design: .monospaced))
                                if let d = t.description, !d.isEmpty {
                                    Text(d).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                        }
                    } else {
                        SettingRow(label: server.tools == nil ? "Not connected yet" : "This server has no tools",
                                   detail: server.tools == nil ? "Test the connection to list them." : nil) { EmptyView() }
                    }
                }
                if server.state == "signin" || server.state == "error", isConnector {
                    HStack {
                        Label(server.signingIn == true ? "Finish signing in in your browser." : "Sign in again to keep using it.",
                              systemImage: "person.badge.key").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                        Spacer()
                        PillButton(title: server.signingIn == true ? "Open again" : "Sign in", systemImage: "arrow.up.forward.app", prominent: true) {
                            Task { _ = await brain.connect(server.connector!) }
                        }
                    }
                    .padding(.bottom, 20)
                }
                if !server.errors.isEmpty {
                    Card(title: "Recent errors") {
                        ForEach(server.errors, id: \.self) { e in
                            Text(e.message).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
                                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14).padding(.vertical, 9)
                        }
                    }
                }
                HStack {
                    DestructiveButton(title: isConnector ? "Disconnect" : "Remove") { confirmRemove = true }
                    Spacer()
                    if !isConnector {
                        PillButton(title: "Edit", systemImage: "pencil") { editing = true }
                    }
                    PillButton(title: testing ? "Testing…" : "Test", systemImage: "bolt.horizontal", prominent: true) {
                        testing = true
                        Task { _ = await brain.testMcpServer(server.id); testing = false }
                    }
                    .disabled(testing || !server.enabled)
                }
            }
        }
        .confirmationDialog("\(isConnector ? "Disconnect" : "Remove") \(server.name)?", isPresented: $confirmRemove) {
            Button(isConnector ? "Disconnect" : "Remove", role: .destructive) {
                Task { await brain.removeMcpServer(server.id); onRemoved() }
            }
        } message: {
            Text(isConnector ? "Bots stop using it, and Local Bot forgets the sign-in." : "Bots stop using its tools. Its saved token and variables are deleted from the Keychain.")
        }
    }
}
