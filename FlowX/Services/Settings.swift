import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.kadxy.FlowX", category: "Settings")

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private static let configDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FlowX", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let filePath = configDir.appendingPathComponent("settings.json")

    /// Derive the default storefront from the user's system region, validated against known iTunes country codes.
    private static let defaultStorefront: String = {
        guard let region = Locale.current.region?.identifier.lowercased() else { return "us" }
        guard let url = Bundle.main.url(forResource: "itunes_country_codes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return region }
        let knownCodes = Set(dict.keys.map { $0.lowercased() })
        return knownCodes.contains(region) ? region : "us"
    }()

    // MARK: - Token Config

    @Published var developerToken: String = ""
    @Published var userToken: String = ""
    @Published var storefront: String = AppSettings.defaultStorefront

    // MARK: - UI Config

    @Published var menuBarLyricsWidth: Double = 180
    @Published var showMenuBarLyrics: Bool = true
    @Published var menuBarKaraoke: Bool = true
    @Published var menuBarEdgeFadeWidth: Double = 36
    @Published var language: String = "system"

    private var cancellables = Set<AnyCancellable>()

    private init() {
        load()
        applyLanguage()
        setupObservers()
        // Storefront detection needs the developer token, so run it afterwards.
        Task {
            await refreshDeveloperToken()
            await refreshStorefrontFromToken()
        }
    }

    // MARK: - Load / Save

    private func load() {
        guard let raw = try? Data(contentsOf: Self.filePath),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any]
        else { return }

        developerToken = json["developerToken"] as? String ?? ""
        userToken = json["userToken"] as? String ?? ""
        storefront = json["storefront"] as? String ?? AppSettings.defaultStorefront
        menuBarLyricsWidth = json["menuBarLyricsWidth"] as? Double ?? 180
        showMenuBarLyrics = json["showMenuBarLyrics"] as? Bool ?? true
        menuBarKaraoke = json["menuBarKaraoke"] as? Bool ?? true
        menuBarEdgeFadeWidth = min(60, max(0, json["menuBarEdgeFadeWidth"] as? Double ?? 36))
        language = json["language"] as? String ?? "system"
    }

    private func setupObservers() {
        // Auto-save on any property change (debounced to coalesce rapid updates)
        objectWillChange
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
            .store(in: &cancellables)

        // Apply language override when changed
        $language
            .dropFirst()
            .sink { [weak self] _ in self?.applyLanguage() }
            .store(in: &cancellables)
    }

    private func save() {
        var dict: [String: Any] = [
            "developerToken": developerToken,
            "userToken": userToken,
            "storefront": storefront,
            "menuBarLyricsWidth": menuBarLyricsWidth,
            "showMenuBarLyrics": showMenuBarLyrics,
            "menuBarKaraoke": menuBarKaraoke,
            "menuBarEdgeFadeWidth": menuBarEdgeFadeWidth,
            "language": language
        ]
        if let raw = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) {
            try? raw.write(to: Self.filePath, options: .atomic)
        }
    }

    /// Set AppleLanguages override based on current language setting.
    func applyLanguage() {
        if language == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([language], forKey: "AppleLanguages")
        }
    }

    // MARK: - Developer Token Auto-Refresh

    /// General JWT regex: header and payload start with `eyJ` (base64url of `{"`), each segment >= 20 chars.
    private static let jwtPattern = "eyJ[A-Za-z0-9_-]{20,}\\.eyJ[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{20,}"

    /// The bundle carries several JWTs side by side. The one MusicKit actually uses as
    /// `developerToken` is the AMPWebPlay token: its header declares `kid == "WebPlayKid"`.
    /// Other bundles (e.g. the 298-char MapKit/search token) look longer but return 401.
    /// Picking by length therefore selects the wrong token, so match on the `kid` instead.
    private static func isDeveloperToken(_ jwt: String) -> Bool {
        let segments = jwt.split(separator: ".")
        guard let headerSegment = segments.first else { return false }
        var base64 = String(headerSegment)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return (header["kid"] as? String) == "WebPlayKid"
    }

    func refreshDeveloperToken() async {
        do {
            let homeURL = URL(string: "https://music.apple.com/us/home")!
            let (homeData, _) = try await URLSession.shared.data(from: homeURL)
            guard let html = String(data: homeData, encoding: .utf8) else { return }

            guard let scriptMatch = html.range(of: #"(?<=src=")[^"]*?/assets/index~[^"]+\.js"#, options: .regularExpression) else {
                logger.error("Could not find index JS bundle in HTML")
                return
            }
            let jsPath = String(html[scriptMatch]).replacingOccurrences(of: "\"", with: "")
            let jsURL = URL(string: "https://music.apple.com\(jsPath)")!

            let (jsData, _) = try await URLSession.shared.data(from: jsURL)
            guard let js = String(data: jsData, encoding: .utf8) else { return }

            let regex = try NSRegularExpression(pattern: Self.jwtPattern)
            let matches = regex.matches(in: js, range: NSRange(js.startIndex..., in: js))
            let candidates = matches.compactMap { Range($0.range, in: js).map { String(js[$0]) } }

            guard let newToken = candidates.first(where: Self.isDeveloperToken) else {
                logger.error("Could not find developer token in JS (\(candidates.count) JWT candidates, none with kid=WebPlayKid)")
                return
            }

            await MainActor.run {
                if newToken != self.developerToken {
                    self.developerToken = newToken
                    logger.info("Developer token refreshed (\(newToken.prefix(32))...)")
                } else {
                    logger.info("Developer token unchanged")
                }
            }
        } catch {
            logger.error("Token refresh error: \(error.localizedDescription)")
        }
    }

    // MARK: - Storefront Auto-Detection

    /// Resolve the account's storefront straight from the user token, so it never
    /// has to be picked by hand. Falls back silently to the current value.
    func refreshStorefrontFromToken() async {
        guard !userToken.isEmpty, !developerToken.isEmpty else { return }
        let status = await TokenValidator.validate(userToken: userToken, developerToken: developerToken)
        guard case .valid(let info) = status, !info.regionCode.isEmpty else { return }
        await MainActor.run {
            if self.storefront != info.regionCode {
                self.storefront = info.regionCode
                logger.info("Storefront resolved from token: \(info.regionCode)")
            }
        }
    }
}
