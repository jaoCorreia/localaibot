import SwiftUI

/// Renders a bot reply as markdown: headings, lists and fenced code blocks, with
/// inline styles (bold, italic, code, links) inside each block. Streaming text is
/// fine: an unclosed fence just runs to the end of the message.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(inline(text))
                .font(.system(size: 13))
                .lineSpacing(3)
        case .heading(let level, let text):
            Text(inline(text))
                .font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 13, weight: .semibold))
                .padding(.top, 2)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(inline(item.text))
                            .font(.system(size: 13))
                            .lineSpacing(3)
                    }
                    .padding(.leading, CGFloat(item.indent) * 14)
                }
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

enum MarkdownBlock: Equatable {
    struct Item: Equatable {
        var marker: String
        var text: String
        var indent: Int
    }

    case paragraph(String)
    case heading(Int, String)
    case list([Item])
    case code(String)

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var items: [Item] = []
        var code: [String]?

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            if !items.isEmpty { blocks.append(.list(items)) }
            paragraph = []; items = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if var lines = code {
                if trimmed.hasPrefix("```") { blocks.append(.code(lines.joined(separator: "\n"))); code = nil }
                else { lines.append(line); code = lines }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            if let heading = heading(trimmed) { flush(); blocks.append(heading); continue }
            if let item = item(line) {
                if !paragraph.isEmpty { flush() }
                items.append(item); continue
            }
            // A wrapped line continues the last list item; otherwise it's paragraph text.
            if !items.isEmpty, line.first == " " { items[items.count - 1].text += " " + trimmed; continue }
            if !items.isEmpty { flush() }
            paragraph.append(line)
        }
        if let lines = code { flush(); blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return .heading(hashes, line.dropFirst(hashes + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func item(_ line: String) -> Item? {
        let spaces = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(spaces)
        let indent = spaces / 2
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return Item(marker: "•", text: String(rest.dropFirst(2)), indent: indent)
        }
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 3 {
            let after = rest.dropFirst(digits.count)
            if let dot = after.first, ".)".contains(dot), after.dropFirst().first == " " {
                return Item(marker: "\(digits).", text: String(after.dropFirst(2)), indent: indent)
            }
        }
        return nil
    }
}
