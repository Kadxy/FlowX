import SwiftUI
import AppKit
import Combine

@main
struct FlowXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let iconWidth: CGFloat = 30
    private static let gap: CGFloat = 6

    private var statusItem: NSStatusItem!
    private var tickerView: TickerView!
    private var logoView: LogoView!
    private let mc = MusicController.shared
    private var cancellables = Set<AnyCancellable>()

    private var tickerWidth: CGFloat {
        CGFloat(AppSettings.shared.tickerWidth)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = tickerWidth
        let totalWidth = w + AppDelegate.gap + AppDelegate.iconWidth
        statusItem = NSStatusBar.system.statusItem(withLength: totalWidth)
        statusItem.button?.sendAction(on: [])

        tickerView = TickerView(frame: NSRect(x: 0, y: 0, width: w, height: 22))
        tickerView.font = NSFont.systemFont(ofSize: 14)
        tickerView.onPrev = { [weak self] in self?.mc.previousTrack() }
        tickerView.onPlayPause = { [weak self] in self?.mc.playPause() }
        tickerView.onNext = { [weak self] in self?.mc.nextTrack() }
        statusItem.button?.addSubview(tickerView)

        logoView = LogoView(frame: NSRect(x: w + AppDelegate.gap, y: 0, width: AppDelegate.iconWidth, height: 22))
        statusItem.button?.addSubview(logoView)

        updateTicker()

        // Listen for width change from settings window
        NotificationCenter.default.addObserver(
            self, selector: #selector(onWidthChanged),
            name: .tickerWidthChanged, object: nil
        )

        mc.$currentLyricLine.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTicker() }.store(in: &cancellables)
        mc.$lyricLineDuration.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTicker() }.store(in: &cancellables)
        mc.$currentTrack.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTicker() }.store(in: &cancellables)
        mc.$playerState.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tickerView.isPlaying = self?.mc.playerState.isPlaying ?? false }
            .store(in: &cancellables)
        mc.$isMusicRunning.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTicker() }.store(in: &cancellables)
    }

    @objc private func onWidthChanged() {
        let w = tickerWidth
        statusItem.length = w + AppDelegate.gap + AppDelegate.iconWidth
        tickerView.frame = NSRect(x: 0, y: 0, width: w, height: 22)
        logoView.frame = NSRect(x: w + AppDelegate.gap, y: 0, width: AppDelegate.iconWidth, height: 22)
    }

    private func updateTicker() {
        guard mc.isMusicRunning, !mc.currentTrack.title.isEmpty else {
            tickerView.loop = false
            tickerView.text = "♪ Not Playing"
            return
        }

        if !mc.currentLyricLine.isEmpty {
            tickerView.loop = false
            tickerView.lineDuration = mc.lyricLineDuration
            tickerView.text = mc.currentLyricLine
        } else {
            tickerView.loop = true
            tickerView.text = "\(mc.currentTrack.title) - \(mc.currentTrack.artist)"
        }

        tickerView.isPlaying = mc.playerState.isPlaying
    }
}
