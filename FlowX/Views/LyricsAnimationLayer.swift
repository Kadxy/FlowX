import AppKit
import QuartzCore

final class LyricsAnimationLayer: CALayer {

    var karaokeEnabled: Bool = true

    var edgeFadeWidth: CGFloat = 24

    var renderAppearance: NSAppearance?

    // MARK: - 只读状态

    private(set) var isAnimating: Bool = false

    // MARK: - 内部子 layer

    private var textImageLayer: CALayer?
    private var dimImageLayer: CALayer?
    private var brightImageLayer: CALayer?
    private var karaokeMask: CALayer?
    private var edgeFadeMask: CAGradientLayer?

    // MARK: - 文本缓存

    private var cachedText: String = ""
    private var cachedTextSize: NSSize = .zero
    private var cachedWordWidths: [CGFloat] = []

    // MARK: - 漂移检测锚点

    /// 动画构建时的播放位置（秒）
    private(set) var anchorPosition: TimeInterval = 0
    /// 动画构建时的系统时间（CACurrentMediaTime）
    private(set) var anchorWallTime: CFTimeInterval = 0

    // MARK: - 常量

    private let font: NSFont = .systemFont(ofSize: 14)
    private let scale: CGFloat = 2.0

    // MARK: - 公共 API

    /// 构建或重建动画。安全地重复调用——每次都会先拆掉旧 layer。
    /// - Parameters:
    ///   - text: 显示文本（歌词行或 "♪ Not Playing" 等静态文本）
    ///   - line: 歌词行（含 word timing），为 nil 时绘制静态文本
    ///   - position: 当前播放位置（秒）
    ///   - playing: 当前是否正在播放
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

    /// 冻结所有动画在当前视觉位置（暂停时调用）。
    /// 原理：将每个子 layer 的 speed 设为 0，CA 的内部时钟停止，画面定格。
    func freeze() {
        let now = CACurrentMediaTime()
        for sub in allAnimatedLayers {
            guard sub.speed != 0 else { continue }
            let pausedTime = sub.convertTime(now, from: nil)
            sub.speed = 0
            sub.timeOffset = pausedTime
        }
    }

    /// 从冻结位置恢复动画（播放时调用）。
    /// 原理：恢复 speed=1，并调整 beginTime 补偿暂停期间流逝的时间，
    /// 使动画从暂停的那一帧继续而不是跳到当前时刻。
    /// 这是 Apple 官方推荐的 CA 动画暂停/恢复做法。
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

    // MARK: - 动画构建

