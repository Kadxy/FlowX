import Foundation

struct TTMLParser {
    static func parse(_ ttml: String) -> [LyricLine] {
        let isWordTiming = ttml.contains("itunes:timing=\"Word\"")

        // Try simplified Chinese translation first, fall back to main body
        if let lines = parseTranslation(ttml, lang: "zh-Hans", wordTiming: isWordTiming), !lines.isEmpty {
            return lines
        }
        let bodyLines = parseBody(ttml, wordTiming: isWordTiming)
        if !bodyLines.isEmpty { return bodyLines }

        // Fallback: timing="None" — plain lyrics without timestamps
        return parsePlainBody(ttml)
    }

    // MARK: - Translation Section

    private static func parseTranslation(_ ttml: String, lang: String, wordTiming: Bool) -> [LyricLine]? {
        let translationPattern = #"<translation[^>]*xml:lang="\#(lang)"[^>]*>(.*?)</translation>"#
        guard let translationRegex = try? NSRegularExpression(pattern: translationPattern, options: [.dotMatchesLineSeparators]),
              let translationMatch = translationRegex.firstMatch(in: ttml, range: NSRange(ttml.startIndex..., in: ttml)),
              let translationRange = Range(translationMatch.range(at: 1), in: ttml) else {
            return nil
        }
        let translationBlock = String(ttml[translationRange])

        let textPattern = #"<text\s+for="[^"]*">(.*?)</text>"#
        guard let textRegex = try? NSRegularExpression(pattern: textPattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let textMatches = textRegex.matches(in: translationBlock, range: NSRange(translationBlock.startIndex..., in: translationBlock))

        var result: [LyricLine] = []

        for match in textMatches {
            guard let contentRange = Range(match.range(at: 1), in: translationBlock) else { continue }
            let content = String(translationBlock[contentRange])

            let spans = extractSpans(from: content)
            guard !spans.isEmpty else { continue }

            let lineTime = spans.first!.begin
            let lineEnd = spans.last!.end
            // Strip tags but keep x-bg content (background vocals in parentheses)
            let lineText = stripTags(content).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineText.isEmpty else { continue }

            result.append(LyricLine(
                id: result.count,
                time: lineTime,
                endTime: lineEnd,
                text: lineText,
                words: wordTiming ? spans : []
            ))
        }

        return result.isEmpty ? nil : result.sorted { $0.time < $1.time }
    }

    // MARK: - Body Parsing

    private static func parseBody(_ ttml: String, wordTiming: Bool) -> [LyricLine] {
        let pattern = #"<p\s+begin="([^"]+)"\s+end="([^"]+)"[^>]*>(.*?)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let matches = regex.matches(in: ttml, range: NSRange(ttml.startIndex..., in: ttml))

        var result: [LyricLine] = []
        for match in matches {
            guard let beginRange = Range(match.range(at: 1), in: ttml),
                  let endRange = Range(match.range(at: 2), in: ttml),
                  let contentRange = Range(match.range(at: 3), in: ttml) else { continue }

            let beginStr = String(ttml[beginRange])
            let endStr = String(ttml[endRange])
            let rawContent = String(ttml[contentRange])

            let spans = wordTiming ? extractSpans(from: rawContent) : []
            // Strip tags but keep x-bg content (background vocals in parentheses)
            let text = stripTags(rawContent).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            result.append(LyricLine(
                id: result.count,
                time: parseTime(beginStr),
                endTime: parseTime(endStr),
                text: text,
                words: spans
            ))
        }

        return result.sorted { $0.time < $1.time }
    }

    // MARK: - Span Extraction

    private static func extractSpans(from content: String) -> [LyricWord] {
        // Strip x-bg (background vocal) blocks before extracting spans
        let stripped = content.replacingOccurrences(
            of: #"<span\s+ttm:role="x-bg"[^>]*>.*?</span>"#,
            with: "",
            options: .regularExpression
        )

        // Capture span text + any trailing text before the next tag (e.g., spaces)
        let spanPattern = #"<span\s+begin="([^"]+)"\s+end="([^"]+)"[^>]*>([^<]*)</span>([^<]*)"#
        guard let regex = try? NSRegularExpression(pattern: spanPattern, options: []) else { return [] }
        let matches = regex.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped))

        var result: [LyricWord] = []
        for match in matches {
            guard let beginRange = Range(match.range(at: 1), in: stripped),
                  let endRange = Range(match.range(at: 2), in: stripped),
                  let textRange = Range(match.range(at: 3), in: stripped) else { continue }

            var text = String(stripped[textRange])
            // Append trailing inter-span text (spaces)
            if let trailingRange = Range(match.range(at: 4), in: stripped) {
                text += String(stripped[trailingRange])
            }
            guard !text.isEmpty else { continue }

            result.append(LyricWord(
                text: text,
                begin: parseTime(String(stripped[beginRange])),
                end: parseTime(String(stripped[endRange]))
            ))
        }

        return result
    }

    // MARK: - Plain Lyrics

    private static func parsePlainBody(_ ttml: String) -> [LyricLine] {
        let pattern = #"<p>([^<]+)</p>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let matches = regex.matches(in: ttml, range: NSRange(ttml.startIndex..., in: ttml))

        var result: [LyricLine] = []
        for match in matches {
            guard let textRange = Range(match.range(at: 1), in: ttml) else { continue }
            let text = String(ttml[textRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            result.append(LyricLine(
                id: result.count,
                time: 0,
                endTime: 0,
                text: text,
                words: []
            ))
        }

        return result
    }

    // MARK: - Time Parsing

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
