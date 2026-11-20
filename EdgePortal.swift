import AppKit
import QuartzCore

// Ported from ThunderControl (return-edge-resistance-20261110): DesktopReturnPressure,
// ReturnBoundaryGeometry/Spring/Overlay. Only left and right outer edges are portals, so the
// geometry keeps the two vertical cases and works directly in Cocoa screen points.
enum EdgeSide: String { case left, right
    var opposite: Self { self == .left ? .right : .left }
    func outerScreen(_ screens: [CGRect], y: CGFloat) -> EdgePressure.Key? {
        let row = screens.indices.filter { screens[$0].minY <= y && y < screens[$0].maxY }
        let i = row.min { a, b in self == .left ? screens[a].minX < screens[b].minX : screens[a].maxX > screens[b].maxX }
        return i.map { EdgePressure.Key(screen: $0, side: self) }
    }
}

struct EdgePressure: Equatable {
    struct Key: Equatable { let screen: Int; let side: EdgeSide }
    let key: Key
    let startedAt: Double
    var lastOutwardAt: Double
    var distance: Double
    static let duration = 0.250
    static let maximumGap = 0.150
    // Only outward movement advances an episode. A nil key (other direction, held button, no portal) resets it.
    static func advance(_ episode: inout Self?, key: Key?, now: Double, distance: Double = 0) -> Bool {
        guard let key, now.isFinite else { episode = nil; return false }
        let added = distance.isFinite ? min(10_000, max(0, distance)) : 0
        guard var current = episode, current.key == key, now >= current.lastOutwardAt,
              now - current.lastOutwardAt <= maximumGap else {
            episode = Self(key: key, startedAt: now, lastOutwardAt: now, distance: added); return false
        }
        current.lastOutwardAt = now
        current.distance = min(10_000, current.distance + added)
        if now - current.startedAt >= duration { episode = nil; return true }
        episode = current; return false
    }
}

// The edge `point` is pushing out of, if it is an outer edge there: no other screen touches that edge at this height.
func portalEdge(screens: [CGRect], index: Int, point: CGPoint, dx: Double) -> EdgeSide? {
    guard screens.indices.contains(index), dx.isFinite, dx != 0 else { return nil }
    let f = screens[index]
    guard f.contains(point) else { return nil }
    let side: EdgeSide
    if dx < 0, point.x <= f.minX + 1 { side = .left }
    else if dx > 0, point.x >= f.maxX - 1.5 { side = .right }
    else { return nil }
    let edgeX = side == .left ? f.minX : f.maxX
    let neighbour = screens.enumerated().contains { i, s in
        i != index && abs((side == .left ? s.maxX : s.minX) - edgeX) <= 1 && point.y >= s.minY && point.y < s.maxY
    }
    return neighbour ? nil : side
}

// A landing warp or continued pushing must not send the user straight back.
struct PortalReentry {
    private var armed = false
    mutating func crosses(_ key: EdgePressure.Key, screens: [CGRect], point: CGPoint, dx: Double, blocked: Bool) -> Bool {
        guard !blocked, screens.indices.contains(key.screen), screens[key.screen].contains(point), dx.isFinite else { armed = false; return false }
        let f = screens[key.screen]
        let inset = key.side == .left ? point.x - f.minX : (f.maxX - 1) - point.x
        if inset >= 2, key.side == .left ? dx > 0 : dx < 0 { armed = true }
        guard armed, portalEdge(screens: screens, index: key.screen, point: point, dx: dx) == key.side else { return false }
        armed = false; return true
    }
}

struct EdgeSurfaceGeometry {

    static let maximumDepth = 26.0
    static let maximumLength: CGFloat = 140
    let frame: CGRect
    let side: EdgeSide
    let anchor: CGPoint
    let depthKey = "transform.scale.x"

