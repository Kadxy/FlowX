import Foundation
import ScriptingBridge
import Combine

final class MusicController: ObservableObject {
    static let shared = MusicController()

    @Published private(set) var playerState: PlayerState = .stopped
    @Published private(set) var currentTrack: TrackInfo = .empty
    @Published private(set) var isMusicRunning: Bool = false
    @Published private(set) var currentLyricLine: String = ""
    @Published private(set) var hasLyrics: Bool = false

    private(set) var playerPosition: TimeInterval = 0

    private let musicApp: MusicApplication
    private let amLyrics = LyricsService()
    private var lyrics: [LyricLine] = []
    private var lastFetchedTrackIdentity = ""
    private var lastActiveIndex: Int = -1

    private init() {
        let app: AnyObject = SBApplication(bundleIdentifier: "com.apple.Music")!
        musicApp = unsafeBitCast(app, to: MusicApplication.self)

        // Listen for Apple Music state changes (immediate, no polling needed)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(onPlayerInfoChanged(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )

        // Timer only for position updates (lyric sync)
        // Use .common mode so it keeps firing during menu tracking
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollPosition()
        }
        RunLoop.main.add(timer, forMode: .common)

        // Initial state
        refreshState()
    }

    // MARK: - Notification handler (instant response to play/pause/track change)

    @objc private func onPlayerInfoChanged(_ notification: Notification) {
        let info = notification.userInfo

        // Player state from notification
        if let stateStr = info?["Player State"] as? String {
            let newState: PlayerState
            switch stateStr {
            case "Playing": newState = .playing
            case "Paused":  newState = .paused
            case "Stopped": newState = .stopped
            default:        newState = .unknown
            }
            if newState != playerState { playerState = newState }
            isMusicRunning = true
        }

        // Track info from notification
        let name = info?["Name"] as? String ?? ""
        let artist = info?["Artist"] as? String ?? ""
        let album = info?["Album"] as? String ?? ""
        let totalTime = info?["Total Time"] as? Double ?? 0
        let duration = totalTime / 1000.0 // ms → s

        // persistentID: notification gives Int64, ScriptingBridge gives hex string
        // Use ScriptingBridge for consistent hex format
        let persistentID = musicApp.currentTrack?.persistentID ?? ""

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

    // MARK: - Position polling (only for lyric sync, lightweight)

    private func pollPosition() {
        guard musicApp.isRunning else {
            if isMusicRunning {
                isMusicRunning = false
                playerState = .stopped
                currentTrack = .empty
                playerPosition = 0
                currentLyricLine = ""
                lastActiveIndex = -1
            }
            return
        }

        playerPosition = musicApp.playerPosition
        updateCurrentLyric()
    }

    // MARK: - Full state refresh (on launch only)

    private func refreshState() {
        guard musicApp.isRunning else { return }
        isMusicRunning = true

        let rawState = musicApp.playerState
        playerState = mapPlayerState(rawState)
        playerPosition = musicApp.playerPosition

        if let track = musicApp.currentTrack {
            currentTrack = TrackInfo(
                title: track.name ?? "Unknown",
                artist: track.artist ?? "Unknown",
                album: track.album ?? "",
                duration: track.duration,
                persistentID: track.persistentID ?? "",
                isFavorited: false
            )
            onTrackChanged()
        }
    }

    // MARK: - Track change → fetch lyrics

    private func onTrackChanged() {
        let identity = currentTrack.identity
        guard identity != lastFetchedTrackIdentity, !currentTrack.title.isEmpty else { return }

        lastFetchedTrackIdentity = identity
        lyrics = []
        hasLyrics = false
        currentLyricLine = ""
        lastActiveIndex = -1

        let track = currentTrack
        Task {
            let lines = await amLyrics.fetchLyrics(
                trackName: track.title,
                artistName: track.artist,
                duration: track.duration,
                persistentID: track.persistentID
            )
            await MainActor.run {
                guard self.currentTrack.identity == track.identity else { return }
                if let lines, !lines.isEmpty {
                    self.lyrics = lines
                    self.hasLyrics = true
                }
            }
        }
    }

    // MARK: - Lyric sync

    private func updateCurrentLyric() {
        guard !lyrics.isEmpty else { return }
        let pos = playerPosition

        var activeIdx = -1
        for (i, line) in lyrics.enumerated() {
            if line.time <= pos { activeIdx = i } else { break }
        }

        if activeIdx != lastActiveIndex {
            lastActiveIndex = activeIdx
            currentLyricLine = activeIdx >= 0 ? lyrics[activeIdx].text : ""
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
    func previousTrack() { musicApp.previousTrack() }
}
