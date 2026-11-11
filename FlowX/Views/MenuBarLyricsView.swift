import AppKit
import QuartzCore

final class MenuBarLyricsView: NSView {
    private let mc = MusicController.shared
    private var animationLayer: LyricsAnimationLayer!

    // MARK: - Hover controls

    private let iconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        .applying(.init(hierarchicalColor: .labelColor))

    private func symbol(_ name: String, accessibility: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: accessibility)?
            .withSymbolConfiguration(iconConfig)
    }

    private lazy var prevButton = makeControlButton("backward.end.fill", accessibility: "Previous Track", action: #selector(prevTapped))
    private lazy var playPauseButton = makeControlButton("play.fill", accessibility: "Play", action: #selector(playPauseTapped))
    private lazy var nextButton = makeControlButton("forward.end.fill", accessibility: "Next Track", action: #selector(nextTapped))
    private lazy var controlButtons = [prevButton, playPauseButton, nextButton]

    var onPrev: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?

    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var currentText = ""

    // MARK: - Animation timer

    private var animTimer: Timer?

    // MARK: - Public properties

    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            playPauseButton.image = symbol(isPlaying ? "pause.fill" : "play.fill",
                                               accessibility: isPlaying ? "Pause" : "Play")
            if animationLayer.isAnimating {
                if isPlaying { animationLayer.unfreeze() } else { animationLayer.freeze() }
                updateAnimTimer()
            } else {
                rebuildAnimation()
            }
        }
    }

    var text: String {
        get { currentText }
        set {
            guard newValue != currentText else { return }
            currentText = newValue
            rebuildAnimation()
        }
    }

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        animTimer?.invalidate()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true

        animationLayer = LyricsAnimationLayer()
        animationLayer.frame = bounds
        animationLayer.masksToBounds = true
        animationLayer.karaokeEnabled = AppSettings.shared.menuBarKaraoke
        animationLayer.edgeFadeWidth = CGFloat(AppSettings.shared.menuBarEdgeFadeWidth)
        animationLayer.renderAppearance = effectiveAppearance
        layer?.addSublayer(animationLayer)

        setupControlButtons()
        updateTrackingArea()
    }

    // MARK: - Animation Timer

    private func startAnimTimer() {
        guard animTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            self?.animationLayer.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private func stopAnimTimer() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func updateAnimTimer() {
        if animationLayer.isAnimating && isPlaying {
            startAnimTimer()
        } else {
            stopAnimTimer()
        }
    }

    // MARK: - Drift Detection

    private let driftThreshold: TimeInterval = 1.0
    private let driftResyncCooldown: CFTimeInterval = 1.0
    private var lastDriftResyncAt: CFTimeInterval = 0

    /// Called on each poll. Detects animation drift from actual playback position and rebuilds if needed.
    func syncIfNeeded() {
        guard animationLayer.isAnimating, !isHovering, isPlaying else { return }
        let now = CACurrentMediaTime()
        guard now - lastDriftResyncAt >= driftResyncCooldown else { return }
        let actual = mc.playerPosition

        let expected: TimeInterval
        if isPlaying {
            expected = animationLayer.anchorPosition + (now - animationLayer.anchorWallTime)
        } else {
            expected = animationLayer.anchorPosition
        }

        let drift = abs(actual - expected)
        guard drift > driftThreshold else { return }
        lastDriftResyncAt = now
        rebuildAnimation()
    }

    private func rebuildAnimation() {
        guard !isHovering else { return }
        animationLayer.karaokeEnabled = AppSettings.shared.menuBarKaraoke
        animationLayer.edgeFadeWidth = CGFloat(AppSettings.shared.menuBarEdgeFadeWidth)
        animationLayer.update(
            text: currentText,
            line: mc.currentLine,
            position: mc.playerPosition,
            playing: isPlaying
        )
        updateAnimTimer()
    }

    func refreshLayers() {
        animationLayer.renderAppearance = effectiveAppearance
        rebuildAnimation()
    }

    // MARK: - NSView lifecycle

    private var isHandlingAppearanceChange = false

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard !isHandlingAppearanceChange else { return }
        isHandlingAppearanceChange = true
        refreshLayers()
        isHandlingAppearanceChange = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = bounds.width
        super.setFrameSize(newSize)
        guard newSize.width != oldWidth else { return }
        animationLayer.frame = CGRect(origin: .zero, size: newSize)
        rebuildAnimation()
    }

    // MARK: - Hover controls setup

    private func makeControlButton(_ symbolName: String, accessibility: String? = nil, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.image = symbol(symbolName, accessibility: accessibility)
        btn.bezelStyle = .regularSquare
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.target = self
        btn.action = action
        btn.isHidden = true
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.widthAnchor.constraint(equalToConstant: 20).isActive = true
        btn.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return btn
    }

    private func setupControlButtons() {
        let stack = NSStackView(views: controlButtons)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func prevTapped() { onPrev?() }
    @objc private func playPauseTapped() { onPlayPause?() }
    @objc private func nextTapped() { onNext?() }

    // MARK: - Tracking area + hover

    private func updateTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        controlButtons.forEach { $0.isHidden = false }
        animationLayer.isHidden = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        controlButtons.forEach { $0.isHidden = true }
        animationLayer.isHidden = false
        rebuildAnimation()
    }
}
