import AppKit

final class TickerView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var currentText = ""
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    private var btnPrev: NSButton!
    private var btnPlayPause: NSButton!
    private var btnNext: NSButton!

    var onPrev: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var isPlaying: Bool = false { didSet { updateButtonIcon() } }

    var font: NSFont = NSFont.systemFont(ofSize: 14) {
        didSet { label.font = font; updateDisplay() }
    }

    var text: String {
        get { currentText }
        set {
            guard newValue != currentText else { return }
            currentText = newValue
            if !isHovering { updateDisplay() }
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

        label.font = font
        label.lineBreakMode = .byClipping
        label.wantsLayer = true
        addSubview(label)

        setupHoverButtons()
        updateTrackingArea()
    }

    // MARK: - Hover buttons

    private func setupHoverButtons() {
        let icons = ["backward.end.fill", "play.fill", "forward.end.fill"]
        var buttons: [NSButton] = []
        for (i, icon) in icons.enumerated() {
            let btn = NSButton(frame: .zero)
            btn.bezelStyle = .inline
            btn.isBordered = false
            btn.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            btn.imageScaling = .scaleProportionallyDown
            (btn.cell as? NSButtonCell)?.highlightsBy = []
            btn.target = self
            btn.action = #selector(buttonTapped(_:))
            btn.tag = i
            btn.isHidden = true
            addSubview(btn)
            buttons.append(btn)
        }
        btnPrev = buttons[0]
        btnPlayPause = buttons[1]
        btnNext = buttons[2]
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        switch sender.tag {
        case 0: onPrev?()
        case 1: onPlayPause?()
        case 2: onNext?()
        default: break
        }
    }

    private func updateButtonIcon() {
        btnPlayPause?.image = NSImage(
            systemSymbolName: isPlaying ? "pause.fill" : "play.fill",
            accessibilityDescription: nil
        )
    }

    // MARK: - Tracking area (hover detection)

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
        label.isHidden = true
        setButtons(hidden: false)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        setButtons(hidden: true)
        label.isHidden = false
        updateDisplay()
    }

    private func setButtons(hidden: Bool) {
        [btnPrev, btnPlayPause, btnNext].forEach { $0?.isHidden = hidden }
    }

    // MARK: - Layout

    private var lastLayoutWidth: CGFloat = 0

    override func layout() {
        super.layout()
        relayoutButtons()
        if !isHovering && bounds.width != lastLayoutWidth {
            lastLayoutWidth = bounds.width
            updateDisplay()
        }
    }

    private func relayoutButtons() {
        let btnW: CGFloat = 28
        let gap: CGFloat = 4
        let buttons = [btnPrev, btnPlayPause, btnNext].compactMap { $0 }
        let total = CGFloat(buttons.count) * btnW + CGFloat(buttons.count - 1) * gap
        let startX = (bounds.width - total) / 2
        for (i, btn) in buttons.enumerated() {
            btn.frame = NSRect(x: startX + CGFloat(i) * (btnW + gap), y: 0, width: btnW, height: bounds.height)
        }
    }

    // MARK: - Display

    private func updateDisplay() {
        label.stringValue = currentText
        label.sizeToFit()

        let textWidth = label.frame.width
        let viewWidth = bounds.width
        let labelY = (bounds.height - label.frame.height) / 2

        label.frame = NSRect(
            x: textWidth <= viewWidth ? (viewWidth - textWidth) / 2 : 0,
            y: labelY,
            width: textWidth,
            height: label.frame.height
        )
    }

    override func mouseDown(with event: NSEvent) {}
}
