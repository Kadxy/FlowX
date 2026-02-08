import Foundation
import os

private let logger = Logger(subsystem: "com.kadxy.FlowX", category: "Lyrics")

final class LyricsService {
    private let session: URLSession
    private var settings: AppSettings { AppSettings.shared }

    private static let cacheDir: URL = {
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

    func fetchLyrics(trackName: String, artistName: String, duration: TimeInterval, persistentID: String) async -> [LyricLine]? {
        // 1. Disk cache: {persistentID}-{catalogSongId}.ttml
        if !persistentID.isEmpty, let cached = findCachedFile(persistentID: persistentID) {
            logger.info("Disk cache hit: \(trackName) (\(persistentID) → \(cached.catalogId))")
            let lines = TTMLParser.parse(cached.ttml)
            return lines.isEmpty ? nil : lines
        }

        logger.info("Fetching: \(trackName) - \(artistName)")

        // 2. Catalog search
        guard let songId = await searchCatalog(name: trackName, artist: artistName, duration: duration) else {
            logger.info("✗ Song not found")
            return nil
        }
        logger.info("Found catalogSongId: \(songId)")

        // 3. Fetch TTML lyrics
        guard let ttml = await fetchSyllableLyrics(songId: songId) else {
            logger.info("✗ No lyrics for songId \(songId)")
            return nil
        }

        // 4. Save TTML to disk
        if !persistentID.isEmpty {
            saveTTMLToDisk(ttml: ttml, persistentID: persistentID, catalogId: songId)
        }

        let lines = TTMLParser.parse(ttml)
        logger.info("✓ Parsed \(lines.count) lines, first: '\(lines.first?.text ?? "")' @ \(String(format: "%.1f", lines.first?.time ?? 0))s")
        return lines.isEmpty ? nil : lines
    }

    // MARK: - Catalog Search

    private func searchCatalog(name: String, artist: String, duration: TimeInterval) async -> String? {
        var c = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(settings.storefront)/search")
        c?.queryItems = [
            URLQueryItem(name: "term", value: "\(name) \(artist)"),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "l", value: "zh-Hans-CN")
        ]
        guard let url = c?.url, let data = await apiRequest(url: url) else { return nil }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = json?["results"] as? [String: Any]
            let songs = results?["songs"] as? [String: Any]
            let songData = songs?["data"] as? [[String: Any]] ?? []

            logger.info("  Catalog search returned \(songData.count) songs")

            var bestId: String?
            var bestDiff = Double.infinity
            var bestExact = false

            for song in songData {
                let id = song["id"] as? String ?? ""
                let attrs = song["attributes"] as? [String: Any] ?? [:]
                let durationMs = attrs["durationInMillis"] as? Double ?? 0
                let songDur = durationMs / 1000.0
                let diff = abs(songDur - duration)
                let songName = attrs["name"] as? String ?? ""
                let songArtist = attrs["artistName"] as? String ?? ""
                let isExactTitle = songName == name

                logger.info("  [\(id)] '\(songName)' by '\(songArtist)', dur=\(String(format: "%.1f", songDur))s (Δ\(String(format: "%.1f", diff))s)\(isExactTitle ? " ✓exact" : "")")

                // 优先标题精确匹配，其次 duration 最接近
                let dominated: Bool
                if isExactTitle != bestExact {
                    dominated = isExactTitle  // 精确标题优先
                } else {
                    dominated = diff < bestDiff
                }
                if dominated {
                    bestDiff = diff
                    bestId = id
                    bestExact = isExactTitle
                }
            }

            if bestDiff < 5, let id = bestId { return id }
            return songData.first?["id"] as? String
        } catch {
            logger.info("  Catalog search parse error: \(error)")
            return nil
        }
    }

    // MARK: - Fetch syllable lyrics

    private func fetchSyllableLyrics(songId: String) async -> String? {
        var c = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(settings.storefront)/songs/\(songId)/syllable-lyrics")
        c?.queryItems = [
            URLQueryItem(name: "l[lyrics]", value: "zh-hans-cn"),
            URLQueryItem(name: "l[script]", value: "zh-Hans"),
            URLQueryItem(name: "extend", value: "ttmlLocalizations")
        ]
        guard let url = c?.url, let data = await apiRequest(url: url, needsUserToken: true) else { return nil }

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

    // MARK: - Disk Cache (filename: {persistentID}-{catalogSongId}.ttml)

    private func findCachedFile(persistentID: String) -> (ttml: String, catalogId: String)? {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: Self.cacheDir.path) else { return nil }
        guard let match = files.first(where: { $0.hasPrefix("\(persistentID)-") && $0.hasSuffix(".ttml") }) else { return nil }
        let catalogId = String(match.dropFirst(persistentID.count + 1).dropLast(5)) // remove "{pid}-" and ".ttml"
        let file = Self.cacheDir.appendingPathComponent(match)
        guard let ttml = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return (ttml, catalogId)
    }

    private func saveTTMLToDisk(ttml: String, persistentID: String, catalogId: String) {
        let file = Self.cacheDir.appendingPathComponent("\(persistentID)-\(catalogId).ttml")
        try? ttml.write(to: file, atomically: true, encoding: .utf8)
        logger.info("  Cached TTML → \(persistentID)-\(catalogId).ttml")
    }

    // MARK: - API Request

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private func apiRequest(url: URL, needsUserToken: Bool = false) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(settings.developerToken)", forHTTPHeaderField: "authorization")
        if needsUserToken {
            req.setValue(settings.userToken, forHTTPHeaderField: "media-user-token")
        }
        req.setValue("https://music.apple.com", forHTTPHeaderField: "origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "user-agent")
        req.setValue("*/*", forHTTPHeaderField: "accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")

        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if !(200...299).contains(status) {
                logger.info("  API \(url.path) → HTTP \(status)")
                return nil
            }
            return data
        } catch {
            logger.info("  API error: \(error.localizedDescription)")
            return nil
        }
    }
}
