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
    private var logoItem: NSStatusItem!
    private var tickerItem: NSStatusItem!
    private var tickerView: TickerView!
    private let mc = MusicController.shared
    private var cancellables = Set<AnyCancellable>()

    private var tickerWidth: CGFloat {
        CGFloat(AppSettings.shared.tickerWidth)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Logo item — native NSStatusBarButton, created first so it sits on the right
        logoItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: "music.pages.fill", accessibilityDescription: "FlowX")?
            .withSymbolConfiguration(config)
        img?.isTemplate = true
        logoItem.button?.image = img
        logoItem.button?.target = self
        logoItem.button?.action = #selector(logoClicked)
        logoItem.button?.sendAction(on: [.leftMouseUp])
        logoItem.menu = makeMenu()

        // Ticker item — display only, created second so it appears to the left
        let w = tickerWidth
        tickerItem = NSStatusBar.system.statusItem(withLength: w)
        tickerItem.button?.sendAction(on: [])

        tickerView = TickerView(frame: NSRect(x: 0, y: 0, width: w, height: 22))
        tickerView.font = NSFont.systemFont(ofSize: 14)
        tickerView.onPrev = { [weak self] in self?.mc.previousTrack() }
        tickerView.onPlayPause = { [weak self] in self?.mc.playPause() }
        tickerView.onNext = { [weak self] in self?.mc.nextTrack() }
        tickerItem.button?.addSubview(tickerView)

        updateTicker()

        NotificationCenter.default.addObserver(
            self, selector: #selector(onWidthChanged),
            name: .tickerWidthChanged, object: nil
        )

        mc.$currentLyricLine.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTicker() }.store(in: &cancellables)
        mc.$currentTrack.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTicker() }.store(in: &cancellables)
        mc.$hasLyrics.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTicker() }.store(in: &cancellables)
        mc.$playerState.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tickerView.isPlaying = self?.mc.playerState.isPlaying ?? false }
            .store(in: &cancellables)
        mc.$isMusicRunning.removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateTicker() }.store(in: &cancellables)
    }

    @objc private func logoClicked() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit FlowX", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func onWidthChanged() {
        let w = tickerWidth
        tickerItem.length = w
        tickerView.frame = NSRect(x: 0, y: 0, width: w, height: 22)
    }

    private func updateTicker() {
        guard mc.isMusicRunning, !mc.currentTrack.title.isEmpty else {
            tickerView.text = "♪ Not Playing"
            return
        }

        let trackLabel = "\(mc.currentTrack.title) - \(mc.currentTrack.artist)"

        if mc.hasLyrics, !mc.currentLyricLine.isEmpty {
            tickerView.text = mc.currentLyricLine
        } else {
            tickerView.text = trackLabel
        }

        tickerView.isPlaying = mc.playerState.isPlaying
    }
}
