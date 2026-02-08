import AppKit

final class MenuBarLyricsView: NSView {
    private var currentText = ""
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    // Pre-cached SF Symbol images (hierarchicalColor resolves dynamically per draw)
    private let iconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        .applying(.init(hierarchicalColor: .labelColor))
    private lazy var prevImage = NSImage(systemSymbolName: "backward.end.fill", accessibilityDescription: nil)?.withSymbolConfiguration(iconConfig)
    private lazy var playImage = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)?.withSymbolConfiguration(iconConfig)
    private lazy var pauseImage = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)?.withSymbolConfiguration(iconConfig)
    private lazy var nextImage = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil)?.withSymbolConfiguration(iconConfig)

    var onPrev: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?

    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue, isHovering else { return }
            needsDisplay = true
        }
    }

    var font: NSFont = NSFont.systemFont(ofSize: 14) {
        didSet { if !isHovering { needsDisplay = true } }
    }

    var text: String {
        get { currentText }
        set {
            guard newValue != currentText else { return }
            currentText = newValue
            if !isHovering { needsDisplay = true }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
        updateTrackingArea()
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            drawControls()
        } else {
            drawLyrics()
        }
    }

    private func drawLyrics() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let size = (currentText as NSString).size(withAttributes: attrs)
        let x = size.width <= bounds.width ? (bounds.width - size.width) / 2 : 0
        let y = (bounds.height - size.height) / 2
        (currentText as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }

    private func drawControls() {
        let images = [prevImage, isPlaying ? pauseImage : playImage, nextImage]
        let iconH: CGFloat = 14
        let gap: CGFloat = 20
        let totalW = CGFloat(images.count) * iconH + CGFloat(images.count - 1) * gap
        var x = (bounds.width - totalW) / 2
        let y = (bounds.height - iconH) / 2

        for img in images {
            guard let img else { continue }
            let rect = NSRect(x: x, y: y, width: iconH, height: iconH)
            img.draw(in: rect)
            x += iconH + gap
        }
    }

    // MARK: - Tracking area

    private func updateTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }

    // MARK: - Click handling (divide into thirds)

    override func mouseDown(with event: NSEvent) {
        guard isHovering else { return }
        let loc = convert(event.locationInWindow, from: nil)
        let third = bounds.width / 3

        if loc.x < third {
            onPrev?()
        } else if loc.x < third * 2 {
            onPlayPause?()
        } else {
            onNext?()
        }
    }
}
