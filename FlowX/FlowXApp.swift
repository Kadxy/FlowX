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
    private var openInMusicItem: NSMenuItem!
    private var menuBarLyricsItem: NSMenuItem!
    private var viewLyricsFileItem: NSMenuItem!
    private var clearCacheItem: NSMenuItem!
    private var selectLyricsItem: NSMenuItem!
    private var selectLyricsSubmenu: NSMenu!

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(onMenuBarKaraokeChanged),
            name: .menuBarKaraokeChanged, object: nil
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
        let m = menu // trigger lazy init before updating items
        updateLyricsMenuItems()
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
        // Refresh after menu closes (RunLoop was blocked during tracking)
        updateMenuBar()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

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

        let desktopLyricsItem = NSMenuItem(title: String(localized: "Desktop Lyrics"), action: nil, keyEquivalent: "")
        desktopLyricsItem.image = NSImage(systemSymbolName: "menubar.dock.rectangle", accessibilityDescription: nil)
        desktopLyricsItem.isEnabled = false
        menu.addItem(desktopLyricsItem)

        menu.addItem(NSMenuItem.separator())

        viewLyricsFileItem = NSMenuItem(title: String(localized: "View Lyrics File"), action: #selector(viewLyricsFile), keyEquivalent: "")
        viewLyricsFileItem.target = self
        viewLyricsFileItem.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        menu.addItem(viewLyricsFileItem)

        clearCacheItem = NSMenuItem(title: String(localized: "Clear Cache & Reload"), action: #selector(clearCacheAndReload), keyEquivalent: "")
        clearCacheItem.target = self
        clearCacheItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(clearCacheItem)

        selectLyricsItem = NSMenuItem(title: String(localized: "Select Lyrics..."), action: nil, keyEquivalent: "")
        selectLyricsItem.image = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: nil)
        selectLyricsSubmenu = NSMenu()
        selectLyricsSubmenu.delegate = self
        selectLyricsItem.submenu = selectLyricsSubmenu
        menu.addItem(selectLyricsItem)

        menu.addItem(NSMenuItem.separator())

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

    private func updateLyricsMenuItems() {
        let hasTrack = mc.isMusicRunning && !mc.currentTrack.title.isEmpty
        let hasCachedFile = hasTrack && mc.cachedLyricsFileURL() != nil
        openInMusicItem.isEnabled = hasTrack
        viewLyricsFileItem.isEnabled = hasCachedFile
        clearCacheItem.isEnabled = hasCachedFile
        selectLyricsItem.isEnabled = hasTrack
    }

    @objc private func openInMusic() {
        mc.revealInMusic()
    }

    @objc private func toggleMenuBarLyrics() {
        let newValue = !AppSettings.shared.showMenuBarLyrics
        AppSettings.shared.showMenuBarLyrics = newValue
        menuBarLyricsItem.state = newValue ? .on : .off
        applyMenuBarVisibility()
    }

    @objc private func viewLyricsFile() {
        guard let url = mc.cachedLyricsFileURL() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func clearCacheAndReload() {
        mc.refetchLyrics()
    }

    @objc private func selectLyricsResult(_ sender: NSMenuItem) {
        guard let songId = sender.representedObject as? String else { return }
        mc.selectLyrics(songId: songId)
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

    @objc private func onMenuBarKaraokeChanged() {
        lyricsView.refreshLayers()
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

// MARK: - NSMenuDelegate (lazy-load search results for "Select Lyrics..." submenu)

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === selectLyricsSubmenu else { return }

        menu.removeAllItems()
        let loadingItem = NSMenuItem(title: String(localized: "Searching..."), action: nil, keyEquivalent: "")
        loadingItem.isEnabled = false
        menu.addItem(loadingItem)

        Task {
            let results = await mc.searchCatalogResults()
            await MainActor.run {
                menu.removeAllItems()
                if results.isEmpty {
                    let emptyItem = NSMenuItem(title: String(localized: "No Results"), action: nil, keyEquivalent: "")
                    emptyItem.isEnabled = false
                    menu.addItem(emptyItem)
                    return
                }
                for song in results {
                    let durStr = Self.formatDuration(song.duration)
                    let title = "\(song.name) - \(song.artist)  (\(durStr))"
                    let item = NSMenuItem(title: title, action: #selector(self.selectLyricsResult(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = song.id
                    menu.addItem(item)
                }
            }
        }
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
