import AppKit

/// Converts a subset of Markdown into a styled NSAttributedString for display in chat bubbles.
///
/// Supported elements: code blocks, inline code, bold, italic, headers, bullet lists,
/// blockquotes, and `[text](url)` links.
enum MarkdownRenderer {

    static func render(_ markdown: String, fontSize: CGFloat = 13, textColor: NSColor = .labelColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        var needsNewline = false

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                if needsNewline { result.append(newline()) }
                needsNewline = true
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let cl = lines[i]
                    if cl.trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
                    codeLines.append(cl)
                    i += 1
                }
                result.append(codeBlock(codeLines.joined(separator: "\n"), fontSize: fontSize))
                continue
            }

            // Empty line → paragraph break
            if trimmed.isEmpty {
                if needsNewline { result.append(newline()) }
                needsNewline = false
                i += 1
                continue
            }

            if needsNewline { result.append(newline()) }
            needsNewline = true

            // Headers
            if trimmed.hasPrefix("### ") {
                result.append(headerLine(String(trimmed.dropFirst(4)), level: 3, fontSize: fontSize, textColor: textColor))
            } else if trimmed.hasPrefix("## ") {
                result.append(headerLine(String(trimmed.dropFirst(3)), level: 2, fontSize: fontSize, textColor: textColor))
            } else if trimmed.hasPrefix("# ") {
                result.append(headerLine(String(trimmed.dropFirst(2)), level: 1, fontSize: fontSize, textColor: textColor))
            }
            // Bullet list
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                let content = String(trimmed.dropFirst(2))
                let bullet = NSMutableAttributedString(string: "  •  ", attributes: baseAttrs(fontSize: fontSize, textColor: textColor))
                bullet.append(inlineFormatted(content, fontSize: fontSize, textColor: textColor))
                result.append(bullet)
            }
            // Numbered list
            else if let range = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let prefix = String(trimmed[range])
                let content = String(trimmed[range.upperBound...])
                let num = NSMutableAttributedString(string: "  \(prefix)", attributes: baseAttrs(fontSize: fontSize, textColor: textColor))
                num.append(inlineFormatted(content, fontSize: fontSize, textColor: textColor))
                result.append(num)
            }
            // Blockquote
            else if trimmed.hasPrefix("> ") {
                let content = String(trimmed.dropFirst(2))
                let para = NSMutableParagraphStyle()
                para.headIndent = 16
                para.firstLineHeadIndent = 16
                var attrs = baseAttrs(fontSize: fontSize, textColor: .secondaryLabelColor)
                attrs[.paragraphStyle] = para
                let quote = NSMutableAttributedString(string: "")
                quote.append(inlineFormatted(content, fontSize: fontSize, textColor: .secondaryLabelColor))
                quote.addAttributes(attrs, range: NSRange(location: 0, length: quote.length))
                result.append(quote)
            }
            // Regular paragraph
            else {
                result.append(inlineFormatted(line, fontSize: fontSize, textColor: textColor))
            }

            i += 1
        }
        return result
    }

    // MARK: - Block Elements

    private static func codeBlock(_ code: String, fontSize: CGFloat) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 1
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.black.withAlphaComponent(0.15),
            .paragraphStyle: para,
        ]
        return NSAttributedString(string: code, attributes: attrs)
    }

    private static func headerLine(_ text: String, level: Int, fontSize: CGFloat, textColor: NSColor) -> NSAttributedString {
        let size: CGFloat
        switch level {
        case 1: size = fontSize + 5
        case 2: size = fontSize + 3
        default: size = fontSize + 1
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: size),
            .foregroundColor: textColor,
        ]
        let header = NSMutableAttributedString(string: text, attributes: attrs)
        applyInlineSpans(header, fontSize: size, textColor: textColor)
        return header
    }

    // MARK: - Inline Formatting

    static func inlineFormatted(_ text: String, fontSize: CGFloat, textColor: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: baseAttrs(fontSize: fontSize, textColor: textColor))
        applyInlineSpans(result, fontSize: fontSize, textColor: textColor)
        return result
    }

    private static func applyInlineSpans(_ attrStr: NSMutableAttributedString, fontSize: CGFloat, textColor: NSColor) {
        // Inline code: `code`
        applyPattern(attrStr, pattern: #"`([^`]+)`"#) { range, capture in
            attrStr.replaceCharacters(in: range, with: capture)
            let newRange = NSRange(location: range.location, length: (capture as NSString).length)
            attrStr.addAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                .backgroundColor: NSColor.black.withAlphaComponent(0.12),
            ], range: newRange)
        }

        // Bold: **text**
        applyPattern(attrStr, pattern: #"\*\*(.+?)\*\*"#) { range, capture in
            attrStr.replaceCharacters(in: range, with: capture)
            let newRange = NSRange(location: range.location, length: (capture as NSString).length)
            attrStr.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: fontSize), range: newRange)
        }

        // Bold: __text__
        applyPattern(attrStr, pattern: #"__(.+?)__"#) { range, capture in
            attrStr.replaceCharacters(in: range, with: capture)
            let newRange = NSRange(location: range.location, length: (capture as NSString).length)
            attrStr.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: fontSize), range: newRange)
        }

        // Italic: *text* (but not ** which is bold)
        applyPattern(attrStr, pattern: #"(?<!\*)\*([^*]+)\*(?!\*)"#) { range, capture in
            attrStr.replaceCharacters(in: range, with: capture)
            let newRange = NSRange(location: range.location, length: (capture as NSString).length)
            let italicFont = NSFontManager.shared.convert(NSFont.systemFont(ofSize: fontSize), toHaveTrait: .italicFontMask)
            attrStr.addAttribute(.font, value: italicFont, range: newRange)
        }

        // Links: [text](url)
        applyPattern(attrStr, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { range, _ in
            let full = (attrStr.string as NSString).substring(with: range)
            guard let textRange = full.range(of: #"\[([^\]]+)\]"#, options: .regularExpression),
                  let urlRange = full.range(of: #"\(([^)]+)\)"#, options: .regularExpression) else { return }
            let linkText = String(full[textRange]).dropFirst().dropLast()
            let urlString = String(full[urlRange]).dropFirst().dropLast()
            attrStr.replaceCharacters(in: range, with: String(linkText))
            let newRange = NSRange(location: range.location, length: linkText.count)
            if let url = URL(string: String(urlString)) {
                attrStr.addAttributes([
                    .link: url,
                    .foregroundColor: NSColor.controlAccentColor,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], range: newRange)
            }
        }
    }

    /// Applies a regex pattern and calls the handler for each match (from last to first to preserve indices).
    private static func applyPattern(_ attrStr: NSMutableAttributedString,
                                     pattern: String,
                                     handler: (NSRange, String) -> Void) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let fullRange = NSRange(location: 0, length: attrStr.length)
        let matches = regex.matches(in: attrStr.string, range: fullRange)
        for match in matches.reversed() {
            let fullRange = match.range
            let capture = match.numberOfRanges > 1
                ? (attrStr.string as NSString).substring(with: match.range(at: 1))
                : (attrStr.string as NSString).substring(with: fullRange)
            handler(fullRange, capture)
        }
    }

    // MARK: - Helpers

    private static func baseAttrs(fontSize: CGFloat, textColor: NSColor) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: textColor,
        ]
    }

    private static func newline() -> NSAttributedString {
        NSAttributedString(string: "\n")
    }
}
