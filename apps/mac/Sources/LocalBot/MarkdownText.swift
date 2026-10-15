import SwiftUI
import AppKit

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
            RichText(text: inline(text), size: 13)
        case .heading(let level, let text):
            RichText(text: inline(text), size: level == 1 ? 17 : level == 2 ? 15 : 13, weight: .semibold)
                .padding(.top, 2)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    // Top-aligned: the AppKit text has no baseline SwiftUI can align to.
                    HStack(alignment: .top, spacing: 6) {
                        Text(item.marker)
                            .font(.system(size: 13).monospacedDigit())
                            .foregroundStyle(.secondary)
                        RichText(text: inline(item.text), size: 13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
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
        var attr = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        // Bare URLs and domains ("example.com/page") become links too.
        let plain = String(attr.characters)
        let matches = Self.links?.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) ?? []
        for match in matches {
            guard let url = match.url, let r = Range(match.range, in: plain) else { continue }
            let start = attr.index(attr.startIndex, offsetByCharacters: plain.distance(from: plain.startIndex, to: r.lowerBound))
            let end = attr.index(start, offsetByCharacters: plain.distance(from: r.lowerBound, to: r.upperBound))
            if attr[start..<end].runs.allSatisfy({ $0.link == nil && $0.inlinePresentationIntent?.contains(.code) != true }) {
                attr[start..<end].link = url
            }
        }
        return attr
    }

    private static let links = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
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

/// Inline markdown drawn by AppKit: selectable, and links get the pointing-hand
/// cursor and open in the browser (SwiftUI's Text can't change the cursor).
struct RichText: NSViewRepresentable {
    let text: AttributedString
    var size: CGFloat
    var weight: NSFont.Weight = .regular

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor(Theme.link),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let rendered = attributed()
        if view.textStorage?.isEqual(to: rendered) != true { view.textStorage?.setAttributedString(rendered) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let container = view.textContainer, let layout = view.layoutManager else { return nil }
        // No width, or "as wide as you like": lay out on one line and hug it.
        let given = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let width = max(given ?? .greatestFiniteMagnitude, 20)
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        return CGSize(width: given ?? ceil(used.width), height: ceil(used.height))
    }

    private func attributed() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code)
                ? NSFont.monospacedSystemFont(ofSize: size - 1, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: intent.contains(.stronglyEmphasized) ? .semibold : weight)
            if intent.contains(.emphasized) {
                font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
            }
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor(Theme.text), .paragraphStyle: paragraph,
            ]
            if intent.contains(.strikethrough) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if intent.contains(.code) { attrs[.backgroundColor] = NSColor(Theme.raised) }
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: String(text[run.range].characters), attributes: attrs))
        }
        return out
    }
}