    init(side: EdgeSide, point: CGPoint, screenFrame f: CGRect) {
        let length = min(Self.maximumLength, max(1, f.height))
        let tangent = min(max(point.y, f.minY + length / 2), f.maxY - length / 2)
        let depth = min(CGFloat(Self.maximumDepth), f.width)
        self.side = side
        anchor = CGPoint(x: side == .left ? 0 : 1, y: 0.5)
        frame = CGRect(x: side == .left ? f.minX : f.maxX - depth, y: tangent - length / 2, width: depth, height: length)
    }

    func path() -> CGPath {
        let depth = frame.width, length = frame.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { side == .left ? CGPoint(x: x, y: y) : CGPoint(x: frame.width - x, y: y) }
        let path = CGMutablePath()
        path.move(to: p(0, 1))
        path.addCurve(to: p(depth - 1, length / 2), control1: p(0, length * 0.28), control2: p(depth - 1, length * 0.28))
        path.addCurve(to: p(0, length - 1), control1: p(depth - 1, length * 0.72), control2: p(0, length * 0.72))
        path.closeSubpath()
        return path
    }

    // f(u) = u*D*1.5 / (D + 1.5u), as a scale of the drawn depth D-1.
    static func stretch(_ distance: Double) -> Double {
        let u = distance.isFinite ? min(10_000, max(0, distance)) : 0
        return (u * maximumDepth * 1.5 / (maximumDepth + 1.5 * u)) / (maximumDepth - 1)
    }
}

struct EdgeSurfaceSpring {
    let position: Double
    let velocity: Double
    let target: Double
    let startedAt: Double
    let responseScale: Double
    static let duration = 0.65

    init(position: Double, velocity: Double, target: Double, startedAt: Double, responseScale: Double = 1) {
        self.position = position; self.velocity = velocity; self.target = target
        self.startedAt = startedAt; self.responseScale = responseScale
    }

    func sample(at time: Double) -> (position: Double, velocity: Double) {
        let t = max(0, time - startedAt)
        let alpha = 9.0 / responseScale
        let omega = sqrt(179.0) / responseScale
        let a = position - target
        let b = (velocity + alpha * a) / omega
        let wave = a * cos(omega * t) + b * sin(omega * t)
        let decay = exp(-alpha * t)
        return (target + decay * wave,
                decay * ((-a * omega * sin(omega * t) + b * omega * cos(omega * t)) - alpha * wave))
    }

    func retarget(_ target: Double, at time: Double, responseScale: Double? = nil) -> Self {
        let current = sample(at: time)
        return Self(position: current.position, velocity: current.velocity, target: target, startedAt: time,
                    responseScale: responseScale ?? self.responseScale)
    }

    func animation(key: String) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: key)
        let duration = Self.duration * responseScale
        let count = Int((duration * 120).rounded())
        animation.values = (0...count).map { sample(at: startedAt + Double($0) * duration / Double(count)).position }
        animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
        animation.calculationMode = .linear
        animation.duration = duration
        animation.beginTime = startedAt
        return animation
    }
}

final class EdgeSurfacePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}


