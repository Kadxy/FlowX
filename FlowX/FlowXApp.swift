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
    private var statusItem: NSStatusItem!
    private var lyricsView: MenuBarLyricsView!
    private lazy var mc = MusicController.shared
    private var cancellables = Set<AnyCancellable>()
    private lazy var menu = makeMenu()
    private var openInMusicItem: NSMenuItem!
    private var menuBarLyricsItem: NSMenuItem!
    private var viewLyricsFileItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensure Apple Music is installed — FlowX is designed exclusively for Apple Music
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") != nil else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Apple Music Not Found")
            alert.informativeText = String(localized: "FlowX requires Apple Music to be installed on your Mac.")
            alert.alertStyle = .critical
            alert.addButton(withTitle: String(localized: "Quit"))
            alert.runModal()
            NSApp.terminate(nil)
            return
        }

        let settings = AppSettings.shared

        // A single status item carries the lyrics, the hover controls and the menu entry. Keeping
        // them in separate items is what let clicks land on the wrong element on macOS 27.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.sendAction(on: [])

        lyricsView = MenuBarLyricsView(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        lyricsView.onMenu = { [weak self] in self?.showMenu() }
        lyricsView.onPrev = { [weak self] in self?.mc.backTrack() }
        lyricsView.onPlayPause = { [weak self] in self?.mc.playPause() }
        lyricsView.onNext = { [weak self] in self?.mc.nextTrack() }
        statusItem.button?.addSubview(lyricsView)

        mc.onPositionUpdated = { [weak self] in self?.lyricsView.syncIfNeeded() }

        applyMenuBarVisibility()
        updateMenuBar()

        // Observe settings changes
        settings.$menuBarLyricsWidth
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.layoutStatusItem() }
            .store(in: &cancellables)

        settings.$showMenuBarLyrics
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isVisible in
                guard let self else { return }
                self.applyMenuBarVisibility()
                self.menuBarLyricsItem.state = isVisible ? .on : .off
                if isVisible {
                    self.mc.fetchLyricsIfNeeded()
                    self.updateMenuBar()
                }
            }
            .store(in: &cancellables)

        Publishers.Merge(
            settings.$menuBarKaraoke.dropFirst().map { _ in },
            settings.$menuBarEdgeFadeWidth.dropFirst().map { _ in }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] in
            self?.lyricsView.refreshLayers()
        }
        .store(in: &cancellables)

        // Observe music state
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

    /// Gap between the menu bar's bottom edge and the menu.
    private static let menuGap: CGFloat = 2

    private func showMenu() {
        guard let button = statusItem.button else { return }
        // Touch `menu` first: it is lazy, and makeMenu() is what populates the item references.
        let m = menu
        updateLyricsMenuItems()
        m.popUp(positioning: nil, at: menuOrigin(in: button), in: button)
        updateMenuBar()
    }

    /// Top-left corner for the menu, in the button's coordinates: the item's left edge, just
    /// below the menu bar. A fixed offset from the button is not enough — the bar's height
    /// varies by display and system version, and a menu that starts even half a point inside
    /// the bar is clipped into a scrolling menu.
    private func menuOrigin(in button: NSStatusBarButton) -> NSPoint {
        let fallback = NSPoint(x: 0, y: button.bounds.height + 5)
        guard let window = button.window, let screen = window.screen ?? NSScreen.main else { return fallback }

        let itemFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        // Status items are centred vertically in the menu bar, so its bottom edge mirrors the
        // top of the screen around the item. `visibleFrame` bounds it when the bar is showing.
        let menuBarBottom = min(2 * itemFrame.midY - screen.frame.maxY, screen.visibleFrame.maxY)
        let origin = NSPoint(x: itemFrame.minX, y: menuBarBottom - Self.menuGap)

        return button.convert(window.convertPoint(fromScreen: origin), from: nil)
    }

    /// Sizes the status item to the lyrics, or to the logo alone when lyrics are off, and
    /// matches the view to the button's bounds.
    private func layoutStatusItem() {
        statusItem.length = AppSettings.shared.showMenuBarLyrics
            ? CGFloat(AppSettings.shared.menuBarLyricsWidth)
            : MenuBarLyricsView.logoWidth
        if let button = statusItem.button {
            lyricsView.frame = button.bounds
            lyricsView.needsLayout = true
            lyricsView.layoutSubtreeIfNeeded()
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        openInMusicItem = NSMenuItem(title: String(localized: "Open in Apple Music"), action: #selector(openInMusic), keyEquivalent: "")
        openInMusicItem.target = self
        openInMusicItem.image = NSImage(systemSymbolName: "arrow.up.forward", accessibilityDescription: nil)
        menu.addItem(openInMusicItem)

        menu.addItem(NSMenuItem.separator())

        menuBarLyricsItem = NSMenuItem(title: String(localized: "Menu Bar Lyrics"), action: #selector(toggleMenuBarLyrics), keyEquivalent: "")
        menuBarLyricsItem.target = self
        menuBarLyricsItem.image = NSImage(systemSymbolName: "menubar.rectangle", accessibilityDescription: nil)
        menuBarLyricsItem.state = AppSettings.shared.showMenuBarLyrics ? .on : .off
        menu.addItem(menuBarLyricsItem)

        menu.addItem(NSMenuItem.separator())

        viewLyricsFileItem = NSMenuItem(title: String(localized: "View Lyrics File"), action: #selector(viewLyricsFile), keyEquivalent: "")
        viewLyricsFileItem.target = self
        viewLyricsFileItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        menu.addItem(viewLyricsFileItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: String(localized: "Settings..."), action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let aboutItem = NSMenuItem(title: String(localized: "About FlowX"), action: #selector(openAbout), keyEquivalent: "")
        aboutItem.target = self
        aboutItem.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: String(localized: "Quit FlowX"), action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        return menu
    }

    private func updateLyricsMenuItems() {
        let hasTrack = mc.isMusicRunning && mc.playerState != .stopped && !mc.currentTrack.title.isEmpty
        let hasCachedFile = hasTrack && mc.cachedLyricsFileURL() != nil
        openInMusicItem.isEnabled = hasTrack
        viewLyricsFileItem.isEnabled = hasCachedFile
    }

    @objc private func openInMusic() {
        mc.revealInMusic()
    }

    @objc private func toggleMenuBarLyrics() {
        let newValue = !AppSettings.shared.showMenuBarLyrics
        AppSettings.shared.showMenuBarLyrics = newValue
        menuBarLyricsItem.state = newValue ? .on : .off
        applyMenuBarVisibility()
        if newValue {
            mc.fetchLyricsIfNeeded()
            updateMenuBar()
        }
    }

    @objc private func viewLyricsFile() {
        guard let url = mc.cachedLyricsFileURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The item itself always stays visible so the menu remains reachable; with menu bar
    /// lyrics off it shrinks to the logo.
    private func applyMenuBarVisibility() {
        lyricsView.showsLyrics = AppSettings.shared.showMenuBarLyrics
        layoutStatusItem()
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
    }

    @objc private func openAbout() {
        AboutWindowController.shared.showWindow(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func updateMenuBar() {
        guard mc.isMusicRunning, !mc.currentTrack.title.isEmpty else {
            lyricsView.text = String(localized: "♪ Not Playing")
            return
        }

        let track = mc.currentTrack
        let trackLabel = track.artist.isEmpty ? track.title : "\(track.title) - \(track.artist)"

        if mc.hasLyrics, !mc.currentLyricLine.isEmpty {
            lyricsView.text = mc.currentLyricLine
        } else {
            lyricsView.text = trackLabel
        }

        lyricsView.isPlaying = mc.playerState.isPlaying
    }
}
