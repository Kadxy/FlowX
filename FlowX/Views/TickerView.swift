import AppKit
import QuartzCore

final class TickerView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var currentText = ""
    private var animKey = "scroll"
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    private var btnPrev: NSButton!
    private var btnPlayPause: NSButton!
    private var btnNext: NSButton!

    var onPrev: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?
    var isPlaying: Bool = false { didSet { updateButtonIcon() } }

    var loop = false
    var lineDuration: TimeInterval = 5

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
        let icons = ["backward.fill", "play.fill", "forward.fill"]
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
        // 只在宽度变化时重建动画，避免 layout ↔ updateDisplay 递归
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        label.layer?.removeAllAnimations()
        label.stringValue = currentText
        label.sizeToFit()

        let textWidth = label.frame.width
        let viewWidth = bounds.width
        let h = bounds.height
        let labelY = (h - label.frame.height) / 2

        if textWidth <= viewWidth {
            label.frame = NSRect(x: (viewWidth - textWidth) / 2, y: labelY, width: textWidth, height: label.frame.height)
            CATransaction.commit()
            return
        }

        let overflow = textWidth - viewWidth

        if loop {
            let padded = currentText + "        " + currentText
            label.stringValue = padded
            label.sizeToFit()
            let paddedWidth = label.frame.width
            label.frame = NSRect(x: 0, y: labelY, width: paddedWidth, height: label.frame.height)
            CATransaction.commit()

            let loopDist = measureText(currentText + "        ")
            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = label.frame.origin.x + paddedWidth / 2
            anim.toValue = anim.fromValue as! CGFloat - loopDist
            anim.duration = CFTimeInterval(loopDist / 30)
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .linear)
            label.layer?.add(anim, forKey: animKey)
        } else {
            label.frame = NSRect(x: 0, y: labelY, width: textWidth, height: label.frame.height)
            CATransaction.commit()

            let availableTime = max(lineDuration, 2)
            let waitTime = availableTime * 0.55
            let scrollTime = max(availableTime * 0.45 - 0.3, 0.5)
            let clampedSpeed = min(max(Double(overflow) / scrollTime, 20), 80)
            let cx = label.frame.origin.x + textWidth / 2

            let anim = CABasicAnimation(keyPath: "position.x")
            anim.fromValue = cx
            anim.toValue = cx - overflow
            anim.beginTime = CACurrentMediaTime() + waitTime
            anim.duration = Double(overflow) / clampedSpeed
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            label.layer?.add(anim, forKey: animKey)
        }
    }

    private func measureText(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    override func mouseDown(with event: NSEvent) {}
}
