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

        applyLanguage()

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

    var menuBarLyricsWidth: Double {
        get { data["menuBarLyricsWidth"] as? Double ?? 180 }
        set { data["menuBarLyricsWidth"] = newValue; save() }
    }

    var showMenuBarLyrics: Bool {
        get { data["showMenuBarLyrics"] as? Bool ?? true }
        set { data["showMenuBarLyrics"] = newValue; save() }
    }

    var menuBarKaraoke: Bool {
        get { data["menuBarKaraoke"] as? Bool ?? true }
        set { data["menuBarKaraoke"] = newValue; save() }
    }

    var menuBarEdgeFadeWidth: Double {
        get { min(40, max(0, data["menuBarEdgeFadeWidth"] as? Double ?? 24)) }
        set { data["menuBarEdgeFadeWidth"] = min(40, max(0, newValue)); save() }
    }

    var language: String {
        get { data["language"] as? String ?? "system" }
        set {
            data["language"] = newValue
            save()
            applyLanguage()
        }
    }

    /// Set AppleLanguages override based on current language setting.
    /// Must be called before any localized strings are loaded.
    func applyLanguage() {
        if language == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        }
    }

    // MARK: - Persistence

    private func save() {
        if let raw = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]) {
            try? raw.write(to: Self.filePath, options: .atomic)
        }
    }

    // MARK: - Developer Token Auto-Refresh

    /// General JWT regex: header and payload start with `eyJ` (base64url of `{"`), each segment >= 20 chars.
    private static let jwtPattern = "eyJ[A-Za-z0-9_-]{20,}\\.eyJ[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{20,}"

    func refreshDeveloperToken() async {
        do {
            // Fetch Apple Music home page
            let homeURL = URL(string: "https://music.apple.com/us/home")!
            let (homeData, _) = try await URLSession.shared.data(from: homeURL)
            guard let html = String(data: homeData, encoding: .utf8) else { return }

            // Find the index JS bundle URL
            guard let scriptMatch = html.range(of: #"(?<=src=")[^"]*?/assets/index~[^"]+\.js"#, options: .regularExpression) else {
                logger.error("Could not find index JS bundle in HTML")
                return
            }
            let jsPath = String(html[scriptMatch]).replacingOccurrences(of: "\"", with: "")
            let jsURL = URL(string: "https://music.apple.com\(jsPath)")!

            // Fetch the JS bundle
            let (jsData, _) = try await URLSession.shared.data(from: jsURL)
            guard let js = String(data: jsData, encoding: .utf8) else { return }

            // Pick the longest JWT in the bundle (the developer token)
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
