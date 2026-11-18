import AppKit

// Spaces (3/4-finger left/right), Mission Control (up) and App Exposé (down) arrive as DockSwipe events:
// CGS type 30 (field 55) with gesture subtype 23 (field 110). Dock consumes them, so apps never see an
// NSEvent .swipe and the view-level gesture forwarding cannot carry them. Ported from ThunderControl
// (DockGestureCodec.swift, DockTransferState.swift): the viewer sends this scalar descriptor, the host
// rebuilds a DockSwipe with the ISS payload bridge. Finger count is not part of the event.
// Viewer -> host [13][JSON], only to hosts whose EffectiveQuality has `dockGesture`.
struct DockGesture: Codable, Equatable {
    static let messageType: UInt8 = 13
    static let maxWireBytes = 256
    var motion: Int  // 1 horizontal (Spaces), 2 vertical (Mission Control up, App Exposé down)
    var phase: Int  // 1 began, 2 changed, 4 ended, 8 cancelled
    var progress: Double
    var vx: Double
    var vy: Double
    var valid: Bool {
        (motion == 1 || motion == 2) && [1, 2, 4, 8].contains(phase) && progress.isFinite && abs(progress) <= 1
            && vx.isFinite && abs(vx) <= 10_000 && vy.isFinite && abs(vy) <= 10_000
    }
    var terminal: Bool { phase == 4 || phase == 8 }
    var cancelled: DockGesture { DockGesture(motion: motion, phase: 8, progress: progress, vx: 0, vy: 0) }

    private static func field(_ n: UInt32) -> CGEventField { CGEventField(rawValue: n)! }
    static func isDockSwipe(_ e: CGEvent) -> Bool {
        e.getIntegerValueField(field(55)) == 30 && e.getIntegerValueField(field(110)) == 23
    }
    static func inspect(_ e: CGEvent) -> DockGesture? {
        guard isDockSwipe(e) else { return nil }
        let d = DockGesture(motion: Int(e.getIntegerValueField(field(123))), phase: Int(e.getIntegerValueField(field(132))),
                            progress: e.getDoubleValueField(field(124)), vx: e.getDoubleValueField(field(129)), vy: e.getDoubleValueField(field(130)))
        return d.valid ? d : nil
    }
    // ThunderControl's receiver inverts both axes and the owner kept that after using it between these
    // two Macs; the captured and synthesized sign conventions differ.
    var projected: DockGesture {
        motion == 1 ? DockGesture(motion: 1, phase: phase, progress: -progress, vx: -vx, vy: vy)
                    : DockGesture(motion: 2, phase: phase, progress: -progress, vx: vx, vy: -vy)
    }
    // The synthesized event for this descriptor as captured on the viewer.
    func event() -> CGEvent? {
        guard valid, Self.supported else { return nil }
        let p = projected
        return DGMakeDockSwipe(Int32(p.motion), Int32(p.phase), p.progress, p.vx, p.vy)
    }
    // The payload layout is only known for macOS 27; anything else keeps gestures local.
    static let supported: Bool = {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
              let e = DGMakeDockSwipe(1, 2, 0.25, 0, 0) else { return false }
        return inspect(e) == DockGesture(motion: 1, phase: 2, progress: 0.25, vx: 0, vy: 0)
    }()
    func wireMessage() -> Data { Data([Self.messageType]) + ((try? JSONEncoder().encode(self)) ?? Data()) }
    static func decodeWire(_ data: Data) -> DockGesture? {
        guard data.first == messageType, data.count > 1, data.count <= maxWireBytes,
              let d = try? JSONDecoder().decode(DockGesture.self, from: data.dropFirst()), d.valid else { return nil }
        return d
    }
}

// Viewer: a session event tap that exists only while input goes to the remote Mac (connected, not
// local through the edge portal, a session window focused). It swallows every DockSwipe so Dock on
// this Mac does nothing, and forwards horizontal and vertical ones. Other events pass untouched.
final class DockGestureTap {
    var onGesture: ((DockGesture) -> Void)?
    // Seams for memory-only tests; the defaults talk to the window server.
    var makeTap: (DockGestureTap) -> CFMachPort? = { tap in
        let mask: CGEventMask = (1 << 29) | (1 << 30)
        return CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, info in
            let tap = Unmanaged<DockGestureTap>.fromOpaque(info!).takeUnretainedValue()
            return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(tap).toOpaque())
    }
    var enableTap: (CFMachPort, Bool) -> Void = { CGEvent.tapEnable(tap: $0, enable: $1) }
    private(set) var port: CFMachPort?
    private var source: CFRunLoopSource?
    // The stream that began while the tap was on; ended with a cancel if the tap goes away mid-swipe.
    private(set) var stream: DockGesture?

    var installed: Bool { port != nil }
    func set(_ on: Bool) {
        if on, port == nil {
            guard let p = makeTap(self) else { return }
            port = p
            source = CFMachPortCreateRunLoopSource(nil, p, 0)
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
            enableTap(p, true)
        } else if !on, let p = port {
            enableTap(p, false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(p)
            port = nil; source = nil
            if let s = stream { stream = nil; onGesture?(s.cancelled) }
        }
    }
    // True swallows the event.
    func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout { if let port { enableTap(port, true) }; return false }
        guard port != nil, DockGesture.isDockSwipe(event),
              // A host replaying a swipe on this same Mac posts from this process.
              event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return false }
        guard let d = DockGesture.inspect(event) else { return true }
        if d.phase == 1 { stream = d } else if stream?.motion != d.motion { return true }
        if d.terminal { stream = nil } else { stream = d }
        onGesture?(d)
        return true
    }
}
