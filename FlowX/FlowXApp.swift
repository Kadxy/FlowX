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
    private var lyricsItem: NSStatusItem!
    private var lyricsView: MenuBarLyricsView!
    private let mc = MusicController.shared
    private var cancellables = Set<AnyCancellable>()
    private lazy var menu = makeMenu()
    private var menuBarLyricsItem: NSMenuItem!

    private var menuBarLyricsWidth: CGFloat {
        CGFloat(AppSettings.shared.menuBarLyricsWidth)
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

        // Lyrics item — display only, created second so it appears to the left
        let w = menuBarLyricsWidth
        lyricsItem = NSStatusBar.system.statusItem(withLength: w)
        lyricsItem.button?.sendAction(on: [])

        lyricsView = MenuBarLyricsView(frame: NSRect(x: 0, y: 0, width: w, height: 22))
        lyricsView.font = NSFont.systemFont(ofSize: 14)
        lyricsView.onPrev = { [weak self] in self?.mc.previousTrack() }
        lyricsView.onPlayPause = { [weak self] in self?.mc.playPause() }
        lyricsView.onNext = { [weak self] in self?.mc.nextTrack() }
        lyricsItem.button?.addSubview(lyricsView)

        applyMenuBarVisibility()
        updateMenuBar()

        NotificationCenter.default.addObserver(
            self, selector: #selector(onMenuBarLyricsWidthChanged),
            name: .menuBarLyricsWidthChanged, object: nil
        )

        mc.$currentLyricLine.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBar() }.store(in: &cancellables)
        mc.$currentTrack.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBar() }.store(in: &cancellables)
        mc.$hasLyrics.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBar() }.store(in: &cancellables)
        mc.$playerState.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.lyricsView.isPlaying = self?.mc.playerState.isPlaying ?? false }
            .store(in: &cancellables)
        mc.$isMusicRunning.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateMenuBar() }.store(in: &cancellables)
    }

    @objc private func logoClicked() {
        guard let button = logoItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        // Refresh after menu closes (RunLoop was blocked during tracking)
        updateMenuBar()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        menuBarLyricsItem = NSMenuItem(title: String(localized: "Menu Bar Lyrics"), action: #selector(toggleMenuBarLyrics), keyEquivalent: "")
        menuBarLyricsItem.target = self
        menuBarLyricsItem.image = NSImage(systemSymbolName: "text.quote", accessibilityDescription: nil)
        menuBarLyricsItem.state = AppSettings.shared.showMenuBarLyrics ? .on : .off
        menu.addItem(menuBarLyricsItem)

        let settingsItem = NSMenuItem(title: String(localized: "Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit FlowX"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        return menu
    }

    @objc private func toggleMenuBarLyrics() {
        let newValue = !AppSettings.shared.showMenuBarLyrics
        AppSettings.shared.showMenuBarLyrics = newValue
        menuBarLyricsItem.state = newValue ? .on : .off
        applyMenuBarVisibility()
    }

    private func applyMenuBarVisibility() {
        lyricsItem.isVisible = AppSettings.shared.showMenuBarLyrics
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func onMenuBarLyricsWidthChanged() {
        let w = menuBarLyricsWidth
        lyricsItem.length = w
        lyricsView.frame = NSRect(x: 0, y: 0, width: w, height: 22)
    }

    private func updateMenuBar() {
        guard mc.isMusicRunning, !mc.currentTrack.title.isEmpty else {
            lyricsView.text = String(localized: "♪ Not Playing")
            return
        }

        let trackLabel = "\(mc.currentTrack.title) - \(mc.currentTrack.artist)"

        if mc.hasLyrics, !mc.currentLyricLine.isEmpty {
            lyricsView.text = mc.currentLyricLine
        } else {
            lyricsView.text = trackLabel
        }

        lyricsView.isPlaying = mc.playerState.isPlaying
    }
}
