import AppKit
import QuartzCore

final class LyricsAnimationLayer: CALayer {

    var karaokeEnabled: Bool = true

    var edgeFadeWidth: CGFloat = 36

    var renderAppearance: NSAppearance?

    // MARK: - State

    private(set) var isAnimating: Bool = false

    // MARK: - Sublayers

    private var textImageLayer: CALayer?
    private var dimImageLayer: CALayer?
    private var brightImageLayer: CALayer?
    private var karaokeMask: CALayer?
    private var edgeFadeMask: CAGradientLayer?

    // MARK: - Text cache

    private var cachedText: String = ""
    private var cachedTextSize: NSSize = .zero
    private var cachedWordWidths: [CGFloat] = []

    // MARK: - Timer-driven animation state

    private var animStartTime: CFTimeInterval = 0
    private var animDuration: TimeInterval = 0
    private var isFrozen: Bool = false
    private var frozenElapsed: TimeInterval = 0

    /// Scroll keyframes for position.x (used by text/dim/bright layers).
    private var scrollValues: [CGFloat] = []
    private var scrollKeyTimes: [Double] = []
    /// Segment index that uses easeInEaseOut (nil = all linear).
    private var scrollEaseSegment: Int?

    /// Karaoke mask width keyframes.
    private var karaokeValues: [CGFloat] = []
    private var karaokeKeyTimes: [Double] = []

    /// Edge fade: per-stop alpha keyframes (only stop 0 and stop 3 change).
    private var edgeFadeLeftAlphas: [CGFloat] = []
    private var edgeFadeRightAlphas: [CGFloat] = []
    private var edgeFadeKeyTimes: [Double] = []

    // MARK: - Drift detection anchors

    /// Playback position (seconds) when the animation was built.
    private(set) var anchorPosition: TimeInterval = 0
    /// System time (`CACurrentMediaTime()`) when the animation was built.
    private(set) var anchorWallTime: CFTimeInterval = 0

    // MARK: - Constants

    private let font: NSFont = .systemFont(ofSize: 14)
    private let scale: CGFloat = 2.0

    // MARK: - Public API

    /// Builds or rebuilds the animation. Safe to call repeatedly — tears down old layers each time.
    func update(text: String, line: LyricLine?, position: TimeInterval, playing: Bool) {
        if text != cachedText {
            cachedText = text
            cachedTextSize = (text as NSString).size(withAttributes: [.font: font])
        }

        teardownSublayers()

        let hasValidLine = line != nil && line!.endTime > line!.time

        if hasValidLine, let line = line {
            anchorPosition = position
            anchorWallTime = CACurrentMediaTime()
            buildAnimations(line: line, position: position)
            isAnimating = true
            if !playing { freeze() }
            tick()
        } else {
            buildStaticLayer()
            isAnimating = false
        }
    }

    /// Freezes all animations at their current visual position (called on pause).
    func freeze() {
        guard !isFrozen else { return }
        frozenElapsed = CACurrentMediaTime() - animStartTime
        isFrozen = true
    }

    /// Resumes animations from the frozen position (called on play).
    func unfreeze() {
        guard isFrozen else { return }
        animStartTime = CACurrentMediaTime() - frozenElapsed
        isFrozen = false
    }

    /// Advances the animation to the current time and sets layer properties directly.
    /// Called externally by a timer to drive rendering on all displays.
    func tick() {
        guard isAnimating, animDuration > 0 else { return }

        let elapsed: TimeInterval
        if isFrozen {
            elapsed = frozenElapsed
        } else {
            elapsed = CACurrentMediaTime() - animStartTime
        }

        let t = min(1, max(0, elapsed / animDuration))

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        if !scrollValues.isEmpty {
            let x = interpolate(values: scrollValues, keyTimes: scrollKeyTimes,
                                at: t, easeSegment: scrollEaseSegment)
            textImageLayer?.position.x = x
            dimImageLayer?.position.x = x
            brightImageLayer?.position.x = x
        }

        if !karaokeValues.isEmpty {
            karaokeMask?.bounds.size.width = interpolate(
                values: karaokeValues, keyTimes: karaokeKeyTimes, at: t)
        }

        if !edgeFadeKeyTimes.isEmpty, let fade = edgeFadeMask {
            let leftA = interpolate(values: edgeFadeLeftAlphas,
                                    keyTimes: edgeFadeKeyTimes, at: t)
            let rightA = interpolate(values: edgeFadeRightAlphas,
                                     keyTimes: edgeFadeKeyTimes, at: t)
            let solid = NSColor.black.cgColor
            fade.colors = [
                NSColor.black.withAlphaComponent(leftA).cgColor,
                solid, solid,
                NSColor.black.withAlphaComponent(rightA).cgColor
            ]
        }

        CATransaction.commit()
    }

