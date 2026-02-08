import Foundation
import os

private let logger = Logger(subsystem: "com.kadxy.FlowX", category: "Settings")

final class AppSettings {
    static let shared = AppSettings()

    private static let configDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let filePath = configDir.appendingPathComponent("settings.json")

    private var data: [String: Any]

    private init() {
        if let raw = try? Data(contentsOf: Self.filePath),
           let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            data = json
        } else {
            data = [:]
        }

        // Auto-refresh developer token in background
        Task { await refreshDeveloperToken() }
    }

    // MARK: - Token Config

    var developerToken: String {
        get { data["developerToken"] as? String ?? "" }
        set { data["developerToken"] = newValue; save() }
    }

    var userToken: String {
        get { data["userToken"] as? String ?? "" }
        set { data["userToken"] = newValue; save() }
    }

    var storefront: String {
        get { data["storefront"] as? String ?? "cn" }
        set { data["storefront"] = newValue; save() }
    }

    // MARK: - UI Config

    var tickerWidth: Double {
        get { data["tickerWidth"] as? Double ?? 180 }
        set { data["tickerWidth"] = newValue; save() }
    }

    var showLyrics: Bool {
        get { data["showLyrics"] as? Bool ?? true }
        set { data["showLyrics"] = newValue; save() }
    }

    // MARK: - Persistence

    private func save() {
        if let raw = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? raw.write(to: Self.filePath, options: .atomic)
        }
    }

    // MARK: - Developer Token Auto-Refresh

    /// General JWT regex
    /// both the header and payload start with eyJ (i.e., base64url(`{"`)), and each segment is at least 20 characters long.
    private static let jwtPattern = "eyJ[A-Za-z0-9_-]{20,}\\.eyJ[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{20,}"

    func refreshDeveloperToken() async {
        do {
            // 1. Fetch Apple Music home page
            let homeURL = URL(string: "https://music.apple.com/us/home")!
            let (homeData, _) = try await URLSession.shared.data(from: homeURL)
            guard let html = String(data: homeData, encoding: .utf8) else { return }

            // 2. Find the index JS bundle URL
            guard let scriptMatch = html.range(of: #"(?<=src=")[^"]*?/assets/index~[^"]+\.js"#, options: .regularExpression) else {
                logger.error("Could not find index JS bundle in HTML")
                return
            }
            let jsPath = String(html[scriptMatch]).replacingOccurrences(of: "\"", with: "")
            let jsURL = URL(string: "https://music.apple.com\(jsPath)")!

            // 3. Fetch the JS bundle
            let (jsData, _) = try await URLSession.shared.data(from: jsURL)
            guard let js = String(data: jsData, encoding: .utf8) else { return }

            // 4. 匹配所有 JWT，取最长的（developer token 是 JS 里最长的 JWT）
            let regex = try NSRegularExpression(pattern: Self.jwtPattern)
            let matches = regex.matches(in: js, range: NSRange(js.startIndex..., in: js))

            guard let best = matches.max(by: { $0.range.length < $1.range.length }),
                  let range = Range(best.range, in: js) else {
                logger.error("Could not find developer token in JS (\(matches.count) JWT candidates)")
                return
            }
            let newToken = String(js[range])

            if newToken != developerToken {
                developerToken = newToken
                logger.info("Developer token refreshed (\(newToken.prefix(32))...)")
            } else {
                logger.info("Developer token unchanged")
            }
        } catch {
            logger.error("Token refresh error: \(error.localizedDescription)")
        }
    }
}
