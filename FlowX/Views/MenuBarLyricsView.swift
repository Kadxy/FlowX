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

    // Pre-cached SF Symbol images
    private let iconConfig = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        .applying(.init(hierarchicalColor: .labelColor))
    private lazy var prevImage = NSImage(
        systemSymbolName: "backward.end.fill", accessibilityDescription: nil
    )?.withSymbolConfiguration(iconConfig)
    private lazy var playImage = NSImage(
        systemSymbolName: "play.fill", accessibilityDescription: nil
    )?.withSymbolConfiguration(iconConfig)
    private lazy var pauseImage = NSImage(
        systemSymbolName: "pause.fill", accessibilityDescription: nil
    )?.withSymbolConfiguration(iconConfig)
    private lazy var nextImage = NSImage(
        systemSymbolName: "forward.end.fill", accessibilityDescription: nil
    )?.withSymbolConfiguration(iconConfig)

    var onPrev: (() -> Void)?
    var onPlayPause: (() -> Void)?
    var onNext: (() -> Void)?

    var isPlaying: Bool = false {
        didSet {
            guard isPlaying != oldValue else { return }
            if isHovering { needsDisplay = true }
            rebuildIfNeeded()
        }
    }

    var font: NSFont = NSFont.systemFont(ofSize: 14) {
        didSet {
            cachedTextSize = (currentText as NSString).size(withAttributes: [.font: font])
            teardownLayers()
            needsDisplay = true
            rebuildIfNeeded()
        }
    }

    var text: String {
        get { currentText }
        set {
            guard newValue != currentText else { return }
            currentText = newValue
            cachedTextSize = (newValue as NSString).size(withAttributes: [.font: font])
            teardownLayers()
            needsDisplay = true
            rebuildIfNeeded()
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

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = bounds.width
        super.setFrameSize(newSize)
        guard newSize.width != oldWidth else { return }
        teardownLayers()
        needsDisplay = true
        rebuildIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshLayers()
    }

    func refreshLayers() {
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
        for l in [textImageLayer, dimImageLayer, brightImageLayer, karaokeMask].compactMap({ $0 }) {
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
        let startX = needsScroll ? 0 : (bounds.width - size.width) / 2
        let origin = CGPoint(x: startX, y: y)

        isLayerMode = true

        if karaoke {
            setupKaraokeLayers(parent: parentLayer, line: line, size: size, origin: origin,
                               scale: scale, duration: duration, elapsed: elapsed, needsScroll: needsScroll)
        } else {
            setupSingleLayer(parent: parentLayer, size: size, origin: origin,
                             scale: scale, duration: duration, elapsed: elapsed, needsScroll: needsScroll)
        }
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
        textImageLayer?.removeFromSuperlayer(); textImageLayer = nil
        dimImageLayer?.removeFromSuperlayer(); dimImageLayer = nil
        brightImageLayer?.removeFromSuperlayer(); brightImageLayer = nil
        karaokeMask = nil
        cachedWordWidths = []
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
            var color: NSColor = .labelColor
            if let dimAlpha {
                color = NSColor(cgColor: NSColor.labelColor.cgColor)?.withAlphaComponent(dimAlpha)
                    ?? .labelColor
            }
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
            drawControls()
        } else if isLayerMode {
            NSGraphicsContext.current?.cgContext.clear(dirtyRect)
            setLayersHidden(false)
        } else {
            drawStaticLyrics()
        }
    }

    private func setLayersHidden(_ hidden: Bool) {
        textImageLayer?.isHidden = hidden
        dimImageLayer?.isHidden = hidden
        brightImageLayer?.isHidden = hidden
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

    private func drawControls() {
        let images = [prevImage, isPlaying ? pauseImage : playImage, nextImage]
        let iconH: CGFloat = 14, gap: CGFloat = 20
        let totalW = CGFloat(images.count) * iconH + CGFloat(images.count - 1) * gap
        var x = (bounds.width - totalW) / 2
        let y = (bounds.height - iconH) / 2

        for img in images {
            guard let img else { continue }
            img.draw(in: NSRect(x: x, y: y, width: iconH, height: iconH))
            x += iconH + gap
        }
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
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
        rebuildIfNeeded()
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
