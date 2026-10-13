import SwiftUI

struct ChatView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var brain: Brain
    let bot: Brain.Bot
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var messages: [Brain.Message] { brain.messages[bot.id] ?? [] }
    private var thinking: Bool { brain.thinking.contains(bot.id) }
    private var ready: Bool { brain.providerStatus?.configured == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            if messages.isEmpty {
                Placeholder(icon: "bubble.left", text: "Chat with \(bot.name)",
                            detail: ready ? "Give it a task or ask a question." : "Add an AI provider in Settings to start.")
            } else {
                transcript
            }
            composer
        }
        .background(Theme.sidebar)
        .task { await brain.loadHistory(bot.id) }
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack(spacing: 10) {
            AnimatedFace(face: bot.face, size: 26, working: thinking, seed: bot.id)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name).font(.system(size: 13, weight: .semibold))
                Text(bot.model).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            Spacer()
            IconButton(systemImage: "trash", help: "Clear conversation") { Task { await brain.clearChat(bot.id) } }
            IconButton(systemImage: "slider.horizontal.3", help: "Bot settings") { model.sheet = .editBot(bot.id) }
            PanelToggle(side: .trailing)
        }
        .padding(.leading, 16).padding(.trailing, 12)
        .frame(height: titleBarHeight)
        .background(Theme.sidebar)
        .dragsWindow()
        .zIndex(1)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(messages) { message in
                        MessageRow(message: message, bot: bot, streaming: thinking && message.id == messages.last?.id)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 18)
                .thinScrollers()
            }
            .onChange(of: messages.last?.text) {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .fadesUnderTopBar(Theme.sidebar)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(ready ? "Message \(bot.name)…" : "Add an AI provider in Settings",
                          text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...8)
                    .focused($focused)
                    .disabled(!ready)
                    .onSubmit(send)
                    .padding(.vertical, 6)
                Button(action: thinking ? stop : send) {
                    Image(systemName: thinking ? "stop.fill" : "arrow.up")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(canSend || thinking ? Theme.onText : Theme.tertiary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(canSend || thinking ? Theme.text : Theme.raised))
                }
                .buttonStyle(.plain)
                .disabled(!canSend && !thinking)
                .accessibilityLabel(thinking ? "Stop" : "Send")
            }
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface))
            .hairline(18)
            .padding(14)
        }
    }

    private var canSend: Bool { ready && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        guard canSend, !thinking else { return }
        let text = draft
        draft = ""
        Task { await brain.send(text, to: bot.id) }
    }

    private func stop() { Task { await brain.stop(bot.id) } }
}

struct MessageRow: View {
    let message: Brain.Message
    let bot: Brain.Bot
    let streaming: Bool

    var body: some View {
        if message.role == "activity" {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.motionlines").font(.system(size: 10))
                Text(message.text).font(.system(size: 11)).lineLimit(2)
            }
            .foregroundStyle(Theme.tertiary)
            .padding(.leading, 32)
        } else if message.role == "user" {
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Theme.raised))
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                Avatar(svg: bot.avatar, size: 22).padding(.top, 1)
                VStack(alignment: .leading, spacing: 6) {
                    if message.text.isEmpty && message.error == nil {
                        TypingDots()
                    } else if !message.text.isEmpty {
                        Text(markdown(message.text))
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = message.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(Theme.danger)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(Theme.secondary).frame(width: 5, height: 5)
                        .opacity(0.3 + 0.7 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
            .padding(.vertical, 6)
        }
    }
}
