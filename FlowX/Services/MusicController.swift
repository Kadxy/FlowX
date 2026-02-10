import Foundation
import ScriptingBridge
import Combine
import AppKit

final class MusicController: ObservableObject {
    static let shared = MusicController()

    @Published private(set) var playerState: PlayerState = .stopped
    @Published private(set) var currentTrack: TrackInfo = .empty
    @Published private(set) var isMusicRunning: Bool = false
    @Published private(set) var currentLyricLine: String = ""
    private(set) var currentLine: LyricLine?
    private(set) var currentLineIndex: Int = -1
    @Published private(set) var hasLyrics: Bool = false

    private(set) var playerPosition: TimeInterval = 0
    private(set) var lyrics: [LyricLine] = []

    private let musicApp: MusicApplication
    private let amLyrics = LyricsService()
    private var lastFetchedTrackIdentity = ""
    private var lastActiveIndex: Int = -1
    private var lastWasInterlude: Bool = false
    private var currentCatalogId: String = ""

    /// Called on the main thread after each position poll.
    var onPositionUpdated: (() -> Void)?

    private var pollTimer: Timer?

    private init() {
        let app: AnyObject = SBApplication(bundleIdentifier: "com.apple.Music")!
        musicApp = unsafeBitCast(app, to: MusicApplication.self)

        // Instant state/track changes via distributed notification
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onPlayerInfoChanged(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )

        // Detect Music.app quit
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(onAppTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Lightweight position poll for lyric sync (only does work when playing)
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            self?.pollPosition()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        refreshState()
    }

    // MARK: - Notification Handler

    @objc private func onPlayerInfoChanged(_ notification: Notification) {
        let info = notification.userInfo

        if let stateStr = info?["Player State"] as? String {
            let newState: PlayerState
            switch stateStr {
            case "Playing": newState = .playing
            case "Paused":  newState = .paused
            case "Stopped": newState = .stopped
            default:        newState = .unknown
            }
            if newState != playerState {
                // Sync position immediately on resume so animation rebuilds with accurate elapsed time
                if newState == .playing {
                    playerPosition = musicApp.playerPosition
                    updateCurrentLyric()
                }
                playerState = newState
            }
            isMusicRunning = true
        }

        // Track info from notification (avoids ScriptingBridge IPC)
        let name = info?["Name"] as? String ?? ""
        let artist = info?["Artist"] as? String ?? ""
        let album = info?["Album"] as? String ?? ""
        let totalTime = info?["Total Time"] as? Double ?? 0
        let duration = totalTime / 1000.0

        let persistentID: String
        if let pid = info?["PersistentID"] as? Int {
            persistentID = String(format: "%lX", pid)
        } else {
            persistentID = currentTrack.persistentID
        }

        if !name.isEmpty {
            let newTrack = TrackInfo(
                title: name,
                artist: artist,
                album: album,
                duration: duration,
                persistentID: persistentID,
                isFavorited: false
            )
            if newTrack != currentTrack {
                currentTrack = newTrack
                onTrackChanged()
            }
        }
    }

    // MARK: - Music.app Quit Detection

    @objc private func onAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.Music" else { return }

        isMusicRunning = false
        playerState = .stopped
        currentTrack = .empty
        playerPosition = 0
        currentLyricLine = ""
        currentLine = nil
        currentLineIndex = -1
        lastActiveIndex = -1
        lastWasInterlude = false
        currentCatalogId = ""
    }

    // MARK: - Position Polling

    private func pollPosition() {
        guard isMusicRunning,
              AppSettings.shared.showMenuBarLyrics else { return }

        playerPosition = musicApp.playerPosition
        updateCurrentLyric()
        onPositionUpdated?()
    }

    // MARK: - State Refresh

    private func refreshState() {
        guard musicApp.isRunning else { return }
        isMusicRunning = true

        let rawState = musicApp.playerState
        playerState = mapPlayerState(rawState)
        playerPosition = musicApp.playerPosition

        if let track = musicApp.currentTrack,
           let name = track.name, !name.isEmpty {
            currentTrack = TrackInfo(
                title: name,
                artist: track.artist ?? "",
                album: track.album ?? "",
                duration: track.duration,
                persistentID: track.persistentID ?? "",
                isFavorited: false
            )
            onTrackChanged()
        }
    }

    // MARK: - Track Change

