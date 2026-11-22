// Turns the Mac's transcript Markdown (frontmatter already stripped, chunks
// joined in order — see specs/001 transcript-format.md) into blocks the
// detail screen renders: `# 14:03 – 14:18 (…)` headings and
// `[HH:MM:SS · mic] text` runs, whose heads become mono timestamps.

import Foundation

enum TranscriptBlock: Equatable, Identifiable {
    case heading(String)
    case run(time: String, source: String, text: String)
    case paragraph(String)

    var id: String {
        switch self {
        case let .heading(text): return "h:\(text)"
        case let .run(time, source, text): return "r:\(time):\(source):\(text.prefix(40))"
        case let .paragraph(text): return "p:\(text.prefix(60))"
        }
    }
}

enum TranscriptParser {
    static func parse(_ markdown: String) -> [TranscriptBlock] {
        var blocks: [TranscriptBlock] = []
        var seen = Set<String>()
        for paragraph in paragraphs(in: stripFrontmatter(markdown)) {
            let block = classify(paragraph)
            // Keep identifiers unique for ForEach even if text repeats.
            var unique = block
            var counter = 1
            while seen.contains(unique.id) {
                counter += 1
                unique = disambiguate(block, counter)
            }
            seen.insert(unique.id)
            blocks.append(unique)
        }
        return blocks
    }

    /// First spoken text, for list excerpts.
    static func excerpt(_ markdown: String, maxLength: Int = 160) -> String? {
        for block in parse(markdown) {
            switch block {
            case let .run(_, _, text) where !text.isEmpty:
                return String(text.prefix(maxLength))
            case let .paragraph(text) where !text.hasPrefix("_("):
                return String(text.prefix(maxLength))
            default:
                continue
            }
        }
        return nil
    }

    // MARK: internals

    private static let runPattern = try! NSRegularExpression(
        pattern: #"^\[(\d{1,2}:\d{2}(?::\d{2})?)\s*·\s*([^\]]+?)\]\s*(.*)$"#,
        options: [.dotMatchesLineSeparators])

    private static func classify(_ paragraph: String) -> TranscriptBlock {
        if paragraph.hasPrefix("#") {
            let text = paragraph.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            return .heading(text)
        }
        let range = NSRange(paragraph.startIndex..., in: paragraph)
        if let match = runPattern.firstMatch(in: paragraph, range: range),
           let time = Range(match.range(at: 1), in: paragraph),
           let source = Range(match.range(at: 2), in: paragraph),
           let text = Range(match.range(at: 3), in: paragraph) {
            return .run(
                time: String(paragraph[time]),
                source: paragraph[source].trimmingCharacters(in: .whitespaces),
                text: joinLines(String(paragraph[text])))
        }
        return .paragraph(joinLines(paragraph))
    }

    private static func disambiguate(_ block: TranscriptBlock, _ n: Int) -> TranscriptBlock {
        switch block {
        case let .heading(text): return .heading(text + String(repeating: "\u{200B}", count: n))
        case let .run(time, source, text): return .run(time: time, source: source, text: text + String(repeating: "\u{200B}", count: n))
        case let .paragraph(text): return .paragraph(text + String(repeating: "\u{200B}", count: n))
        }
    }

    static func stripFrontmatter(_ markdown: String) -> String {
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return normalized }
        let body = normalized.dropFirst(4)
        guard let end = body.range(of: "\n---\n") else { return normalized }
        return String(body[end.upperBound...])
    }

    private static func paragraphs(in text: String) -> [String] {
        text.components(separatedBy: "\n")
            .split(whereSeparator: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            .flatMap { lines -> [String] in
                // A heading line directly followed by text is its own block.
                var result: [String] = []
                var current: [String] = []
                for line in lines {
                    if line.hasPrefix("#") || isRunHead(line) {
                        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
                        current = [line]
                        if line.hasPrefix("#") {
                            result.append(line)
                            current = []
                        }
                    } else {
                        current.append(line)
                    }
                }
                if !current.isEmpty { result.append(current.joined(separator: "\n")) }
                return result
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let runHeadPattern = try! NSRegularExpression(pattern: #"^\[\d{1,2}:\d{2}"#)

    private static func isRunHead(_ line: String) -> Bool {
        runHeadPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private static func joinLines(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