    private func buildAnimations(line: LyricLine, position: TimeInterval) {
        let size = cachedTextSize
        guard size.width > 0, size.height > 0 else { return }

        let karaoke = karaokeEnabled && !line.words.isEmpty
        let duration = line.endTime - line.time
        let elapsed = max(0, min(position - line.time, duration))
        let needsScroll = size.width > bounds.width
        let y = (bounds.height - size.height) / 2
        let origin = CGPoint(x: needsScroll ? 0 : (bounds.width - size.width) / 2, y: y)

        // 1. 构建内容层（卡拉OK 双层 或 普通单层）
        if karaoke {
            buildKaraokeLayers(line: line, size: size, origin: origin,
                               duration: duration, elapsed: elapsed)
        } else {
            textImageLayer = addImageLayer(renderTextImage(), size: size, origin: origin)
        }

        // 2. 文本溢出时添加滚动动画和边缘渐隐
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

    /// 无动画时的静态文本（如 "♪ Not Playing" 或无时间信息的歌词）
    private func buildStaticLayer() {
        let size = cachedTextSize
        guard size.width > 0, size.height > 0 else { return }
        let x = size.width <= bounds.width ? (bounds.width - size.width) / 2 : 0
        let y = (bounds.height - size.height) / 2
        textImageLayer = addImageLayer(renderTextImage(), size: size, origin: CGPoint(x: x, y: y))
    }

    // MARK: - 卡拉OK 层构建

    private func buildKaraokeLayers(
        line: LyricLine, size: NSSize, origin: CGPoint,
        duration: TimeInterval, elapsed: TimeInterval
    ) {
        // 缓存每个单词的宽度，按比例修正字距（单词宽度之和 ≠ 整行宽度）
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let rawWidths = line.words.map { (($0.text) as NSString).size(withAttributes: attrs).width }
        let rawSum = rawWidths.reduce(0, +)
        let ratio = rawSum > 0 ? size.width / rawSum : 1.0
        cachedWordWidths = rawWidths.map { $0 * ratio }

        // 暗色底层（未唱部分，alpha 0.45）
        dimImageLayer = addImageLayer(renderTextImage(dimAlpha: 0.45), size: size, origin: origin)

        // 高亮层 + 遮罩（已唱部分，遮罩宽度从 0 逐字扩展）
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

    // MARK: - 滚动动画

    /// 计算滚动的开始/结束时间点（占歌词行时长的比例）
    private func computeScrollTimes(
        karaoke: Bool, line: LyricLine?, textWidth: CGFloat, duration: TimeInterval
    ) -> (start: Double, end: Double) {
        if karaoke, let line = line {
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
        } else {
            let lr: CGFloat = 0.65
            let s = Double(min(0.85, bounds.width * lr / textWidth))
            let e = max(s + 0.05, 1.0 - Double(bounds.width * (1 - lr) / textWidth))
            return (s, e)
        }
    }

    /// 非卡拉OK 模式的滚动：文本唱到 65% 位置时开始平滑滚动
    private func makeScrollAnimation(
        textWidth: CGFloat, duration: TimeInterval, elapsed: TimeInterval
    ) -> CAKeyframeAnimation {
        let leadRatio: CGFloat = 0.65
        let startRatio = min(0.85, bounds.width * leadRatio / textWidth)
        let endRatio = max(startRatio + 0.05, 1.0 - bounds.width * (1 - leadRatio) / textWidth)
        return makeScrollKeyframes(textWidth: textWidth, duration: duration, elapsed: elapsed,
                                   startT: startRatio, endT: endRatio)
    }

    /// 卡拉OK 模式的滚动：高亮边缘保持在视图 65% 位置
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

    /// 滚动关键帧：[停留, 停留, 滚到底, 停留]，中间段用 easeInEaseOut
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

    // MARK: - 卡拉OK 遮罩动画

    /// 构建遮罩宽度的关键帧动画：每个单词的 begin/end 对应一个宽度值，
    /// 遮罩从左往右逐字扩展，产生逐字高亮效果。
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

    // MARK: - 边缘渐隐

    /// 滚动时的左右边缘渐隐效果，用 CAGradientLayer 作为 self.mask。
    /// locations 随滚动阶段变化：无左渐隐 → 两边渐隐 → 无右渐隐。
    private func buildEdgeFade(scrollStart: Double, scrollEnd: Double,
                               duration: TimeInterval, elapsed: TimeInterval) {
        let fade = CAGradientLayer()
        fade.frame = bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)

        let inset = Double(edgeFadeWidth / bounds.width)
        fade.colors = [NSColor.clear, .black, .black, .clear].map(\.cgColor)
        fade.locations = [0, 0, NSNumber(value: 1 - inset), 1]

        let noLeft: [NSNumber] = [0, 0, NSNumber(value: 1 - inset), 1]
        let both: [NSNumber] = [0, NSNumber(value: inset), NSNumber(value: 1 - inset), 1]
        let noRight: [NSNumber] = [0, NSNumber(value: inset), 1, 1]

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
        fade.cornerRadius = cornerRadius

        mask = fade
        edgeFadeMask = fade
    }

    // MARK: - 文本渲染

    /// 将文本光栅化为位图（CGImage）。
    /// 因为是离屏渲染，macOS 不会自动设置外观上下文，必须用 renderAppearance 手动指定。
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

    // MARK: - 工具方法

    /// 创建并添加一个显示 CGImage 的子 layer，返回引用
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

    /// 所有需要 freeze/unfreeze 的子 layer
    private var allAnimatedLayers: [CALayer] {
        [textImageLayer, dimImageLayer, brightImageLayer, karaokeMask, edgeFadeMask].compactMap { $0 }
    }

    /// 拆除所有子 layer，重置状态。用 CATransaction 禁用隐式动画避免副作用。
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