    // MARK: - Animation Construction

    private func buildAnimations(line: LyricLine, position: TimeInterval) {
        let size = cachedTextSize
        guard size.width > 0, size.height > 0 else { return }

        let karaoke = karaokeEnabled && !line.words.isEmpty
        let duration = line.endTime - line.time
        let elapsed = max(0, min(position - line.time, duration))
        let needsScroll = size.width > bounds.width
        let y = (bounds.height - size.height) / 2
        let origin = CGPoint(x: needsScroll ? 0 : (bounds.width - size.width) / 2, y: y)

        animDuration = duration
        animStartTime = CACurrentMediaTime() - elapsed

        // Build content layers (karaoke dual-layer or plain single-layer)
        if karaoke {
            buildKaraokeLayers(line: line, size: size, origin: origin, duration: duration)
        } else {
            textImageLayer = addImageLayer(renderTextImage(), size: size, origin: origin)
        }

        // Store scroll & edge-fade keyframes when text overflows
        if needsScroll {
            let times = computeScrollTimes(karaoke: karaoke, line: line,
                                           textWidth: size.width, duration: duration)
            if karaoke {
                storeHighlightFollowScroll(line: line, textWidth: size.width, duration: duration)
            } else {
                storeScrollKeyframes(textWidth: size.width, startT: times.start, endT: times.end)
            }
            storeEdgeFade(scrollStart: times.start, scrollEnd: times.end, duration: duration)
        }
    }

    /// Static text layer for non-animated content.
    private func buildStaticLayer() {
        let size = cachedTextSize
        guard size.width > 0, size.height > 0 else { return }
        let x = size.width <= bounds.width ? (bounds.width - size.width) / 2 : 0
        let y = (bounds.height - size.height) / 2
        textImageLayer = addImageLayer(renderTextImage(), size: size, origin: CGPoint(x: x, y: y))
    }

    // MARK: - Karaoke Layers

    private func buildKaraokeLayers(
        line: LyricLine, size: NSSize, origin: CGPoint, duration: TimeInterval
    ) {
        // Cache per-word widths, scaled proportionally to correct for kerning
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let rawWidths = line.words.map { (($0.text) as NSString).size(withAttributes: attrs).width }
        let rawSum = rawWidths.reduce(0, +)
        let ratio = rawSum > 0 ? size.width / rawSum : 1.0
        cachedWordWidths = rawWidths.map { $0 * ratio }

        // Dim layer (unsung portion, alpha 0.45)
        dimImageLayer = addImageLayer(renderTextImage(dimAlpha: 0.45), size: size, origin: origin)

        // Bright layer + mask (sung portion, mask width expands word-by-word)
        let brightLayer = addImageLayer(renderTextImage(), size: size, origin: origin)
        let kMask = CALayer()
        kMask.backgroundColor = NSColor.white.cgColor
        kMask.anchorPoint = CGPoint(x: 0, y: 0.5)
        kMask.position = CGPoint(x: 0, y: size.height / 2)
        kMask.bounds = CGRect(x: 0, y: 0, width: 0, height: size.height)
        brightLayer.mask = kMask
        karaokeMask = kMask
        brightImageLayer = brightLayer

        storeKaraokeKeyframes(line: line, duration: duration)
    }

    // MARK: - Scroll Keyframes

