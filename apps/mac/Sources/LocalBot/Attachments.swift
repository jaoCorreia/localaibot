import SwiftUI
import AppKit
import QuickLook
import QuickLookThumbnailing
import UniformTypeIdentifiers
import AVFoundation

/// Files a bot shared in the chat. One document gets a preview card, images a
/// grid, several files a list with "Download all", anything without a preview
/// a compact row.
struct AttachmentsView: View {
    let files: [Brain.Attachment]
    let botID: String

    private var images: [Brain.Attachment] { files.filter(\.isImage) }
    private var others: [Brain.Attachment] { files.filter { !$0.isImage } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty { ImageGrid(files: images, botID: botID) }
            if others.count == 1, let file = others.first {
                if file.hasPreview { PreviewCard(file: file, botID: botID) } else { CompactCard(file: file, botID: botID) }
            } else if others.count > 1 {
                FileList(files: others, botID: botID)
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
    }
}

// MARK: Local copies

/// Shared files are fetched from the brain once and kept in the app's cache,
/// so previews, Quick Look and dragging to Finder work on real files.
@MainActor
final class SharedFiles {
    static let shared = SharedFiles()
    private var loading: [String: Task<URL?, Never>] = [:]

    private let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalBot/files", isDirectory: true)

    func cached(_ file: Brain.Attachment) -> URL? {
        let url = path(file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func local(_ file: Brain.Attachment, botID: String) async -> URL? {
        if let url = cached(file) { return url }
        if let task = loading[file.id] { return await task.value }
        let task = Task<URL?, Never> {
            guard let data = await Brain.shared?.fileData(botID: botID, fileID: file.id) else { return nil }
            let url = path(file)
            // Written off the main thread so the chat stays smooth.
            return await Task.detached(priority: .userInitiated) { () -> URL? in
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
            }.value
        }
        loading[file.id] = task
        let url = await task.value
        loading[file.id] = nil
        return url
    }

    /// Copies into ~/Downloads (never overwriting) and shows it in Finder.
    func download(_ files: [Brain.Attachment], botID: String) async {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var saved: [URL] = []
        for file in files {
            guard let source = await local(file, botID: botID) else { continue }
            let target = unique(downloads.appendingPathComponent(file.name))
            if (try? FileManager.default.copyItem(at: source, to: target)) != nil { saved.append(target) }
        }
        if !saved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(saved) }
    }

    private func path(_ file: Brain.Attachment) -> URL {
        root.appendingPathComponent(file.id, isDirectory: true).appendingPathComponent(file.name)
    }

    private func unique(_ url: URL) -> URL {
        var candidate = url
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// Small files are fetched as soon as they show up, for thumbnails and dragging.
private let prefetchLimit = 15 * 1024 * 1024

private struct FileActions {
    let file: Brain.Attachment
    let botID: String
    let quickLook: Binding<URL?>

    func open() {
        Task { if let url = await SharedFiles.shared.local(file, botID: botID) { quickLook.wrappedValue = url } }
    }

    func download() {
        Task { await SharedFiles.shared.download([file], botID: botID) }
    }
}

// MARK: Cards

/// B: one document with its first page.
private struct PreviewCard: View {
    let file: Brain.Attachment
    let botID: String
    @State private var thumbnail: NSImage?
    @State private var quickLook: URL?

    var body: some View {
        let actions = FileActions(file: file, botID: botID, quickLook: $quickLook)
        VStack(spacing: 0) {
            ZStack {
                Theme.surface
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .padding(14)
                } else {
                    FileIcon(file: file, size: 34)
                }
            }
            .frame(height: 170)
            .contentShape(Rectangle())
            .onTapGesture { actions.open() }
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 10) {
                FileTitle(file: file)
                PillButton(title: "Open", systemImage: "eye") { actions.open() }
                PillButton(title: "Download", systemImage: "arrow.down", prominent: true) { actions.download() }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebar))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .hairline(12)
        .draggableFile(file, botID: botID)
        .quickLookPreview($quickLook)
        .task(id: file.id) { thumbnail = await Thumbnails.image(for: file, botID: botID, size: CGSize(width: 240, height: 300)) }
    }
}

/// A: one file without a preview.
private struct CompactCard: View {
    let file: Brain.Attachment
    let botID: String
    @State private var quickLook: URL?