// Opaque grey (.92) surface on the pushed edge, click-through and never key.
final class EdgeSurfaceOverlay {
    private(set) var panel: EdgeSurfacePanel?
    private(set) var membrane: CAShapeLayer?
    private var key: EdgePressure.Key?
    private var screenFrame: CGRect?
    private var geometry: EdgeSurfaceGeometry?
    private var dismissal: DispatchWorkItem?
    private var motionReduced = false
    private(set) var depthSpring: EdgeSurfaceSpring?
    var reducedMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func push(key: EdgePressure.Key, screenFrame frame: CGRect, point: CGPoint, distance: Double) {
        dismissal?.cancel(); dismissal = nil
        let isNew = self.key != key || panel == nil || screenFrame != frame
        if isNew {
            reset()
            self.key = key; screenFrame = frame; motionReduced = reducedMotion()
            let panel = EdgeSurfacePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = false; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
            // Stays visible while Pulsar hides itself on the way back to this Mac.
            panel.canHide = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.level = .statusBar
            let view = NSView(); view.wantsLayer = true; panel.contentView = view
            let shape = CAShapeLayer()
            shape.fillColor = NSColor(calibratedWhite: 0.92, alpha: 1).cgColor
            shape.strokeColor = nil
            shape.lineWidth = 0; view.layer?.addSublayer(shape)
            self.panel = panel; membrane = shape
        }
        guard let panel, let membrane, let screenFrame else { return }
        let g = EdgeSurfaceGeometry(side: key.side, point: point, screenFrame: screenFrame)
        let shapeChanged = geometry?.frame.size != g.frame.size || geometry?.side != g.side
        geometry = g
        if panel.frame != g.frame { panel.setFrame(g.frame, display: false) }
        if shapeChanged {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            membrane.bounds = CGRect(origin: .zero, size: g.frame.size)
            membrane.anchorPoint = g.anchor
            membrane.position = CGPoint(x: g.frame.width * g.anchor.x, y: g.frame.height * g.anchor.y)
            membrane.path = g.path()
            membrane.contentsScale = panel.backingScaleFactor
            if isNew {
                membrane.setValue(EdgeSurfaceGeometry.stretch(0), forKeyPath: g.depthKey)
                membrane.opacity = 0
            }
            CATransaction.commit()
        }
        animate(g.depthKey, to: EdgeSurfaceGeometry.stretch(distance), spring: !motionReduced)
        membrane.removeAnimation(forKey: "opacity")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        membrane.opacity = 1
        CATransaction.commit()
        if !panel.isVisible { panel.orderFrontRegardless() }
        let idle = DispatchWorkItem { [weak self] in self?.release(crossed: false) }
        dismissal = idle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: idle)
    }

    private func animate(_ key: String, to target: Double, spring: Bool, responseScale: Double = 1, duration: Double = 0.10, delay: Double = 0) {
        guard let membrane else { return }
        let from = membrane.presentation()?.value(forKeyPath: key) ?? membrane.value(forKeyPath: key) ?? target
        let animation: CAAnimation
        if spring {
            let now = membrane.convertTime(CACurrentMediaTime(), from: nil)
            let next = depthSpring?.retarget(target, at: now, responseScale: responseScale)
                ?? EdgeSurfaceSpring(position: (from as? NSNumber)?.doubleValue ?? target, velocity: 0, target: target, startedAt: now, responseScale: responseScale)
            depthSpring = next
            animation = next.animation(key: key)
        } else {
            if key != "opacity" { depthSpring = nil }
            let basic = CABasicAnimation(keyPath: key)
            basic.fromValue = from; basic.toValue = target; basic.duration = duration
            animation = basic
        }
        if delay > 0 {
            animation.beginTime = membrane.convertTime(CACurrentMediaTime(), from: nil) + delay
            animation.fillMode = .backwards
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        membrane.setValue(target, forKeyPath: key)
        CATransaction.commit()
        membrane.add(animation, forKey: key)
    }

    func release(crossed: Bool) {
        guard let geometry, panel != nil else { return }
        dismissal?.cancel()
        let scale = motionReduced ? 1.0 : 1.2
        animate(geometry.depthKey, to: crossed ? EdgeSurfaceGeometry.stretch(10_000) : 0, spring: !motionReduced, responseScale: scale)
        animate("opacity", to: 0, spring: false, duration: motionReduced ? 0.10 : (crossed ? 0.18 : 0.28) * scale, delay: motionReduced || crossed ? 0 : 0.16 * scale)
        let work = DispatchWorkItem { [weak self] in self?.reset() }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (motionReduced ? 0.12 : EdgeSurfaceSpring.duration * scale), execute: work)
    }

    func reset() {
        dismissal?.cancel(); dismissal = nil
        membrane?.removeAllAnimations(); panel?.orderOut(nil); panel?.close()
        membrane = nil; panel = nil; key = nil; screenFrame = nil; geometry = nil; depthSpring = nil
    }
}
