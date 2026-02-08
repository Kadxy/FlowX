import Foundation

struct TTMLParser {
    static func parse(_ ttml: String) -> [LyricLine] {
        // Try simplified Chinese translation first, fall back to main body
        if let lines = parseTranslation(ttml, lang: "zh-Hans"), !lines.isEmpty {
            return lines
        }
        return parseBody(ttml)
    }

    // MARK: - Parse zh-Hans translation section
    // Format: <text for="L1"><span begin="30.208" end="30.670">这是</span><span ...>一首</span>...</text>

    private static func parseTranslation(_ ttml: String, lang: String) -> [LyricLine]? {
        // Find the translation block for the target language
        let translationPattern = #"<translation[^>]*xml:lang="\#(lang)"[^>]*>(.*?)</translation>"#
        guard let translationRegex = try? NSRegularExpression(pattern: translationPattern, options: [.dotMatchesLineSeparators]),
              let translationMatch = translationRegex.firstMatch(in: ttml, range: NSRange(ttml.startIndex..., in: ttml)),
              let translationRange = Range(translationMatch.range(at: 1), in: ttml) else {
            return nil
        }
        let translationBlock = String(ttml[translationRange])

        // Extract each <text for="Lx">...</text>
        let textPattern = #"<text\s+for="[^"]*">(.*?)</text>"#
        guard let textRegex = try? NSRegularExpression(pattern: textPattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let textMatches = textRegex.matches(in: translationBlock, range: NSRange(translationBlock.startIndex..., in: translationBlock))

        var result: [LyricLine] = []

        for match in textMatches {
            guard let contentRange = Range(match.range(at: 1), in: translationBlock) else { continue }
            let content = String(translationBlock[contentRange])

            // Extract spans: <span begin="30.208" end="30.670" ...>text</span>
            let spanPattern = #"<span\s+begin="([^"]+)"[^>]*>([^<]*)</span>"#
            guard let spanRegex = try? NSRegularExpression(pattern: spanPattern, options: []) else { continue }
            let spanMatches = spanRegex.matches(in: content, range: NSRange(content.startIndex..., in: content))

            guard let firstSpan = spanMatches.first,
                  let beginRange = Range(firstSpan.range(at: 1), in: content) else { continue }

            let beginStr = String(content[beginRange])
            let time = parseTime(beginStr)

            // Concatenate all span texts
            var text = ""
            for span in spanMatches {
                if let textRange = Range(span.range(at: 2), in: content) {
                    text += String(content[textRange])
                }
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            result.append(LyricLine(id: result.count, time: time, text: text))
        }

        return result.isEmpty ? nil : result.sorted { $0.time < $1.time }
    }

    // MARK: - Parse main <body> <p> elements (fallback)
    // Format: <p begin="30.208" end="36.531" ...><span ...>text</span>...</p>

    private static func parseBody(_ ttml: String) -> [LyricLine] {
        let pattern = #"<p\s+begin="([^"]+)"[^>]*>(.*?)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let matches = regex.matches(in: ttml, range: NSRange(ttml.startIndex..., in: ttml))

        var result: [LyricLine] = []
        for match in matches {
            guard let beginRange = Range(match.range(at: 1), in: ttml),
                  let contentRange = Range(match.range(at: 2), in: ttml) else { continue }

            let beginStr = String(ttml[beginRange])
            let rawContent = String(ttml[contentRange])
            let text = stripTags(rawContent).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            result.append(LyricLine(id: result.count, time: parseTime(beginStr), text: text))
        }

        return result.sorted { $0.time < $1.time }
    }

    // MARK: - Time parsing: "30.208" or "1:13.808" or "00:01:13.808"

    static func parseTime(_ str: String) -> TimeInterval {
        let parts = str.components(separatedBy: ":")
        switch parts.count {
        case 3:
            return (Double(parts[0]) ?? 0) * 3600 + (Double(parts[1]) ?? 0) * 60 + (Double(parts[2]) ?? 0)
        case 2:
            return (Double(parts[0]) ?? 0) * 60 + (Double(parts[1]) ?? 0)
        default:
            return Double(str) ?? 0
        }
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }
}
