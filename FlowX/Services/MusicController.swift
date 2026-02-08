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

        // Instant state/track changes via notification
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
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollPosition()
        }
        RunLoop.main.add(timer, forMode: .common)

        refreshState()
    }

    // MARK: - Notification handler (instant response to play/pause/track change)

    @objc private func onPlayerInfoChanged(_ notification: Notification) {
        let info = notification.userInfo

        // Player state
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

        // Track info from notification (no SB IPC)
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

    // MARK: - Music.app quit detection

    @objc private func onAppTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == "com.apple.Music" else { return }

        isMusicRunning = false
        playerState = .stopped
        currentTrack = .empty
        playerPosition = 0
        currentLyricLine = ""
        lastActiveIndex = -1
    }

    // MARK: - Position polling (only active when playing)

    private func pollPosition() {
        guard isMusicRunning, playerState == .playing else { return }

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
