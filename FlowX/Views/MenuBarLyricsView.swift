import AppKit
import QuartzCore

/// A menu bar icon. Clicks are routed manually by the container, so the icon never gets
/// AppKit's own button behaviour. It dims while pressed, like a borderless button: the system
/// already highlights the whole status item, and a backdrop of our own would stack on top of it.
private final class MenuBarIconView: NSImageView {
    private static let pressedAlpha: CGFloat = 0.45

    func setPressed(_ pressed: Bool) {
        alphaValue = pressed ? Self.pressedAlpha : 1
    }
}

/// Menu bar content: the scrolling lyrics, which give way on hover to the playback controls.
/// A right-click (or Control-click) anywhere on the item opens the menu. With lyrics turned
/// off the item shrinks to the app logo, which opens the menu on a plain click as well.
///
/// Everything lives in a single `NSStatusItem`. All mouse handling happens in this view's own
/// coordinate space — `hitTest` claims every click and the region is resolved here — because
/// AppKit's routing of clicks to nested subviews inside an `NSStatusBarButton` is not
/// dependable (see FB23329983). Subview frames are also set manually rather than with Auto
/// Layout, which does not measure reliably inside a status bar button.
final class MenuBarLyricsView: NSView {

    /// Width of the item when only the logo is shown.
    static let logoWidth: CGFloat = 26

    private static let controlSize: CGFloat = 20
    private static let controlSpacing: CGFloat = 8

    private let mc = MusicController.shared
    private var animationLayer: LyricsAnimationLayer!

    // MARK: - Subviews

    private let logoView = MenuBarIconView()
    private lazy var prevButton = makeIconView("backward.end.fill", label: "Previous Track")
    private lazy var playPauseButton = makeIconView("play.fill", label: "Play")
    private lazy var nextButton = makeIconView("forward.end.fill", label: "Next Track")
    private lazy var controlIcons = [prevButton, playPauseButton, nextButton]

    // MARK: - Callbacks

    var onMenu: (() -> Void)?
    var onPrev: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?

    // MARK: - State

    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var currentText = ""
    private var animTimer: Timer?

    private enum Region: Equatable {
        case menu, prev, playPause, next
    }

    /// Shortest time the pressed state stays on screen, so a click is always acknowledged
    /// even when mouse-down and mouse-up are delivered back to back.
    private static let minimumHighlightDuration: CFTimeInterval = 0.15

    private var pressedRegion: Region?
    private var pressBeganAt: CFTimeInterval = 0
    private var highlightToken = 0

    // MARK: - Public properties

    /// When false the item shrinks to just the logo, so the menu stays reachable.
    var showsLyrics: Bool = true {
        didSet {
            guard showsLyrics != oldValue else { return }
            updateLyricsVisibility()
            controlIcons.forEach { $0.isHidden = true }
            needsLayout = true
            updateAnimTimer()
        }
    }

    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            playPauseButton.image = symbol(isPlaying ? "pause.fill" : "play.fill",
                                           label: isPlaying ? "Pause" : "Play")
            if animationLayer.needsTicks {
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
        animationLayer.masksToBounds = true
        animationLayer.karaokeEnabled = AppSettings.shared.menuBarKaraoke
        animationLayer.edgeFadeWidth = CGFloat(AppSettings.shared.menuBarEdgeFadeWidth)
        animationLayer.renderAppearance = effectiveAppearance
        layer?.addSublayer(animationLayer)

        logoView.image = symbol("music.pages.fill", label: "FlowX")
        addSubview(logoView)

        controlIcons.forEach { addSubview($0) }
        updateLyricsVisibility()

        updateTrackingArea()
        needsLayout = true
    }

    // MARK: - Icons

