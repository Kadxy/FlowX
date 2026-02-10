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
        } else {
            buildStaticLayer()
            isAnimating = false
        }
    }

    /// Freezes all animations at their current visual position (called on pause).
    func freeze() {
        let now = CACurrentMediaTime()
        for sub in allAnimatedLayers {
            guard sub.speed != 0 else { continue }
            let pausedTime = sub.convertTime(now, from: nil)
            sub.speed = 0
            sub.timeOffset = pausedTime
        }
    }

    /// Resumes animations from the frozen position (called on play).
    func unfreeze() {
        let now = CACurrentMediaTime()
        for sub in allAnimatedLayers {
            guard sub.speed == 0 else { continue }
            let pausedTime = sub.timeOffset
            sub.speed = 1
            sub.timeOffset = 0
            sub.beginTime = 0
            let timeSincePause = sub.convertTime(now, from: nil) - pausedTime
            sub.beginTime = timeSincePause
        }
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

        // Build content layers (karaoke dual-layer or plain single-layer)
        if karaoke {
            buildKaraokeLayers(line: line, size: size, origin: origin,
                               duration: duration, elapsed: elapsed)
        } else {
            textImageLayer = addImageLayer(renderTextImage(), size: size, origin: origin)
        }

        // Add scroll animation and edge fade when text overflows
        if needsScroll {
            let times = computeScrollTimes(karaoke: karaoke, line: line,
                                           textWidth: size.width, duration: duration)
            if karaoke, let dim = dimImageLayer, let bright = brightImageLayer {
                let anim = makeHighlightFollowScroll(line: line, textWidth: size.width,
                                                     duration: duration, elapsed: elapsed)
                dim.add(anim, forKey: "scroll")
                if let copy = anim.copy() as? CAAnimation {
                    bright.add(copy, forKey: "scroll")
                }
            } else if let text = textImageLayer {
                text.add(makeScrollAnimation(textWidth: size.width, duration: duration,
                                             elapsed: elapsed), forKey: "scroll")
            }
            buildEdgeFade(scrollStart: times.start, scrollEnd: times.end,
                          duration: duration, elapsed: elapsed)
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
        line: LyricLine, size: NSSize, origin: CGPoint,
        duration: TimeInterval, elapsed: TimeInterval
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

        addKaraokeAnimation(line: line, duration: duration, elapsed: elapsed)
    }

    // MARK: - Scroll Animation

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

    /// Non-karaoke scroll: starts scrolling when text reaches the 65% position.
    private func makeScrollAnimation(
        textWidth: CGFloat, duration: TimeInterval, elapsed: TimeInterval
    ) -> CAKeyframeAnimation {
        let leadRatio: CGFloat = 0.65
        let startRatio = min(0.85, bounds.width * leadRatio / textWidth)
        let endRatio = max(startRatio + 0.05, 1.0 - bounds.width * (1 - leadRatio) / textWidth)
        return makeScrollKeyframes(textWidth: textWidth, duration: duration, elapsed: elapsed,
                                   startT: startRatio, endT: endRatio)
    }

    /// Karaoke scroll: tracks the highlight position word-by-word, keeping the sung word near the center of the view.
    private func makeHighlightFollowScroll(
        line: LyricLine, textWidth: CGFloat, duration: TimeInterval, elapsed: TimeInterval
    ) -> CAKeyframeAnimation {
        let maxScroll = textWidth - bounds.width
        let center = bounds.width * 0.5

        var values: [CGFloat] = [0]
        var keyTimes: [NSNumber] = [0]
        var accWidth: CGFloat = 0
        var lastT: Double = 0

        for (i, word) in line.words.enumerated() {
            let wordW = cachedWordWidths[i]
            let t1 = max(0, (word.begin - line.time) / duration)
            let t2 = min(1, (word.end - line.time) / duration)

            // At word begin: highlight leading edge is at accWidth
            if t1 > lastT {
                let offset = min(maxScroll, max(0, accWidth - center))
                keyTimes.append(NSNumber(value: t1))
                values.append(-offset)
                lastT = t1
            }

            accWidth += wordW

            // At word end: highlight leading edge is at accWidth
            if t2 > lastT {
                let offset = min(maxScroll, max(0, accWidth - center))
                keyTimes.append(NSNumber(value: t2))
                values.append(-offset)
                lastT = t2
            }
        }

        if lastT < 1 {
            keyTimes.append(1)
            values.append(-maxScroll)
        }

        let anim = CAKeyframeAnimation(keyPath: "position.x")
        anim.values = values
        anim.keyTimes = keyTimes
        anim.duration = duration
        anim.calculationMode = .linear
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        anim.beginTime = CACurrentMediaTime() - elapsed
        return anim
    }

    /// Scroll keyframes: [hold, hold, scroll-to-end, hold] with easeInEaseOut for the middle segment.
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

    // MARK: - Karaoke Mask Animation

    /// Builds a mask-width keyframe animation: each word's begin/end maps to a width value,
    /// expanding the mask left-to-right to produce a word-by-word highlight effect.
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

    // MARK: - Edge Fade

    /// Applies edge fade during scrolling via a `CAGradientLayer` mask on `self`.
    /// Locations are fixed; colors animate to avoid the hard-edge artifact of growing gradient width.
    private func buildEdgeFade(scrollStart: Double, scrollEnd: Double,
                               duration: TimeInterval, elapsed: TimeInterval) {
        let fade = CAGradientLayer()
        fade.frame = bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)

        let inset = Double(edgeFadeWidth / bounds.width)
        let edge = NSColor.clear.cgColor
        let solid = NSColor.black.cgColor

        // Fixed locations — gradient shape never changes
        fade.locations = [0, NSNumber(value: inset), NSNumber(value: 1 - inset), 1]
        fade.colors = [solid, solid, solid, edge]

        // Color states: solid = fully visible, edge = faded
        let noLeft  = [solid, solid, solid, edge]
        let both    = [edge, solid, solid, edge]
        let noRight = [edge, solid, solid, solid]

        let desiredTr = 0.75 / duration
        let ahead = 0.15 / duration
        let leftTr = min(desiredTr, scrollStart + ahead)
        let rightTr = min(desiredTr, 1 - scrollEnd + ahead)

        let anim = CAKeyframeAnimation(keyPath: "colors")
        anim.values = [noLeft, noLeft, both, both, noRight, noRight]
        anim.keyTimes = [0,
                         NSNumber(value: max(0, scrollStart - leftTr)),
                         NSNumber(value: max(0, scrollStart - ahead)),
                         NSNumber(value: min(1, scrollEnd - ahead)),
                         NSNumber(value: min(1, scrollEnd + rightTr - ahead)),
                         1]
        anim.duration = duration
        anim.calculationMode = .linear
        anim.isRemovedOnCompletion = false
        anim.fillMode = .both
        anim.beginTime = CACurrentMediaTime() - elapsed
        fade.add(anim, forKey: "edgeFade")
        fade.cornerRadius = cornerRadius

        mask = fade
        edgeFadeMask = fade
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

    /// All sublayers that need freeze/unfreeze.
    private var allAnimatedLayers: [CALayer] {
        [textImageLayer, dimImageLayer, brightImageLayer, karaokeMask, edgeFadeMask].compactMap { $0 }
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
    }
}
