import SwiftUI
import AppKit

/// Shows a remote device's share code: one string another Local Bot pastes
/// into "Connect a machine" to use the same machine.
struct ShareDeviceSheet: View {
    @ObservedObject var brain: Brain
    let deviceID: String
    @Environment(\.dismiss) private var dismiss

    @State private var code: String?
    @State private var failed = false
    @State private var copied = false
    @State private var revealed = false

    private var device: Brain.Computer? { brain.computers.first { $0.id == deviceID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Share \(device?.name ?? "device")").font(.system(size: 17, weight: .semibold))
                Text("In another Local Bot: Add device → Connect a machine, then paste this code.")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }

            Group {
                if let code {
                    HStack(spacing: 10) {
                        Text(revealed ? code : String(code.prefix(22)) + String(repeating: "•", count: 18))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(revealed ? 4 : 1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        IconButton(systemImage: revealed ? "eye.slash" : "eye", help: revealed ? "Hide" : "Show") { revealed.toggle() }
                    }
                } else if failed {
                    Text("Couldn’t make a share code for this device.").font(.system(size: 12)).foregroundStyle(Theme.danger)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .hairline(10)

            Label("Anyone with this code can see and control the machine. Share it only with people you trust; to cut access, remove the device and create a new one.",
                  systemImage: "exclamationmark.shield")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                PillButton(title: "Done", systemImage: "xmark") { dismiss() }
                PillButton(title: copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc", prominent: true) { copy() }
                    .disabled(code == nil)
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Theme.sidebar)
        .task {
            code = await brain.shareDevice(deviceID)
            failed = code == nil
        }
    }

    private func copy() {
        guard let code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
    }
}