    private func symbol(_ name: String, label: String? = nil) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(config)
        // Template images adapt to the menu bar appearance, like every other status item.
        image?.isTemplate = true
        return image
    }

    private func makeIconView(_ name: String, label: String? = nil) -> MenuBarIconView {
        let view = MenuBarIconView()
        view.image = symbol(name, label: label)
        view.imageScaling = .scaleProportionallyDown
        view.isHidden = true
        return view
    }

    private func updateLyricsVisibility() {
        animationLayer.isHidden = !showsLyrics || isHovering
        logoView.isHidden = showsLyrics
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        logoView.frame = bounds

        let oldLyricsWidth = animationLayer.frame.width
        animationLayer.frame = bounds
        // The layer's own width decides scroll range and centring, so rebuild once it changes.
        let lyricsSizeChanged = bounds.width != oldLyricsWidth

        let y = (bounds.height - Self.controlSize) / 2
        let count = CGFloat(controlIcons.count)
        let groupWidth = count * Self.controlSize + (count - 1) * Self.controlSpacing
        var x = (bounds.width - groupWidth) / 2
        for icon in controlIcons {
            icon.frame = NSRect(x: x, y: y, width: Self.controlSize, height: Self.controlSize)
            x += Self.controlSize + Self.controlSpacing
        }

        if lyricsSizeChanged {
            rebuildAnimation()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = bounds.width
        super.setFrameSize(newSize)
        guard newSize.width != oldWidth else { return }
        needsLayout = true
    }

    // MARK: - Hit resolution

    /// Claim every click inside the item. Resolving the region ourselves avoids depending on
    /// AppKit's subview routing inside the status bar button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private func region(at point: NSPoint) -> Region? {
        guard bounds.contains(point) else { return nil }
        // Without lyrics the whole item is the logo.
        guard showsLyrics else { return .menu }
        guard isHovering else { return nil }
        for (index, icon) in controlIcons.enumerated() where icon.frame.contains(point) {
            switch index {
            case 0: return .prev
            case 1: return .playPause
            default: return .next
            }
        }
        return nil
    }

    /// Cursor position in this view's coordinates, taken from the real cursor rather than the
    /// event. On macOS 27 the status item reports every click at the item's centre — the event's
    /// own `locationInWindow` is unusable — while `NSEvent.mouseLocation` stays accurate.
    private func cursorLocation() -> NSPoint? {
        guard let win = window else { return nil }
        return convert(win.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    private func regionUnderCursor() -> Region? {
        cursorLocation().flatMap(region(at:))
    }

    // MARK: - Press handling

    private func setHighlight(_ region: Region?) {
        highlightToken += 1
        logoView.setPressed(region == .menu)
        prevButton.setPressed(region == .prev)
        playPauseButton.setPressed(region == .playPause)
        nextButton.setPressed(region == .next)
    }

    /// Clears the highlight once it has been visible for the minimum duration.
    private func releaseHighlight() {
        let remaining = Self.minimumHighlightDuration - (CACurrentMediaTime() - pressBeganAt)
        guard remaining > 0 else {
            setHighlight(nil)
            return
        }
        let token = highlightToken
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
            // A newer press owns the highlight by now; leave it alone.
            guard let self, self.highlightToken == token else { return }
            self.setHighlight(nil)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Control-click is the same gesture as a right-click.
        guard !event.modifierFlags.contains(.control) else {
            onMenu?()
            return
        }
        pressedRegion = regionUnderCursor()
        pressBeganAt = CACurrentMediaTime()
        setHighlight(pressedRegion)
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed = pressedRegion else { return }
        // Like a standard button: highlighted only while the cursor is still inside it.
        setHighlight(regionUnderCursor() == pressed ? pressed : nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed = pressedRegion else { return }
        pressedRegion = nil
        guard regionUnderCursor() == pressed else {
            setHighlight(nil)
            return
        }

        // The menu is the exception: it tracks in a nested run loop and is its own
        // acknowledgement, so its icon must not sit dimmed underneath it.
        setHighlight(pressed == .menu ? nil : pressed)
        switch pressed {
        case .menu: onMenu?()
        case .prev: onPrev?()
        case .playPause: onPlayPause?()
        case .next: onNext?()
        }
        releaseHighlight()
    }

    // MARK: - Animation timer

    /// `LyricsAnimationLayer` advances by repeated `tick()` calls rather than by Core Animation,
    /// so the scrolling and karaoke mask only move while this timer is running.
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
        if showsLyrics && animationLayer.needsTicks && isPlaying && !isHovering {
            startAnimTimer()
        } else {
            stopAnimTimer()
        }
    }

    // MARK: - Drift detection

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

    // MARK: - Tracking area + hover

    private func updateTrackingArea() {
        if let old = trackingArea { removeTrackingArea(old) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        controlIcons.forEach { $0.isHidden = !showsLyrics }
        updateLyricsVisibility()
        updateAnimTimer()
        needsLayout = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        pressedRegion = nil
        setHighlight(nil)
        controlIcons.forEach { $0.isHidden = true }
        updateLyricsVisibility()
        rebuildAnimation()
    }
}
