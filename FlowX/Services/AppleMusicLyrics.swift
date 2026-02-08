import Foundation

final class AppleMusicLyrics {
    private let developerToken: String
    private let userToken: String
    private let storefront: String
    private let session: URLSession

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

        // Load tokens from .env
        let env = Self.loadEnv()
        developerToken = env["DEVELOPER_TOKEN"] ?? ""
        userToken = env["USER_TOKEN"] ?? ""
        storefront = env["STOREFRONT"] ?? "cn"
    }

    private static func loadEnv() -> [String: String] {
        // Look for .env in the app bundle's parent (project root during dev)
        let candidates = [
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".env"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".env")
        ]
        for url in candidates {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                var dict: [String: String] = [:]
                for line in content.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                    if let eq = trimmed.firstIndex(of: "=") {
                        let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                        let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                        dict[key] = value
                    }
                }
                return dict
            }
        }
        return [:]
    }

    func fetchLyrics(trackName: String, artistName: String, albumName: String, duration: TimeInterval, persistentID: String) async -> [LyricLine]? {
        // 1. Disk cache: {persistentID}-{catalogSongId}.ttml
        if !persistentID.isEmpty, let cached = findCachedFile(persistentID: persistentID) {
            log("Disk cache hit: \(trackName) (\(persistentID) → \(cached.catalogId))")
            let lines = TTMLParser.parse(cached.ttml)
            return lines.isEmpty ? nil : lines
        }

        log("Fetching: \(trackName) - \(artistName)")

        // 2. Search: library first (precise), fallback to catalog
        var songId = await searchLibrary(name: trackName, artist: artistName, album: albumName, duration: duration)
        if songId == nil {
            log("  Library miss, falling back to catalog search")
            songId = await searchCatalog(name: trackName, artist: artistName, duration: duration)
        }
        guard let songId else {
            log("✗ Song not found")
            return nil
        }
        log("Found catalogSongId: \(songId)")

        // 3. Fetch TTML lyrics
        guard let ttml = await fetchSyllableLyrics(songId: songId) else {
            log("✗ No lyrics for songId \(songId)")
            return nil
        }

        // 4. Save TTML to disk
        if !persistentID.isEmpty {
            saveTTMLToDisk(ttml: ttml, persistentID: persistentID, catalogId: songId)
        }

        let lines = TTMLParser.parse(ttml)
        log("✓ Parsed \(lines.count) lines, first: '\(lines.first?.text ?? "")' @ \(String(format: "%.1f", lines.first?.time ?? 0))s")
        return lines.isEmpty ? nil : lines
    }

    // MARK: - Library Search (searches user's own library, returns catalog songId)

    private func searchLibrary(name: String, artist: String, album: String, duration: TimeInterval) async -> String? {
        var c = URLComponents(string: "https://amp-api.music.apple.com/v1/me/library/search")
        c?.queryItems = [
            URLQueryItem(name: "term", value: "\(name) \(artist)"),
            URLQueryItem(name: "types", value: "library-songs"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "include[library-songs]", value: "catalog"),
            URLQueryItem(name: "l", value: "zh-Hans-CN")
        ]
        guard let url = c?.url, let data = await apiRequest(url: url) else { return nil }

        do {
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let results = json?["results"] as? [String: Any]
            let songs = results?["library-songs"] as? [String: Any]
            let songData = songs?["data"] as? [[String: Any]] ?? []

            log("  Library search returned \(songData.count) songs")

            var bestId: String?
            var bestDiff = Double.infinity

            for song in songData {
                let attrs = song["attributes"] as? [String: Any] ?? [:]
                let durationMs = attrs["durationInMillis"] as? Double ?? 0
                let songDur = durationMs / 1000.0
                let diff = abs(songDur - duration)
                let songName = attrs["name"] as? String ?? ""
                let songArtist = attrs["artistName"] as? String ?? ""
                let songAlbum = attrs["albumName"] as? String ?? ""

                // Extract catalog songId from relationships
                let relationships = song["relationships"] as? [String: Any] ?? [:]
                let catalog = relationships["catalog"] as? [String: Any] ?? [:]
                let catalogData = catalog["data"] as? [[String: Any]] ?? []
                let catalogId = catalogData.first?["id"] as? String

                log("  '\(songName)' by '\(songArtist)' [\(songAlbum)], dur=\(String(format: "%.1f", songDur))s (Δ\(String(format: "%.1f", diff))s) → catalog: \(catalogId ?? "nil")")

                if let catalogId = catalogId, diff < bestDiff {
                    bestDiff = diff
                    bestId = catalogId
                }
            }

            return bestId
        } catch {
            log("  Library search parse error: \(error)")
            return nil
        }
    }

    // MARK: - Catalog Search (fallback, searches entire Apple Music catalog)

    private func searchCatalog(name: String, artist: String, duration: TimeInterval) async -> String? {
        var c = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/search")
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

            log("  Catalog search returned \(songData.count) songs")

            var bestId: String?
            var bestDiff = Double.infinity

            for song in songData {
                let id = song["id"] as? String ?? ""
                let attrs = song["attributes"] as? [String: Any] ?? [:]
                let durationMs = attrs["durationInMillis"] as? Double ?? 0
                let songDur = durationMs / 1000.0
                let diff = abs(songDur - duration)
                let songName = attrs["name"] as? String ?? ""
                let songArtist = attrs["artistName"] as? String ?? ""

                log("  [\(id)] '\(songName)' by '\(songArtist)', dur=\(String(format: "%.1f", songDur))s (Δ\(String(format: "%.1f", diff))s)")

                if diff < bestDiff {
                    bestDiff = diff
                    bestId = id
                }
            }

            if bestDiff < 5, let id = bestId { return id }
            return songData.first?["id"] as? String
        } catch {
            log("  Catalog search parse error: \(error)")
            return nil
        }
    }

    // MARK: - Fetch syllable lyrics

    private func fetchSyllableLyrics(songId: String) async -> String? {
        var c = URLComponents(string: "https://amp-api.music.apple.com/v1/catalog/\(storefront)/songs/\(songId)/syllable-lyrics")
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

            log("  No lyrics in syllable-lyrics response")
            return nil
        } catch {
            log("  Parse error: \(error)")
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
        log("  Cached TTML → \(persistentID)-\(catalogId).ttml")
    }

    // MARK: - API Request

    private func apiRequest(url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(developerToken)", forHTTPHeaderField: "authorization")
        req.setValue(userToken, forHTTPHeaderField: "media-user-token")
        req.setValue("https://music.apple.com", forHTTPHeaderField: "origin")
        req.setValue("https://music.apple.com/", forHTTPHeaderField: "referer")

        do {
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if !(200...299).contains(status) {
                log("  API \(url.path) → HTTP \(status)")
                return nil
            }
            return data
        } catch {
            log("  API error: \(error.localizedDescription)")
            return nil
        }
    }

    private func log(_ msg: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        print("[\(df.string(from: Date()))] [AM] \(msg)")
    }
}
