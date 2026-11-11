import Foundation
import os

private let logger = Logger(subsystem: "com.kadxy.FlowX", category: "TokenValidator")

/// Account details Apple returns alongside a successful token check.
struct AccountInfo: Equatable {
    /// Storefront identifier, e.g. `us`.
    var regionCode: String
    /// Localized storefront name, e.g. `United States`.
    var regionName: String
    /// Storefront's default content language tag, e.g. `en-US`.
    var languageTag: String
}

/// Outcome of checking the user (media-user-token) against the Apple Music API.
enum UserTokenStatus: Equatable {
    case valid(AccountInfo)
    /// The developer token was rejected (HTTP 401), so the user token could not be judged.
    case developerTokenUnavailable
    /// Apple rejected the token — expired, revoked, or malformed (HTTP 403).
    case invalid
    /// Network failure or an unexpected status code.
    case failed(String)
}

/// Validates a media-user-token via `/v1/me/storefront`.
///
/// That endpoint is the cheapest call that both proves the token works and reports
/// the account's storefront — so a single request answers "is this valid?" and
/// "which region is this account in?". Apple's failure modes are cleanly split:
/// a bad developer token yields 401, a bad user token yields 403, success is 200.
struct TokenValidator {
    /// Kept in sync with `LyricsService.userAgent`; the API expects a browser-like client.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    static func validate(userToken: String, developerToken: String) async -> UserTokenStatus {
        let token = userToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .invalid }
        guard !developerToken.isEmpty else { return .developerTokenUnavailable }

        guard let url = URL(string: "https://amp-api.music.apple.com/v1/me/storefront") else {
            return .failed("Invalid request URL")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Bearer \(developerToken)", forHTTPHeaderField: "authorization")
        request.setValue(token, forHTTPHeaderField: "media-user-token")
        request.setValue("https://music.apple.com", forHTTPHeaderField: "origin")
        request.setValue("https://music.apple.com/", forHTTPHeaderField: "referer")
        request.setValue(userAgent, forHTTPHeaderField: "user-agent")
        request.setValue("*/*", forHTTPHeaderField: "accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            switch status {
            case 200:
                return .valid(accountInfo(from: data))
            case 401:
                return .developerTokenUnavailable
            case 403:
                logger.info("User token rejected: \(errorDetail(from: data) ?? "no detail")")
                return .invalid
            case 429:
                return .failed("Apple rate-limited the request — try again shortly")
            default:
                return .failed("Unexpected response (HTTP \(status))")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func accountInfo(from data: Data) -> AccountInfo {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first,
              let code = first["id"] as? String else {
            return AccountInfo(regionCode: "", regionName: "", languageTag: "")
        }
        let attributes = first["attributes"] as? [String: Any]
        return AccountInfo(
            regionCode: code,
            regionName: attributes?["name"] as? String ?? code.uppercased(),
            languageTag: attributes?["defaultLanguageTag"] as? String ?? ""
        )
    }

    private static func errorDetail(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["errors"] as? [[String: Any]])?.first else { return nil }
        return first["detail"] as? String
    }
}