    var body: some View {
        let actions = FileActions(file: file, botID: botID, quickLook: $quickLook)
        HStack(spacing: 12) {
            if file.isAudio {
                PlayButton(file: file, botID: botID, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                    AudioProgress(file: file)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                AudioTimeOrSize(file: file)
            } else {
                FileIcon(file: file, size: 18)
                FileTitle(file: file)
            }
            IconButton(systemImage: "arrow.down", help: "Download") { actions.download() }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebar))
        .hairline(12)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.open() }
        .draggableFile(file, botID: botID)
        .quickLookPreview($quickLook)
    }
}

/// C: several files, each downloadable, plus all at once.
private struct FileList: View {
    let files: [Brain.Attachment]
    let botID: String
    @State private var quickLook: URL?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(files) { file in
                let actions = FileActions(file: file, botID: botID, quickLook: $quickLook)
                HStack(spacing: 10) {
                    if file.isAudio {
                        PlayButton(file: file, botID: botID, size: 22)
                    } else {
                        FileIcon(file: file, size: 15, compact: true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        if file.isAudio { AudioProgress(file: file) }
                    }
                    Spacer(minLength: 6)
                    AudioTimeOrSize(file: file)
                    IconButton(systemImage: "arrow.down", help: "Download") { actions.download() }
                }
                .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { actions.open() }
                .draggableFile(file, botID: botID)
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            HStack {
                Text("\(files.count) files · \(Brain.Attachment.format(files.reduce(0) { $0 + $1.size }))")
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                PillButton(title: "Download all", systemImage: "arrow.down.circle") {
                    Task { await SharedFiles.shared.download(files, botID: botID) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.sidebar))
        .hairline(12)
        .quickLookPreview($quickLook)
    }
}

/// D: images inline; click opens Quick Look, drag goes to Finder.
private struct ImageGrid: View {
    let files: [Brain.Attachment]
    let botID: String
    @State private var quickLook: URL?

    var body: some View {
        let columns = files.count == 1 ? 1 : files.count == 2 ? 2 : 3
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(files) { file in
                ImageTile(file: file, botID: botID, tall: files.count == 1) {
                    FileActions(file: file, botID: botID, quickLook: $quickLook).open()
                }
            }
        }
        .quickLookPreview($quickLook)
    }
}

private struct ImageTile: View {
    let file: Brain.Attachment
    let botID: String
    let tall: Bool
    let open: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The tile's size comes from the clear base; the photo fills it
            // and is clipped, so a wide image can't push its column wider.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: tall ? 240 : 110)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Theme.surface.overlay(ProgressView().controlSize(.small))
                    }
                }
                .clipped()
            if hovering {
                IconButton(systemImage: "arrow.down", help: "Download") {
                    Task { await SharedFiles.shared.download([file], botID: botID) }
                }
                .background(Circle().fill(Theme.sidebar.opacity(0.9)))
                .padding(6)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .hairline(10)
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .draggableFile(file, botID: botID)
        .help(file.name)
        .task(id: file.id) {
            if let url = await SharedFiles.shared.local(file, botID: botID) { image = NSImage(contentsOf: url) }
        }
    }
}

// MARK: Pieces

