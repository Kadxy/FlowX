import Foundation
import os

private let logger = Logger(subsystem: "com.kadxy.FlowX", category: "Lyrics")

final class LyricsService {
    private let session: URLSession
    private var settings: AppSettings { AppSettings.shared }

    static let cacheDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowX/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        session = URLSession(configuration: config)
    }

    func fetchLyrics(trackName: String, artistName: String, catalogId: String) async -> [LyricLine]? {
        guard !catalogId.isEmpty else {
            logger.warning("No catalog ID for: \(trackName)")
            return nil
        }

        // Check disk cache
        if let ttml = loadCachedTTML(catalogId: catalogId) {
            logger.debug("Disk cache hit: \(trackName) (\(catalogId))")
            let lines = TTMLParser.parse(ttml)
            return lines.isEmpty ? nil : lines
        }

        logger.debug("Fetching TTML lyrics: \(trackName) - \(artistName) (\(catalogId))")

        // Fetch TTML lyrics from API
        guard let ttml = await fetchSyllableLyrics(songId: catalogId) else {
            logger.info("No lyrics for songId \(catalogId)")
            return nil
        }

        // Save to disk cache
        saveTTMLToDisk(ttml: ttml, catalogId: catalogId)

        let lines = TTMLParser.parse(ttml)
        logger.debug("Parsed \(lines.count) lines, first: '\(lines.first?.text ?? "")' @ \(String(format: "%.1f", lines.first?.time ?? 0))s")
        return lines.isEmpty ? nil : lines
    }

    // MARK: - Syllable Lyrics

    private func fetchSyllableLyrics(songId: String) async -> String? {
        let encodedStorefront = settings.storefront.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? settings.storefront
        let encodedSongId = songId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? songId
        var c = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(encodedStorefront)/songs/\(encodedSongId)/syllable-lyrics")
        c?.queryItems = [
            URLQueryItem(name: "l[lyrics]", value: "zh-hans-cn"),
            URLQueryItem(name: "l[script]", value: "zh-Hans"),
            URLQueryItem(name: "extend", value: "ttmlLocalizations")
        ]
        guard let url = c?.url, let data = await apiRequest(url: url) else { return nil }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let dataArr = json?["data"] as? [[String: Any]] ?? []

            if let first = dataArr.first,
               let attrs = first["attributes"] as? [String: Any] {
                if let ttml = attrs["ttmlLocalizations"] as? String {
                    return ttml
                }
                if let ttml = attrs["ttml"] as? String {
                    return ttml
                }
            }

            logger.info("  No lyrics in syllable-lyrics response")
            return nil
        } catch {
            logger.info("  Parse error: \(error)")
            return nil
        }
    }

    // MARK: - Disk Cache

    private func cacheFileURL(for catalogId: String) -> URL {
        Self.cacheDir.appendingPathComponent("\(catalogId).ttml")
    }

    func cachedFileURL(catalogId: String) -> URL? {
        let file = cacheFileURL(for: catalogId)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    private func loadCachedTTML(catalogId: String) -> String? {
        try? String(contentsOf: cacheFileURL(for: catalogId), encoding: .utf8)
    }

    private func saveTTMLToDisk(ttml: String, catalogId: String) {
        let file = cacheFileURL(for: catalogId)
        try? ttml.write(to: file, atomically: true, encoding: .utf8)
        logger.debug("Cached TTML → \(catalogId).ttml")
    }

    // MARK: - API Request

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private func apiRequest(url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(settings.developerToken)", forHTTPHeaderField: "authorization")
        req.setValue(settings.userToken, forHTTPHeaderField: "media-user-token")
        req.setValue("https://music.apple.com", forHTTPHeaderField: "origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "user-agent")
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")

        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if !(200...299).contains(status) {
                logger.warning("API \(url.path) → HTTP \(status)")
                return nil
            }
            return data
        } catch {
            logger.error("API error: \(error.localizedDescription)")
            return nil
        }
    }
}
