import SwiftUI

/// Pick a kind of device, name it, create it. Unavailable kinds are shown so
/// the roadmap is visible (simulators, remote machines).
struct NewDeviceSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var brain: Brain
    @Environment(\.dismiss) private var dismiss

    @State private var kinds: [Brain.DeviceKind] = []
    @State private var kind: String?
    @State private var name = ""
    @State private var creating = false

    private var selected: Brain.DeviceKind? { kinds.first { $0.id == kind } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add device").font(.system(size: 17, weight: .semibold))
                Text("Devices are the machines bots work on. Each one is isolated from your Mac.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(kinds) { k in
                    KindCard(kind: k, selected: k.id == kind) {
                        guard k.available else { return }
                        kind = k.id
                        if name.isEmpty || kinds.contains(where: { defaultName($0.id) == name }) { name = defaultName(k.id) }
                    }
                }
            }
            if kinds.isEmpty { ProgressView().controlSize(.small).frame(maxWidth: .infinity) }

            if selected != nil {
                Field(label: "Name", text: $name, placeholder: "e.g. Sales desktop")
            }

            if kind == "lume" {
                Label("This downloads macOS (~17 GB) and installs it unattended. It can take 30–60 minutes; the device shows as “Being created…” until it’s ready.",
                      systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }

            HStack {
                Spacer()
                PillButton(title: "Cancel", systemImage: "xmark") { dismiss() }
                PillButton(title: creating ? "Creating…" : "Create device", systemImage: "plus", prominent: true) { create() }
                    .disabled(kind == nil || name.trimmingCharacters(in: .whitespaces).isEmpty || creating)
            }
        }
        .padding(26)
        .frame(width: 700)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.sidebar)
        .task {
            kinds = await brain.deviceKinds()
            if let first = kinds.first(where: \.available) {
                kind = first.id
                name = defaultName(first.id)
            }
        }
    }

    private func defaultName(_ kind: String) -> String {
        let base = kind == "lume" ? "Mac" : "Linux"
        let taken = Set(brain.computers.map(\.name))
        if !taken.contains(base) { return base }
        return (2...99).map { "\(base) \($0)" }.first { !taken.contains($0) } ?? base
    }

    private func create() {
        guard let kind else { return }
        creating = true
        Task {
            if let id = await brain.createDevice(kind: kind, name: name.trimmingCharacters(in: .whitespaces)) {
                model.selection = .computer(id)
                dismiss()
            }
            creating = false
        }
    }
}

struct KindCard: View {
    let kind: Brain.DeviceKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: symbol).font(.system(size: 15))
                        .frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
                    Spacer()
                    if let reason = kind.reason, !kind.available {
                        Text(reason).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(Theme.raised))
                    } else if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.text)
                    }
                }
                Text(kind.label).font(.system(size: 13, weight: .semibold))
                Text(kind.detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.raised : (hovering && kind.available ? Theme.surface : Theme.window.opacity(0.0))))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Theme.text.opacity(0.6) : Theme.border, lineWidth: selected ? 1.5 : 1))
            .opacity(kind.available ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(!kind.available)
    }

    private var symbol: String {
        switch kind.id {
        case "docker": return "terminal"
        case "lume": return "apple.logo"
        case "ios-simulator": return "iphone"
        case "android-emulator": return "candybarphone"
        default: return "network"
        }
    }
}