private struct FileTitle: View {
    let file: Brain.Attachment

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.name).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
            Text("\(file.kind) · \(file.sizeText)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tinted square with the file type's symbol.
private struct FileIcon: View {
    let file: Brain.Attachment
    var size: CGFloat
    var compact = false

    var body: some View {
        let (symbol, color) = file.symbol
        if compact {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(color).frame(width: 18)
        } else {
            Image(systemName: symbol).font(.system(size: size)).foregroundStyle(color)
                .frame(width: size * 2, height: size * 2)
                .background(RoundedRectangle(cornerRadius: size * 0.5).fill(color.opacity(0.16)))
        }
    }
}

private extension View {
    /// Drags the real file to Finder or another app once it's on this Mac.
    func draggableFile(_ file: Brain.Attachment, botID: String) -> some View {
        onDrag {
            if let url = SharedFiles.shared.cached(file), let provider = NSItemProvider(contentsOf: url) { return provider }
            Task { _ = await SharedFiles.shared.local(file, botID: botID) }
            return NSItemProvider()
        }
    }
}

enum Thumbnails {
    @MainActor
    static func image(for file: Brain.Attachment, botID: String, size: CGSize) async -> NSImage? {
        guard file.size <= prefetchLimit, let url = await SharedFiles.shared.local(file, botID: botID) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

extension Brain.Attachment {
    var ext: String { (name as NSString).pathExtension.lowercased() }
    var isImage: Bool { mime.hasPrefix("image/") && mime != "image/svg+xml" }
    var isAudio: Bool { mime.hasPrefix("audio/") || ["mp3", "wav", "m4a", "aac", "flac", "ogg", "aiff"].contains(ext) }
    /// Types Quick Look draws a page of.
    var hasPreview: Bool { ["pdf", "docx", "doc", "xlsx", "pptx", "key", "pages", "numbers", "txt", "md", "csv", "html", "rtf"].contains(ext) }

    var kind: String { ext.isEmpty ? "File" : ext.uppercased() }

    var sizeText: String { Self.format(size) }

    static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    var symbol: (String, Color) {
        switch ext {
        case "pdf": return ("doc.richtext", Color(red: 0.95, green: 0.45, blue: 0.42))
        case "xlsx", "xls", "csv", "numbers": return ("tablecells", Color(red: 0.45, green: 0.80, blue: 0.55))
        case "docx", "doc", "pages", "rtf", "txt", "md": return ("doc.text", Color(red: 0.40, green: 0.60, blue: 1.0))
        case "pptx", "key": return ("rectangle.on.rectangle", Color(red: 0.98, green: 0.65, blue: 0.30))
        case "zip", "gz", "tar", "7z": return ("doc.zipper", Theme.secondary)
        case "mp4", "mov", "webm": return ("film", Color(red: 0.75, green: 0.55, blue: 1.0))
        case "mp3", "wav", "m4a": return ("waveform", Color(red: 0.75, green: 0.55, blue: 1.0))
        case "json", "js", "ts", "py", "sh", "swift", "html": return ("chevron.left.forwardslash.chevron.right", Theme.secondary)
        default: return ("doc", Theme.secondary)
        }
    }
}


// MARK: Audio

/// One audio file at a time plays from the chat; this tracks which and where.
@MainActor
final class ChatAudio: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = ChatAudio()
    @Published private(set) var current: String?
    @Published private(set) var playing = false
    @Published private(set) var loading: String?
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(_ file: Brain.Attachment, botID: String) {
        if current == file.id, let player {
            if player.isPlaying { player.pause(); playing = false; stopTimer() }
            else { player.play(); playing = true; startTimer() }
            return
        }
        stop()
        loading = file.id
        Task {
            defer { if loading == file.id { loading = nil } }
            guard let url = await SharedFiles.shared.local(file, botID: botID) else { return }
            // Opening a WAV reads and checks the whole file: do it off the main thread.
            let made = await Task.detached(priority: .userInitiated) { () -> AVAudioPlayer? in
                guard let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
                p.prepareToPlay()
                return p
            }.value
            guard let next = made, loading == file.id || current == nil else { return }
            next.delegate = self
            player = next
            current = file.id
            duration = next.duration
            position = 0
            next.play()
            playing = true
            startTimer()
        }
    }

    func seek(_ file: Brain.Attachment, to fraction: Double) {
        guard current == file.id, let player else { return }
        player.currentTime = max(0, min(1, fraction)) * player.duration
        position = player.currentTime
    }

    func stop() {
        player?.stop()
        player = nil
        current = nil
        playing = false
        position = 0
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.position = p.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.playing = false
            self.position = 0
            self.stopTimer()
        }
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct PlayButton: View {
    let file: Brain.Attachment
    let botID: String
    var size: CGFloat
    @ObservedObject private var audio = ChatAudio.shared
    @State private var hovering = false

    private var isCurrent: Bool { audio.current == file.id }

    var body: some View {
        Button { audio.toggle(file, botID: botID) } label: {
            ZStack {
                Circle().fill(isCurrent || hovering ? Theme.text : Theme.raised)
                if audio.loading == file.id {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: isCurrent && audio.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(isCurrent || hovering ? Theme.onText : Theme.text)
                        .offset(x: isCurrent && audio.playing ? 0 : size * 0.04)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // Fetch it as soon as it shows up, so the first play starts right away.
        .task(id: file.id) {
            if file.size <= prefetchLimit { _ = await SharedFiles.shared.local(file, botID: botID) }
        }
        .help(isCurrent && audio.playing ? "Pause" : "Play")
        .accessibilityLabel(isCurrent && audio.playing ? "Pause \(file.name)" : "Play \(file.name)")
    }
}

/// A thin progress bar for the playing file; click to jump.
private struct AudioProgress: View {
    let file: Brain.Attachment
    @ObservedObject private var audio = ChatAudio.shared

    var body: some View {
        let isCurrent = audio.current == file.id
        let fraction = isCurrent && audio.duration > 0 ? audio.position / audio.duration : 0
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.raised)
                Capsule().fill(Theme.text).frame(width: max(0, g.size.width * fraction))
            }
            .contentShape(Rectangle())
            .onTapGesture { location in audio.seek(file, to: location.x / max(g.size.width, 1)) }
        }
        .frame(height: 3)
        .opacity(isCurrent ? 1 : 0.6)
    }
}

/// Elapsed / total while it's the current file, the size otherwise.
private struct AudioTimeOrSize: View {
    let file: Brain.Attachment
    @ObservedObject private var audio = ChatAudio.shared

    var body: some View {
        Text(audio.current == file.id
             ? "\(ChatAudio.format(audio.position)) / \(ChatAudio.format(audio.duration))"
             : file.sizeText)
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
    }
}