    /// Computes scroll start/end times as a fraction of the lyric line duration.
    private func computeScrollTimes(
        karaoke: Bool, line: LyricLine?, textWidth: CGFloat, duration: TimeInterval
    ) -> (start: Double, end: Double) {
        if karaoke, let line = line {
            let center = bounds.width * 0.5
            var accWidth: CGFloat = 0, startT: Double = 0, endT: Double = 1
            var foundStart = false
            for (i, word) in line.words.enumerated() {
                accWidth += cachedWordWidths[i]
                let t = min(1.0, (word.end - line.time) / duration)
                if !foundStart && accWidth >= center { startT = t; foundStart = true }
                if accWidth >= textWidth - center { endT = min(1.0, t); break }
            }
            return (startT, max(endT, startT + 0.03))
        } else {
            let lr: CGFloat = 0.65
            let s = Double(min(0.85, bounds.width * lr / textWidth))
            let e = max(s + 0.05, 1.0 - Double(bounds.width * (1 - lr) / textWidth))
            return (s, e)
        }
    }

    /// Non-karaoke scroll: hold → easeInEaseOut scroll → hold.
    private func storeScrollKeyframes(textWidth: CGFloat, startT: Double, endT: Double) {
        let maxScroll = textWidth - bounds.width
        scrollValues = [0, 0, -maxScroll, -maxScroll]
        scrollKeyTimes = [0, startT, endT, 1]
        scrollEaseSegment = 1  // segment between keyTimes[1] and keyTimes[2]
    }

    /// Karaoke scroll: tracks the highlight position word-by-word.
    private func storeHighlightFollowScroll(
        line: LyricLine, textWidth: CGFloat, duration: TimeInterval
    ) {
        let maxScroll = textWidth - bounds.width
        let center = bounds.width * 0.5

        var values: [CGFloat] = [0]
        var keyTimes: [Double] = [0]
        var accWidth: CGFloat = 0
        var lastT: Double = 0

        for (i, word) in line.words.enumerated() {
            let wordW = cachedWordWidths[i]
            let t1 = max(0, (word.begin - line.time) / duration)
            let t2 = min(1, (word.end - line.time) / duration)

            if t1 > lastT {
                let offset = min(maxScroll, max(0, accWidth - center))
                keyTimes.append(t1)
                values.append(-offset)
                lastT = t1
            }

            accWidth += wordW

            if t2 > lastT {
                let offset = min(maxScroll, max(0, accWidth - center))
                keyTimes.append(t2)
                values.append(-offset)
                lastT = t2
            }
        }

        if lastT < 1 {
            keyTimes.append(1)
            values.append(-maxScroll)
        }

        scrollValues = values
        scrollKeyTimes = keyTimes
        scrollEaseSegment = nil  // all linear
    }

    // MARK: - Karaoke Mask Keyframes

    private func storeKaraokeKeyframes(line: LyricLine, duration: TimeInterval) {
        guard !line.words.isEmpty else { return }

        var values: [CGFloat] = [], keyTimes: [Double] = []
        var accWidth: CGFloat = 0, lastT: Double = -1

        for (i, word) in line.words.enumerated() {
            let wordW = cachedWordWidths[i]
            let t1 = max(0, (word.begin - line.time) / duration)
            let t2 = min(1, (word.end - line.time) / duration)
            if t1 > lastT { keyTimes.append(t1); values.append(accWidth); lastT = t1 }
            accWidth += wordW
            if t2 > lastT { keyTimes.append(t2); values.append(accWidth); lastT = t2 }
        }

        if keyTimes.isEmpty || keyTimes.first! > 0 {
            keyTimes.insert(0, at: 0); values.insert(0, at: 0)
        }
        if keyTimes.last! < 1 { keyTimes.append(1); values.append(accWidth) }

        karaokeValues = values
        karaokeKeyTimes = keyTimes
    }

    // MARK: - Edge Fade

    /// Sets up the gradient mask layer and stores alpha keyframes for tick-based updates.
    private func storeEdgeFade(scrollStart: Double, scrollEnd: Double, duration: TimeInterval) {
        let fade = CAGradientLayer()
        fade.frame = bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)

        let inset = Double(edgeFadeWidth / bounds.width)
        fade.locations = [0, NSNumber(value: inset), NSNumber(value: 1 - inset), 1]

        let solid = NSColor.black.cgColor
        fade.colors = [solid, solid, solid, NSColor.clear.cgColor]
        fade.cornerRadius = cornerRadius

