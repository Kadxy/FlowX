import AppKit
import QuartzCore

final class MenuBarLyricsView: NSView {
    private var currentText = ""
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private var cachedTextSize: NSSize = .zero
    private var cachedWordWidths: [CGFloat] = []

    private let mc = MusicController.shared

    // Pre-rendered layers for smooth GPU-animated scrolling & karaoke
    private var textImageLayer: CALayer?
    private var dimImageLayer: CALayer?
    private var brightImageLayer: CALayer?
    private var karaokeMask: CALayer?
    private var isLayerMode = false
    private var edgeFadeLayer: CAGradientLayer?
    private var edgeFadeWidth: CGFloat { CGFloat(AppSettings.shared.menuBarEdgeFadeWidth) }

    // Anchor recorded at animation build time — used to detect drift (seek / stale resume)
    private var anchorPosition: TimeInterval = 0
    private var anchorWallTime: CFTimeInterval = 0
    private var anchorLineTime: TimeInterval = 0

    // Pre-cached SF Symbol images
    private let iconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        .applying(.init(hierarchicalColor: .labelColor))

    private func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
    }

    // Control buttons (real NSButton for native press tracking)
    private lazy var prevButton = makeControlButton("backward.end.fill", action: #selector(prevTapped))
    private lazy var playPauseButton = makeControlButton("play.fill", action: #selector(playPauseTapped))
    private lazy var nextButton = makeControlButton("forward.end.fill", action: #selector(nextTapped))
    private lazy var controlButtons = [prevButton, playPauseButton, nextButton]

    var onPrev: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?

    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            playPauseButton.image = symbol(isPlaying ? "pause.fill" : "play.fill")
            rebuildIfNeeded()
        }
    }

    var font: NSFont = NSFont.systemFont(ofSize: 14) {
        didSet {
            cachedTextSize = (currentText as NSString).size(withAttributes: [.font: font])
            invalidateAndRebuild()
        }
    }

    var text: String {
        get { currentText }
        set {
            guard newValue != currentText else { return }
            currentText = newValue
            cachedTextSize = (newValue as NSString).size(withAttributes: [.font: font])
            invalidateAndRebuild()
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
        setupControlButtons()
        updateTrackingArea()
    }

    private func makeControlButton(_ symbolName: String, action: Selector) -> NSButton {
        let btn = NSButton()
        btn.image = symbol(symbolName)
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

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = bounds.width
        super.setFrameSize(newSize)
        guard newSize.width != oldWidth else { return }
        invalidateAndRebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayers()
    }

    func refreshLayers() {
        invalidateAndRebuild()
    }

    /// Called every poll (0.5s) — rebuilds animations only when position drifted from expectation.
    func syncIfNeeded() {
        guard isLayerMode,
              let line = mc.currentLine,
              line.time == anchorLineTime else { return }

        let drift: Double
        if isPlaying {
            // Playing: position should advance with wall clock
            let expected = anchorPosition + (CACurrentMediaTime() - anchorWallTime)
            drift = abs(mc.playerPosition - expected)
        } else {
            // Paused: position should stay where we froze
            drift = abs(mc.playerPosition - anchorPosition)
        }
        guard drift > 0.2 else { return }

        print("[FlowX] Animation drift \(String(format: "%.2f", drift))s — rebuilding")
        invalidateAndRebuild()
    }

    private func invalidateAndRebuild() {
        teardownLayers()
        needsDisplay = true
        rebuildIfNeeded()
    }

    // MARK: - Rebuild decision

    private func rebuildIfNeeded() {
        let line = mc.currentLine
        let needsScroll = cachedTextSize.width > bounds.width && line != nil
        let needsKaraoke = AppSettings.shared.menuBarKaraoke && line != nil && !line!.words.isEmpty
        let hasValidLine = line != nil && line!.endTime > line!.time
        let wantsLayers = !isHovering && (needsScroll || needsKaraoke || hasValidLine)

        if wantsLayers {
            if isPlaying {
                setupLayersAndAnimations()
            } else if isLayerMode {
                freezeAnimations()
            } else {
                setupLayersAndAnimations()
                freezeAnimations()
            }
        } else if isLayerMode {
            teardownLayers()
            needsDisplay = true
        }
    }

    private func freezeAnimations() {
        for l in [textImageLayer, dimImageLayer, brightImageLayer, karaokeMask, edgeFadeLayer].compactMap({ $0 }) {
            guard l.speed != 0 else { continue }
            let pausedTime = l.convertTime(CACurrentMediaTime(), from: nil)
            l.speed = 0
            l.timeOffset = pausedTime
        }
    }

    // MARK: - Layer setup + CA Animations (zero CPU during playback)

    private func setupLayersAndAnimations() {
        teardownLayers()
        guard let parentLayer = layer else { return }
        guard let line = mc.currentLine, line.endTime > line.time else { return }

        let scale = window?.backingScaleFactor ?? 2.0
        let size = cachedTextSize
        guard size.width > 0, size.height > 0 else { return }

        let karaoke = AppSettings.shared.menuBarKaraoke && !line.words.isEmpty
        let y = (bounds.height - size.height) / 2
        let duration = line.endTime - line.time
        let elapsed = max(0, min(mc.playerPosition - line.time, duration))
        let needsScroll = size.width > bounds.width
        let startX: CGFloat = needsScroll ? 0 : (bounds.width - size.width) / 2
        let origin = CGPoint(x: startX, y: y)

        isLayerMode = true

        // Record anchor for drift detection
        anchorPosition = mc.playerPosition
        anchorWallTime = CACurrentMediaTime()
        anchorLineTime = line.time

        if karaoke {
            setupKaraokeLayers(parent: parentLayer, line: line, size: size, origin: origin,
                               scale: scale, duration: duration, elapsed: elapsed, needsScroll: needsScroll)
        } else {
            setupSingleLayer(parent: parentLayer, size: size, origin: origin,
                             scale: scale, duration: duration, elapsed: elapsed, needsScroll: needsScroll)
        }

        if needsScroll {
            let scrollTimes: (start: Double, end: Double)
            if karaoke {
                scrollTimes = scrollTimesForKaraoke(line: line, textWidth: size.width, duration: duration)
            } else {
                let lr: CGFloat = 0.65
                let s = Double(min(0.85, bounds.width * lr / size.width))
                let e = max(s + 0.05, 1.0 - Double(bounds.width * (1 - lr) / size.width))
                scrollTimes = (s, e)
            }
            setupEdgeFade(on: parentLayer, scrollStart: scrollTimes.start,
                          scrollEnd: scrollTimes.end, duration: duration, elapsed: elapsed)
        }
    }

    private func scrollTimesForKaraoke(line: LyricLine, textWidth: CGFloat, duration: TimeInterval) -> (start: Double, end: Double) {
        let leadEdge = bounds.width * 0.65, trailEdge = bounds.width * 0.35
        var accWidth: CGFloat = 0, startT: Double = 0, endT: Double = 1
        var foundStart = false
        for (i, word) in line.words.enumerated() {
            accWidth += cachedWordWidths[i]
            let t = min(1.0, (word.end - line.time) / duration)
            if !foundStart && accWidth >= leadEdge { startT = t; foundStart = true }
            if accWidth >= textWidth - trailEdge { endT = min(1.0, t); break }
        }
        return (startT, max(endT, startT + 0.03))
    }

    private func setupEdgeFade(on parentLayer: CALayer, scrollStart: Double, scrollEnd: Double,
                                duration: TimeInterval, elapsed: TimeInterval) {
        let fade = CAGradientLayer()
        fade.frame = parentLayer.bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)

        let inset = Double(edgeFadeWidth / bounds.width)
        fade.colors = [NSColor.clear, .black, .black, .clear].map(\.cgColor)
        fade.locations = [0, 0, NSNumber(value: 1 - inset), 1]

        let noLeft:  [NSNumber] = [0, 0, NSNumber(value: 1 - inset), 1]
        let both:    [NSNumber] = [0, NSNumber(value: inset), NSNumber(value: 1 - inset), 1]
        let noRight: [NSNumber] = [0, NSNumber(value: inset), 1, 1]

        // 0.3s 过渡，限制在滚动窗口的 1/3 以内
        let tr = min(0.3 / duration, (scrollEnd - scrollStart) / 3)

        let anim = CAKeyframeAnimation(keyPath: "locations")
        anim.values = [noLeft, noLeft, both, both, noRight, noRight]
        anim.keyTimes = [0,
                         NSNumber(value: scrollStart),
                         NSNumber(value: scrollStart + tr),
                         NSNumber(value: scrollEnd - tr),
                         NSNumber(value: scrollEnd),
                         1]
        anim.duration = duration
        anim.calculationMode = .linear
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        anim.beginTime = CACurrentMediaTime() - elapsed
        fade.add(anim, forKey: "edgeFade")
        fade.cornerRadius = parentLayer.cornerRadius

        parentLayer.mask = fade
        edgeFadeLayer = fade
    }

    private func setupKaraokeLayers(
        parent: CALayer, line: LyricLine, size: NSSize, origin: CGPoint,
        scale: CGFloat, duration: TimeInterval, elapsed: TimeInterval, needsScroll: Bool
    ) {
        // Cache word widths, scaled to match total text width (kerning correction)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let rawWidths = line.words.map { (($0.text) as NSString).size(withAttributes: attrs).width }
        let rawSum = rawWidths.reduce(0, +)
        let ratio = rawSum > 0 ? size.width / rawSum : 1.0
        cachedWordWidths = rawWidths.map { $0 * ratio }

        let dimCG = renderTextImage(dimAlpha: 0.45, scale: scale)
        let dimLayer = makeImageLayer(image: dimCG, size: size, origin: origin, scale: scale)
        parent.addSublayer(dimLayer)
        dimImageLayer = dimLayer

        let brightCG = renderTextImage(scale: scale)
        let brightLayer = makeImageLayer(image: brightCG, size: size, origin: origin, scale: scale)
        let mask = CALayer()
        mask.backgroundColor = NSColor.white.cgColor
        mask.anchorPoint = CGPoint(x: 0, y: 0.5)
        mask.position = CGPoint(x: 0, y: size.height / 2)
        mask.bounds = CGRect(x: 0, y: 0, width: 0, height: size.height)
        brightLayer.mask = mask
        karaokeMask = mask
        parent.addSublayer(brightLayer)
        brightImageLayer = brightLayer

        addKaraokeAnimation(line: line, duration: duration, elapsed: elapsed)

        if needsScroll {
            let anim = makeHighlightFollowScroll(
                line: line, textWidth: size.width, duration: duration, elapsed: elapsed
            )
            dimLayer.add(anim, forKey: "scroll")
            if let copy = anim.copy() as? CAAnimation {
                brightLayer.add(copy, forKey: "scroll")
            }
        }
    }

    private func setupSingleLayer(
        parent: CALayer, size: NSSize, origin: CGPoint,
        scale: CGFloat, duration: TimeInterval, elapsed: TimeInterval, needsScroll: Bool
    ) {
        let cg = renderTextImage(scale: scale)
        let textLayer = makeImageLayer(image: cg, size: size, origin: origin, scale: scale)
        parent.addSublayer(textLayer)
        textImageLayer = textLayer

        if needsScroll {
            textLayer.add(
                makeScrollAnimation(textWidth: size.width, duration: duration, elapsed: elapsed),
                forKey: "scroll"
            )
        }
    }

    private func makeImageLayer(image: CGImage?, size: NSSize, origin: CGPoint, scale: CGFloat) -> CALayer {
        let l = CALayer()
        l.contents = image
        l.contentsScale = scale
        l.anchorPoint = .zero
        l.frame = CGRect(origin: origin, size: size)
        return l
    }

    // MARK: - Scroll animations

    private func makeScrollAnimation(
        textWidth: CGFloat, duration: TimeInterval, elapsed: TimeInterval
    ) -> CAKeyframeAnimation {
        let leadRatio: CGFloat = 0.65
        let startRatio = min(0.85, bounds.width * leadRatio / textWidth)
        let endRatio = max(startRatio + 0.05, 1.0 - bounds.width * (1 - leadRatio) / textWidth)
        return makeScrollKeyframes(textWidth: textWidth, duration: duration, elapsed: elapsed,
                                   startT: startRatio, endT: endRatio)
    }

    private func makeHighlightFollowScroll(
        line: LyricLine, textWidth: CGFloat, duration: TimeInterval, elapsed: TimeInterval
    ) -> CAKeyframeAnimation {
        let leadRatio: CGFloat = 0.65
        let leadEdge = bounds.width * leadRatio, trailEdge = bounds.width * (1 - leadRatio)
        var accWidth: CGFloat = 0, scrollStartT: Double = 0, scrollEndT: Double = 1
        var foundStart = false

        for (i, word) in line.words.enumerated() {
            accWidth += cachedWordWidths[i]
            let t = min(1.0, (word.end - line.time) / duration)
            if !foundStart && accWidth >= leadEdge { scrollStartT = t; foundStart = true }
            if accWidth >= textWidth - trailEdge { scrollEndT = min(1.0, t); break }
        }
        scrollEndT = max(scrollEndT, scrollStartT + 0.03)
        return makeScrollKeyframes(textWidth: textWidth, duration: duration, elapsed: elapsed,
                                   startT: scrollStartT, endT: scrollEndT)
    }

    private func makeScrollKeyframes(
        textWidth: CGFloat, duration: TimeInterval, elapsed: TimeInterval, startT: Double, endT: Double
    ) -> CAKeyframeAnimation {
        let anim = CAKeyframeAnimation(keyPath: "position.x")
        let maxScroll = textWidth - bounds.width
        anim.values = [0, 0, -maxScroll, -maxScroll] as [CGFloat]
        anim.keyTimes = [0, NSNumber(value: startT), NSNumber(value: endT), 1]
        anim.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear)
        ]
        anim.duration = duration
        anim.calculationMode = .linear
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        anim.beginTime = CACurrentMediaTime() - elapsed
        return anim
    }

    // MARK: - Karaoke mask animation

    private func addKaraokeAnimation(line: LyricLine, duration: TimeInterval, elapsed: TimeInterval) {
        guard let mask = karaokeMask, !line.words.isEmpty else { return }

        var values: [CGFloat] = [], keyTimes: [NSNumber] = []
        var accWidth: CGFloat = 0, lastT: Double = -1

        for (i, word) in line.words.enumerated() {
            let wordW = cachedWordWidths[i]
            let t1 = max(0, (word.begin - line.time) / duration)
            let t2 = min(1, (word.end - line.time) / duration)
            if t1 > lastT { keyTimes.append(NSNumber(value: t1)); values.append(accWidth); lastT = t1 }
            accWidth += wordW
            if t2 > lastT { keyTimes.append(NSNumber(value: t2)); values.append(accWidth); lastT = t2 }
        }

        if keyTimes.isEmpty || keyTimes.first!.doubleValue > 0 {
            keyTimes.insert(0, at: 0); values.insert(0, at: 0)
        }
        if keyTimes.last!.doubleValue < 1 { keyTimes.append(1); values.append(accWidth) }

        let anim = CAKeyframeAnimation(keyPath: "bounds.size.width")
        anim.values = values
        anim.keyTimes = keyTimes
        anim.duration = duration
        anim.calculationMode = .linear
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        anim.beginTime = CACurrentMediaTime() - elapsed
        mask.add(anim, forKey: "karaoke")
    }

    // MARK: - Layer lifecycle

    private func teardownLayers() {
        [textImageLayer, dimImageLayer, brightImageLayer].forEach { $0?.removeFromSuperlayer() }
        textImageLayer = nil; dimImageLayer = nil; brightImageLayer = nil
        karaokeMask = nil
        cachedWordWidths = []
        layer?.mask = nil
        edgeFadeLayer = nil
        isLayerMode = false
    }

    private func renderTextImage(dimAlpha: CGFloat? = nil, scale: CGFloat) -> CGImage? {
        let size = cachedTextSize
        let pw = Int(ceil(size.width * scale)), ph = Int(ceil(size.height * scale))
        guard pw > 0, ph > 0 else { return nil }

        let cs = window?.screen?.colorSpace?.cgColorSpace ?? CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: info) else { return nil }

        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: scale, y: scale)

        effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolved = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
            let color = resolved.withAlphaComponent(dimAlpha ?? 1.0)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            (currentText as NSString).draw(at: .zero, withAttributes: attrs)
        }

        NSGraphicsContext.current = saved
        return ctx.makeImage()
    }

    // MARK: - Drawing (static content + hover controls only)

    override func draw(_ dirtyRect: NSRect) {
        if isHovering {
            setLayersHidden(true)
        } else if isLayerMode {
            NSGraphicsContext.current?.cgContext.clear(dirtyRect)
            setLayersHidden(false)
        } else {
            drawStaticLyrics()
        }
    }

    private func setLayersHidden(_ hidden: Bool) {
        [textImageLayer, dimImageLayer, brightImageLayer].forEach { $0?.isHidden = hidden }
        layer?.mask = hidden ? nil : edgeFadeLayer
    }

    private func drawStaticLyrics() {
        let scale = window?.backingScaleFactor ?? 2.0
        guard let image = renderTextImage(scale: scale) else { return }
        let x = cachedTextSize.width <= bounds.width ? (bounds.width - cachedTextSize.width) / 2 : 0
        let y = (bounds.height - cachedTextSize.height) / 2
        NSImage(cgImage: image, size: cachedTextSize).draw(
            in: NSRect(x: x, y: y, width: cachedTextSize.width, height: cachedTextSize.height)
        )
    }

    // MARK: - Tracking area

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
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        controlButtons.forEach { $0.isHidden = true }
        needsDisplay = true
        rebuildIfNeeded()
    }
}