    private func onTrackChanged() {
        let identity = currentTrack.identity
        guard identity != lastFetchedTrackIdentity, !currentTrack.title.isEmpty else { return }

        lastFetchedTrackIdentity = identity
        lyrics = []
        hasLyrics = false
        currentLyricLine = ""
        currentLine = nil
        currentLineIndex = -1
        lastActiveIndex = -1
        lastWasInterlude = false

        guard AppSettings.shared.showMenuBarLyrics else { return }
        let track = currentTrack
        Task {
            let adamId = await NowPlayingService.getNowPlayingAdamID() ?? ""
            let lines = await amLyrics.fetchLyrics(
                trackName: track.title,
                artistName: track.artist,
                catalogId: adamId
            )
            await MainActor.run {
                guard self.currentTrack.identity == track.identity else { return }
                self.currentCatalogId = adamId
                if let lines, !lines.isEmpty {
                    self.lyrics = lines
                    self.hasLyrics = lines.contains { $0.time > 0 }
                }
            }
        }
    }

    // MARK: - Lyric Sync

    private static let interludeThreshold: TimeInterval = 5.0

    private static func makeInterludeLine(start: TimeInterval, end: TimeInterval) -> LyricLine {
        let gap = end - start
        let count = gap >= 15 ? 5 : gap >= 10 ? 4 : 3
        let symbol = "♪"
        let separator = "  "
        let text = Array(repeating: symbol, count: count).joined(separator: separator)
        let wordDuration = (end - start) / Double(count)

        var words: [LyricWord] = []
        for i in 0..<count {
            let wStart = start + Double(i) * wordDuration
            let wEnd = wStart + wordDuration
            let wText = i < count - 1 ? symbol + separator : symbol
            words.append(LyricWord(text: wText, begin: wStart, end: wEnd))
        }

        return LyricLine(id: -1, time: start, endTime: end, text: text, words: words)
    }

    private func updateCurrentLyric() {
        guard !lyrics.isEmpty else { return }
        let pos = playerPosition

        var activeIdx = -1
        for (i, line) in lyrics.enumerated() {
            if line.time <= pos { activeIdx = i } else { break }
        }

        // Detect interlude: past current line's endTime with a large gap before the next line
        var isInterlude = false
        if activeIdx >= 0, lyrics[activeIdx].endTime > 0, pos > lyrics[activeIdx].endTime {
            let nextStart = activeIdx + 1 < lyrics.count ? lyrics[activeIdx + 1].time : .infinity
            isInterlude = (nextStart - lyrics[activeIdx].endTime) >= Self.interludeThreshold
        }

        guard activeIdx != lastActiveIndex || isInterlude != lastWasInterlude else { return }
        lastActiveIndex = activeIdx
        lastWasInterlude = isInterlude

        if activeIdx < 0 {
            currentLyricLine = ""
            currentLine = nil
            currentLineIndex = -1
        } else if isInterlude {
            // Build a synthetic interlude LyricLine for karaoke animation
            let start = lyrics[activeIdx].endTime
            let end = activeIdx + 1 < lyrics.count ? lyrics[activeIdx + 1].time : start + 5
            let line = Self.makeInterludeLine(start: start, end: end)
            currentLyricLine = line.text
            currentLine = line
            currentLineIndex = activeIdx
        } else {
            currentLyricLine = lyrics[activeIdx].text
            currentLine = lyrics[activeIdx]
            currentLineIndex = activeIdx
        }
    }

    private func mapPlayerState(_ state: MusicEPlS) -> PlayerState {
        switch state {
        case MusicEPlSStopped:        return .stopped
        case MusicEPlSPlaying:        return .playing
        case MusicEPlSPaused:         return .paused
        case MusicEPlSFastForwarding: return .fastForwarding
        case MusicEPlSRewinding:      return .rewinding
        default:                      return .unknown
        }
    }

    func playPause() { musicApp.playpause() }
    func nextTrack() { musicApp.nextTrack() }
    func backTrack() { musicApp.backTrack() }

    func revealInMusic() {
        guard let track = musicApp.currentTrack else { return }
        track.reveal()
        musicApp.activate()
    }

    // MARK: - Lyrics Management

    /// Re-fetch lyrics for the current track if not already loaded.
    /// Called when menu bar lyrics is toggled ON while a track is playing.
    func fetchLyricsIfNeeded() {
        guard !currentTrack.title.isEmpty, lyrics.isEmpty else { return }
        lastFetchedTrackIdentity = ""
        onTrackChanged()
    }

    func cachedLyricsFileURL() -> URL? {
        guard !currentCatalogId.isEmpty else { return nil }
        return amLyrics.cachedFileURL(catalogId: currentCatalogId)
    }
}
