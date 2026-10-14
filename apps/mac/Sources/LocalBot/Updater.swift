import SwiftUI
import AppKit

/// Checks GitHub Releases for a newer Local Bot. Nothing is downloaded or
/// installed here: the user gets the release page and installs the DMG like
/// the first time.
@MainActor
final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let notes: String
        let page: URL
    }

    static let repo = "patrick-mns/localbot"

    /// A newer release than the running app, if any.
    @Published private(set) var available: Release?

    /// The running version: the bundle's, or `LOCALBOT_VERSION_OVERRIDE` to try
    /// the flow from source (a dev build has no bundle version and never checks).
    let current: String? = ProcessInfo.processInfo.environment["LOCALBOT_VERSION_OVERRIDE"]
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String

    private var started = false

    /// Checks now and then every few hours while the app runs.
    func start(onFound: @escaping (Release) -> Void) {
        guard !started, current != nil else { return }
        started = true
        Task {
            while true {
                if let release = await latest(), release != available {
                    available = release
                    onFound(release)
                }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    /// The modal shows once per version; the sidebar keeps the nudge.
    func shouldPrompt(_ release: Release) -> Bool {
        UserDefaults.standard.string(forKey: "updatePromptedVersion") != release.version
    }

    func markPrompted(_ release: Release) {
        UserDefaults.standard.set(release.version, forKey: "updatePromptedVersion")
    }

    private func latest() async -> Release? {
        guard let current,
              let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, than: current) else { return nil }
        // Only ever send the user to this repo's releases, whatever the API says.
        let page = URL(string: "https://github.com/\(Self.repo)/releases/tag/\(tag)")
            ?? URL(string: "https://github.com/\(Self.repo)/releases/latest")!
        return Release(version: version, notes: json["body"] as? String ?? "", page: page)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (v: String) in v.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

struct UpdateSheet: View {
    @ObservedObject var updater: Updater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: AppIcon.image()).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text("A new version of Local Bot is available").font(.system(size: 17, weight: .semibold))
                    Text("Version \(updater.available?.version ?? "") is out. You have \(updater.current ?? "?").")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }

            if let notes = updater.available?.notes, !notes.isEmpty {
                ScrollView {
                    MarkdownText(text: notes)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                .hairline(10)
            }

            Text("Download the DMG from GitHub, quit Local Bot and drag the new version to Applications. Your bots, chats and keys stay as they are.")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                PillButton(title: "Later", systemImage: "xmark") { dismiss() }
                PillButton(title: "Download", systemImage: "arrow.down.circle", prominent: true) {
                    if let page = updater.available?.page { NSWorkspace.shared.open(page) }
                    dismiss()
                }
            }
        }
        .padding(26)
        .frame(width: 520)
        .background(Theme.sidebar)
    }
}

/// The sidebar's standing nudge while an update is available.
struct UpdateBanner: View {
    let version: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Theme.live)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update available").font(.system(size: 12, weight: .semibold))
                    Text("Version \(version)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? Theme.raised : Theme.surface))
            .hairline(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
