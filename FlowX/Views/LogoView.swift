import AppKit

final class LogoView: NSView {
    private let imageView = NSImageView()
    private var isMouseDown = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 3

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        img?.isTemplate = true
        imageView.image = img
        imageView.imageScaling = .scaleNone
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        imageView.frame = bounds
    }

    // MARK: - Left click: pressed effect on down, action on up

    override func mouseDown(with event: NSEvent) {
        isMouseDown = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.15).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = nil
        guard isMouseDown else { return }
        isMouseDown = false

        let loc = convert(event.locationInWindow, from: nil)
        if bounds.contains(loc) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
        }
    }

    // MARK: - Right click: context menu

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit FlowX", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