        mask = fade
        edgeFadeMask = fade

        // Compute alpha keyframes for left (stop 0) and right (stop 3).
        // noLeft  = left:1, right:0
        // both    = left:0, right:0
        // noRight = left:0, right:1
        let desiredTr = 0.75 / duration
        let ahead = 0.15 / duration
        let leftTr = min(desiredTr, scrollStart + ahead)
        let rightTr = min(desiredTr, 1 - scrollEnd + ahead)

        edgeFadeKeyTimes = [
            0,
            max(0, scrollStart - leftTr),
            max(0, scrollStart - ahead),
            min(1, scrollEnd - ahead),
            min(1, scrollEnd + rightTr - ahead),
            1
        ]
        edgeFadeLeftAlphas  = [1, 1, 0, 0, 0, 0]
        edgeFadeRightAlphas = [0, 0, 0, 0, 1, 1]
    }

    // MARK: - Interpolation

    /// Linearly interpolates a keyframe animation, with optional easeInEaseOut on one segment.
    private func interpolate(
        values: [CGFloat], keyTimes: [Double], at t: Double, easeSegment: Int? = nil
    ) -> CGFloat {
        guard values.count >= 2, values.count == keyTimes.count else { return values.first ?? 0 }
        let clamped = max(0, min(1, t))

        for i in 1..<keyTimes.count {
            if clamped <= keyTimes[i] {
                let t0 = keyTimes[i - 1]
                let t1 = keyTimes[i]
                let segLen = t1 - t0
                guard segLen > 0 else { return values[i] }
                var local = (clamped - t0) / segLen
                if let seg = easeSegment, (i - 1) == seg {
                    local = local * local * (3 - 2 * local)  // smoothstep
                }
                return values[i - 1] + CGFloat(local) * (values[i] - values[i - 1])
            }
        }
        return values.last ?? 0
    }

    // MARK: - Text Rendering

    /// Rasterizes text into a bitmap (`CGImage`).
    /// Off-screen rendering requires manually setting the appearance context via `renderAppearance`.
    private func renderTextImage(dimAlpha: CGFloat? = nil) -> CGImage? {
        let size = cachedTextSize
        let pw = Int(ceil(size.width * scale)), ph = Int(ceil(size.height * scale))
        guard pw > 0, ph > 0 else { return nil }

        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: pw, height: ph,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: info) else { return nil }

        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ctx.scaleBy(x: scale, y: scale)

        let appearance = renderAppearance ?? NSAppearance(named: .aqua)!
        appearance.performAsCurrentDrawingAppearance {
            let resolved = NSColor(cgColor: NSColor.labelColor.cgColor) ?? .labelColor
            let color = resolved.withAlphaComponent(dimAlpha ?? 1.0)
            let attrs: [NSAttributedString.Key: Any] = [.font: self.font, .foregroundColor: color]
            (self.cachedText as NSString).draw(at: .zero, withAttributes: attrs)
        }

        NSGraphicsContext.current = saved
        return ctx.makeImage()
    }

    // MARK: - Helpers

    @discardableResult
    private func addImageLayer(_ image: CGImage?, size: NSSize, origin: CGPoint) -> CALayer {
        let l = CALayer()
        l.contents = image
        l.contentsScale = scale
        l.anchorPoint = .zero
        l.frame = CGRect(origin: origin, size: size)
        addSublayer(l)
        return l
    }

    /// Tears down all sublayers and resets state.
    private func teardownSublayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        [textImageLayer, dimImageLayer, brightImageLayer].forEach { $0?.removeFromSuperlayer() }
        mask = nil
        CATransaction.commit()

        textImageLayer = nil; dimImageLayer = nil; brightImageLayer = nil
        karaokeMask = nil; edgeFadeMask = nil
        cachedWordWidths = []
        isAnimating = false

        // Reset animation descriptors
        scrollValues = []; scrollKeyTimes = []; scrollEaseSegment = nil
        karaokeValues = []; karaokeKeyTimes = []
        edgeFadeLeftAlphas = []; edgeFadeRightAlphas = []; edgeFadeKeyTimes = []
    }
}
