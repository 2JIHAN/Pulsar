import AppKit
import Network
import ApplicationServices
import AVFoundation
import Carbon
import VideoToolbox
import IOKit.pwr_mgt

@_silgen_name("CGSMainConnectionID") private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSSetGlobalHotKeyOperatingMode") private func CGSSetGlobalHotKeyOperatingMode(_ cid: Int32, _ mode: Int32) -> Int32

// Disabling symbolic hot keys lets Cmd+Tab, Cmd+Space and Mission Control keys reach the viewer.
// Carbon's push alone did not stop Ctrl+Up on a real MacBook; Parsec's loader also imports this
// CoreGraphics call (REA evidence). Mode 1 disables global hot keys, 0 restores them.
// Each push must be popped exactly once, otherwise the user's shortcuts stay disabled.
final class HotKeyMode {
    var push: () -> UnsafeMutableRawPointer? = {
        _ = CGSSetGlobalHotKeyOperatingMode(CGSMainConnectionID(), 1)
        return PushSymbolicHotKeyMode(OptionBits(kHIHotKeyModeAllDisabled))
    }
    var pop: (UnsafeMutableRawPointer) -> Void = {
        PopSymbolicHotKeyMode($0)
        _ = CGSSetGlobalHotKeyOperatingMode(CGSMainConnectionID(), 0)
    }
    private var token: UnsafeMutableRawPointer?
    func set(_ on: Bool) {
        if on, token == nil { token = push() }
        else if !on, let t = token { token = nil; pop(t) }
    }
}

final class SleepAssertion {
    var acquire: () -> IOPMAssertionID? = {
        var id: IOPMAssertionID = 0
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Pulsar hosting" as CFString,
            &id
        )
        return ok == kIOReturnSuccess ? id : nil
    }
    var release: (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }
    private var id: IOPMAssertionID?
    var isHeld: Bool { id != nil }
    func set(_ on: Bool) {
        if on, id == nil { id = acquire() }
        else if !on, let current = id { id = nil; release(current) }
    }
    deinit { set(false) }
}

final class Viewer: NSView {
    let display = AVSampleBufferDisplayLayer()
    var format: CMVideoFormatDescription?
    var videoSize = CGSize.zero { didSet { needsLayout = true; needsDisplay = true } }
    var sendInput: ((InputMessage) -> Void)?
    var emergency: (() -> Void)?
    var focusChanged: (() -> Void)?
    // Sends a KeyframeRequest for this viewer's stream (only to 0.9+ hosts, which know type 11).
    var onNeedKeyframe: (() -> Void)?
    private var keyframeAsked: TimeInterval?
    var tracksMouse = true
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    var contentRect: NSRect {
        let size = videoSize
        guard size.width > 0, size.height > 0 else { return .zero }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        return NSRect(x: (bounds.width - size.width * s) / 2, y: (bounds.height - size.height * s) / 2, width: size.width * s, height: size.height * s)
    }
    // Returns false for a frame that must close the connection. Non-keyframes without a usable
    // decoder state are skipped until the next keyframe: a 0.10+ host sends one when asked (a 60 s
    // safety interval otherwise), older hosts every 2 s anyway.
    func show(_ frame: VideoFrame) -> Bool {
        let renderer = display.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush(); format = nil }
        if !frame.keyframe && format == nil { requestKeyframe() }
        if frame.keyframe {
            keyframeAsked = nil
            guard let next = videoFormat(frame) else { return false }
            if format.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: next) }) ?? true {
                format = next
                let d = CMVideoFormatDescriptionGetDimensions(next)
                videoSize = CGSize(width: Int(d.width), height: Int(d.height))
            }
        }
        if let format, let sample = videoSample(frame, format: format) { renderer.enqueue(sample) }
        return true
    }
    // One request per 2 s until a keyframe arrives: a large keyframe on a slow link can take over a
    // second, and every extra request would make the host encode another one.
    func requestKeyframe(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let asked = keyframeAsked, now - asked < 2 { return }
        keyframeAsked = now; onNeedKeyframe?()
    }
    func clear() { format = nil; videoSize = .zero; display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
    override func layout() {
        super.layout()
        // The layer frame is already the aspect-fit contentRect; resizeAspect also keeps the first frame
        // of a new size undistorted until the next layout moves the frame.
        if display.superlayer == nil { wantsLayer = true; display.videoGravity = .resizeAspect; layer?.addSublayer(display) }
        CATransaction.begin(); CATransaction.setDisableActions(true); display.frame = contentRect; CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        if videoSize == .zero { ("연결 후 이 화면을 클릭하면 입력이 전달됩니다." as NSString).draw(at: NSPoint(x: 20, y: 20), withAttributes: [.foregroundColor: NSColor.white]) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        guard tracksMouse else { return }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func becomeFirstResponder() -> Bool { focusChanged?(); return true }
    override func resignFirstResponder() -> Bool { sendInput?(InputMessage(kind: .release)); focusChanged?(); return true }
    func mouse(_ e: NSEvent, _ kind: InputMessage.Kind) {
        guard window?.isKeyWindow == true, window?.firstResponder === self else { return }
        let p = convert(e.locationInWindow, from: nil), r = contentRect
        guard r.width > 0, r.height > 0 else { return }
        if !r.contains(p) && kind != .up { return }
        sendInput?(Viewer.inputMessage(e, kind, point: p, rect: r))
    }
    // NSEvent raises if scrollingDelta is read from a non-scroll event, which crashed the viewer on the first click.
    static func inputMessage(_ e: NSEvent, _ kind: InputMessage.Kind, point p: NSPoint, rect r: NSRect) -> InputMessage {
        let scroll = kind == .scroll
        var m = InputMessage(kind: kind, x: min(1, max(0, (p.x-r.minX)/r.width)), y: min(1, max(0, (p.y-r.minY)/r.height)),
            code: scroll ? 0 : UInt16(min(2, max(0, e.buttonNumber))), flags: UInt64(e.modifierFlags.rawValue),
            dx: scroll ? min(1000, max(-1000, Double(e.scrollingDeltaX))) : 0, dy: scroll ? min(1000, max(-1000, Double(e.scrollingDeltaY))) : 0)
        if scroll, !e.hasPreciseScrollingDeltas { m.lines = true }
        return m
    }
    override func mouseDown(with e: NSEvent) { window?.makeFirstResponder(self); mouse(e, .down) }
    override func mouseUp(with e: NSEvent) { mouse(e, .up) }
    override func rightMouseDown(with e: NSEvent) { mouse(e, .down) }
    override func rightMouseUp(with e: NSEvent) { mouse(e, .up) }
    override func otherMouseDown(with e: NSEvent) { mouse(e, .down) }
    override func otherMouseUp(with e: NSEvent) { mouse(e, .up) }
    override func mouseMoved(with e: NSEvent) { mouse(e, .move) }
    override func mouseDragged(with e: NSEvent) { mouse(e, .move) }
    override func rightMouseDragged(with e: NSEvent) { mouse(e, .move) }
    override func otherMouseDragged(with e: NSEvent) { mouse(e, .move) }
    override func scrollWheel(with e: NSEvent) { mouse(e, .scroll) }
    override func magnify(with e: NSEvent) { gesture(e) }
    override func rotate(with e: NSEvent) { gesture(e) }
    override func swipe(with e: NSEvent) { gesture(e) }
    override func smartMagnify(with e: NSEvent) { gesture(e) }
    func gesture(_ e: NSEvent) {
        guard window?.isKeyWindow == true, window?.firstResponder === self else { return }
        let r = contentRect
        guard r.width > 0, r.height > 0, let m = Viewer.gestureMessage(e, point: convert(e.locationInWindow, from: nil), rect: r) else { return }
        sendInput?(m)
    }
    static func gestureMessage(_ e: NSEvent, point p: NSPoint, rect r: NSRect) -> InputMessage? {
        guard let data = e.cgEvent?.data as Data?, !data.isEmpty, data.count <= InputMessage.gestureDataLimit, let build = osBuild else { return nil }
        return InputMessage(kind: .gesture, x: min(1, max(0, (p.x-r.minX)/r.width)), y: min(1, max(0, (p.y-r.minY)/r.height)), data: data, build: build)
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 && e.modifierFlags.contains([.command, .option]) { emergency?(); return }
        sendInput?(InputMessage(kind: .keyDown, code: e.keyCode, flags: UInt64(e.modifierFlags.rawValue)))
    }
    override func keyUp(with e: NSEvent) { sendInput?(InputMessage(kind: .keyUp, code: e.keyCode, flags: UInt64(e.modifierFlags.rawValue))) }
    override func flagsChanged(with e: NSEvent) { sendInput?(InputMessage(kind: .flags, code: e.keyCode, flags: UInt64(e.modifierFlags.rawValue))) }
}
// Viewer: the host cursor drawn as this Mac's cursor over the remote screens. Shapes are cached by hash.
struct RemoteCursor {
    static let blank = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true }, hotSpot: .zero)
    private(set) var cache = [String: NSCursor]()
    private(set) var current: NSCursor?
    private(set) var visible = true
    private(set) var screenWidth: Double?
    // nil until the host sent a shape; hidden on the host shows a blank cursor here.
    var shown: NSCursor? { current.map { visible ? $0 : Self.blank } }
    mutating func reset() { current = nil; visible = true; screenWidth = nil }
    // False for an image that does not decode to its announced size: the connection is closed.
    mutating func apply(_ u: CursorUpdate) -> Bool {
        if let image = u.image, cache[u.hash] == nil {
            guard let c = image.cursor() else { return false }
            if cache.count >= 32 { cache.removeAll() }
            cache[u.hash] = c
        }
        if let c = cache[u.hash] { current = c }
        visible = u.visible
        if let w = u.screenWidth { screenWidth = w }
        return true
    }
}
// Viewer overlay numbers, summed per second. RTT is the newest timed-ping sample.
struct LiveStats {
    var rttMs: Double?
    var encodeSum = 0.0, displaySum = 0.0, timed = 0, displayed = 0, skipped = 0
    var bitrateMbps: Double?
    mutating func add(_ t: FrameTiming, displayMs: Double?) {
        encodeSum += t.encodeMs; timed += 1; skipped += Int(t.skipped); bitrateMbps = t.bitrateMbps
        if let d = displayMs { displaySum += d; displayed += 1 }
    }
    mutating func reset() { encodeSum = 0; displaySum = 0; timed = 0; displayed = 0; skipped = 0 }
    // e.g. "60fps · 18.2/20Mbps · 왕복 12ms · 인코딩 4ms · 표시 2ms · 건너뜀 0"; the second Mbps is the host's current target.
    func text(fps: Int, mbps: Double, timing: Bool) -> String {
        guard timing else { return String(format: "%d fps  ·  %.1f Mbps", fps, mbps) }
        var parts = [String(format: "%dfps", fps), bitrateMbps.map { String(format: "%.1f/%gMbps", mbps, ($0 * 10).rounded() / 10) } ?? String(format: "%.1fMbps", mbps)]
        if let r = rttMs { parts.append(String(format: "왕복 %.0fms", r)) }
        if timed > 0 { parts.append(String(format: "인코딩 %.0fms", encodeSum / Double(timed))) }
        if displayed > 0 { parts.append(String(format: "표시 %.0fms", displaySum / Double(displayed))) }
        parts.append("건너뜀 \(skipped)")
        return parts.joined(separator: " · ")
    }
}
// One host display (or virtual display) streamed to one viewer screen.
final class HostStream {
    let screen: Int
    let capture = Capture()
    var virtualDisplay: VirtualDisplay?
    init(screen: Int) { self.screen = screen }
    func stop() { capture.stop(); virtualDisplay?.destroy(); virtualDisplay = nil }
}
// A borderless window that may cover the menu bar area while the session hides the menu bar.
final class ScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
struct RemoteScreen {
    let id: Int
    let window: ScreenWindow
    let view: SessionView
    var viewer: Viewer { view.viewer }
}
// window: the remote screen inside the Pulsar window. screens: one borderless window per viewer screen.
// local: connected, but the pointer went back to this Mac through an edge portal.
enum Presentation { case window, screens, local }
// Tailscale first (works across networks), then private LAN, link-local bridges last.
private func rank(_ a: (String, String)) -> Int { a.0.hasPrefix("Tailscale") ? 0 : a.1.hasPrefix("169.254.") ? 2 : 1 }
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let status = NSTextField(wrappingLabelWithString: "공유를 시작하거나 연결코드를 붙여넣으세요.")
    var statusText = "" { didSet { status.stringValue = statusText; computers?.note.stringValue = statusText } }
    let tailnetState = NSTextField(labelWithString: "꺼짐")
    var tailnetListener: NWListener?
    var selfLogin: String?
    var consumedKey: UInt16?
    var returnPage = 1
    let addresses = NSPopUpButton()
    let code = NSSecureTextField()
    let allowAccess = NSSwitch()
    let preventSleep = NSSwitch()
    let guestInput = NSSwitch()
    let sleepAssertion = SleepAssertion()
    let updater = Updater()
    var streams = [HostStream]()
    var streamRequest: QualityRequest?
    let viewer = Viewer()
    var presentation = Presentation.window
    var wantsScreens = true
    var remoteScreens = [RemoteScreen]()
    var clientScreens = [ClientScreen]()
    var screenMap: ScreenMap?
    var layoutHost = ""
    var layoutChosen = false
    var legacyHost = false
    var edgeReturn = true
    var remoteSide: EdgeSide = .right
    var edgePressure: EdgePressure?
    var localPortal: EdgePressure.Key?
    var reentry = PortalReentry()
    var heldEdgeKeys = Set<UInt16>()
    func blocksEdge(_ e: NSEvent) -> Bool {
        !heldEdgeKeys.isEmpty || NSEvent.pressedMouseButtons != 0 || !e.modifierFlags.intersection([.shift, .control, .option, .command, .function]).isEmpty
    }
    let edgeOverlay = EdgeSurfaceOverlay()
    var statusItem: NSStatusItem?
    var boardPressed = false
    let hostButton = NSButton(title: "공유 시작", target: nil, action: nil)
    var listener: NWListener?
    var secret: Data?
    var token: String?
    let host = HostPeers()
    var outbound: Peer?
    var session = ViewerSession()
    let hotKeys = HotKeyMode()
    var split: NSSplitViewController!
    var sidebar: SidebarController!
    let content = ContentController()
    var computers: ComputersPage!
    var settings: SettingsPage!
    var sessionView: SessionView!
    var devices = [TailscaleDevice]()
    var fetching = false
    var inSession = false
    var frames = 0, bytes = 0
    // Viewer: the host announced 0.10 timing. Per-second sums for the overlay.
    var hostTiming = false
    var stats = LiveStats()
    // Host: newest RTT from a timed ping since the last per-second tick.
    var hostRtt: Double?
    var gestureNoted = false
    let cursorTracker = CursorTracker()
    // Viewer: the host announced `cursor` (no cursor in the video) and `dockGesture`.
    var hostCursor = false
    var hostDockGesture = false
    var remoteCursor = RemoteCursor()
    let dockTap = DockGestureTap()
    var qualityWait: DispatchWorkItem?
    weak var awaitedPeer: Peer?
    let injector = InputInjector()
    var timer: Timer?
    var uiTimer: Timer?
    var deviceTimer: Timer?
    var ips = [String]()
    var hosting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let mainMenu = NSMenu(); let item = NSMenuItem(); mainMenu.addItem(item)
        let menu = NSMenu()
        menu.addItem(withTitle: "설정…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Pulsar 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = menu
        let edit = NSMenu(title: "편집"), editItem = NSMenuItem(); editItem.submenu = edit; mainMenu.addItem(editItem)
        edit.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "실행 복귀", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "오려두기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "복사하기", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = mainMenu
        buildWindow()
        viewer.sendInput = { [weak self] m in guard let data = try? JSONEncoder().encode(m) else { return }; self?.outbound?.send(Data([2]) + data) }
        viewer.emergency = { [weak self] in self?.stopAll() }
        dockTap.onGesture = { [weak self] d in self?.outbound?.send(d.wireMessage()) }
        viewer.onNeedKeyframe = { [weak self] in self?.sendKeyframeRequest(0) }
        // First responder changes only after become/resign return, so re-evaluate afterwards.
        viewer.focusChanged = { [weak self] in DispatchQueue.main.async { self?.updateSystemInput() } }
        // Deferred: key focus moving between session screen windows is not a focus loss.
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; if !self.forwardingKeys { self.sendInput(InputMessage(kind: .release)) }; self.updateSystemInput() }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateSystemInput() }
        }
        // A local monitor sees key events before menus and also the keyUp of Command combinations,
        // which AppKit never delivers to the view, so remote keys are not left held down.
        // Session shortcuts are matched first and stay on this Mac, along with their keyUp.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, self.isSessionWindow(e.window) else { return e }
            if self.presentation == .screens {
                self.advanceEdge(nil, point: .zero, now: e.timestamp)
                if e.type == .keyDown { self.heldEdgeKeys.insert(e.keyCode) }
                if e.type == .keyUp { self.heldEdgeKeys.remove(e.keyCode) }
            }
            if self.inSession, let action = ShortcutAction.matching(e) { self.consumedKey = e.keyCode; self.perform(action); return nil }
            if e.type == .keyUp, self.consumedKey == e.keyCode { self.consumedKey = nil; return nil }
            guard self.forwardingKeys else { return e }
            switch e.type {
            case .keyDown: self.viewer.keyDown(with: e)
            case .keyUp: self.viewer.keyUp(with: e)
            default: self.viewer.flagsChanged(with: e)
            }
            return nil
        }
        // Screen windows send pointer input from here, by global position, so the pointer can cross screens.
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
                                                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .magnify, .rotate, .swipe, .smartMagnify]) { [weak self] e in
            self?.routePointer(e) ?? e
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in self?.localEdge(e) }
        host.onActive = { [weak self] p in self?.awaitQuality(for: p) }
        host.onInactive = { [weak self] in
            guard let self else { return }
            self.qualityWait?.cancel(); self.qualityWait = nil; self.awaitedPeer = nil
            self.stopStreams(); self.injector.release(); self.statusText = "연결 해제됨. 공유는 대기 중입니다."
        }
        host.onPacket = { [weak self] p, data in self?.hostPacket(p, data) }
        // Every second: keepalive (timed for 0.10 peers) and one bitrate-controller step per stream.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for p in self.host.peers where p.ready {
                let timed = p === self.host.active && self.streamRequest?.timing == true
                if Date().timeIntervalSince(p.lastReceive) > 20 { p.close() } else { p.send(timed ? TimedPing.ping(TimedPing.now()) : Data([3])) }
            }
            let rtt = self.hostRtt; self.hostRtt = nil
            for s in self.streams { s.capture.tick(rttMs: rtt) }
            if let p = self.outbound, p.ready {
                if Date().timeIntervalSince(p.lastReceive) > ViewerSession.silenceLimit { p.close() } else { p.send(self.hostTiming ? TimedPing.ping(TimedPing.now()) : Data([3])) }
            }
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refreshDevices() }
        refreshDevices()
        settings.onSystemChanged = { [weak self] in self?.updateSystemInput() }
        if let listen = Permission.all.first(where: { $0.pane == "Privacy_ListenEvent" }), !listen.granted() { listen.request() }
        preventSleep.state = HostPreferences.preventSleep() ? .on : .off
        guestInput.state = (HostPreferences.allowGuestInput() && AXIsProcessTrusted()) ? .on : .off
        if HostPreferences.allowRemoteAccess() {
            if CGPreflightScreenCaptureAccess() { startHost() }
            else { allowAccess.state = .off; statusText = "원격 접속을 시작하지 못했습니다. 화면 기록 권한이 필요합니다." }
        } else {
            allowAccess.state = .off
        }
        // Launch argument `-PulsarStartPage 0|1|2` opens a page directly (used for screenshots).
        select(min(2, max(0, UserDefaults.standard.integer(forKey: "PulsarStartPage"))))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Pulsar"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.titlebarSeparatorStyle = .none
        window.delegate = self; window.minSize = NSSize(width: 960, height: 600); window.isReleasedWhenClosed = false
        let found = localAddresses().sorted { rank($0) < rank($1) }; ips = found.map { $0.1 }; addresses.addItems(withTitles: found.map { $0.0 }); if ips.isEmpty { ips = ["127.0.0.1"]; addresses.addItem(withTitle: "로컬 테스트 127.0.0.1") }
        hostButton.target = self; hostButton.action = #selector(toggleHost)
        allowAccess.target = self; allowAccess.action = #selector(allowAccessChanged)
        preventSleep.target = self; preventSleep.action = #selector(preventSleepChanged)
        guestInput.target = self; guestInput.action = #selector(guestInputChanged)

        sidebar = SidebarController()
        sidebar.onSelect = { [weak self] page in self?.show(page) }
        computers = ComputersPage()
        computers.onCodePage = { [weak self] in self?.select(1) }
        computers.onSettings = { [weak self] in self?.select(2) }
        computers.onConnect = { [weak self] d in
            guard let self, let ip = d.ipv4 else { return }
            self.disconnectViewer(); self.returnPage = 0
            self.session.start(DialTarget(tailnet: ip)); self.statusText = "\(d.name)에 연결하는 중…"; self.dial()
        }
        settings = SettingsPage(allowAccess: allowAccess, preventSleep: preventSleep)
        updater.idle = { [weak self] in self.map { $0.host.active == nil && $0.outbound == nil && !$0.inSession } ?? false }
        updater.start()
        settings.onCheckUpdate = { [weak self] in self?.updater.check { text in self?.settings.updateNote.stringValue = text } }
        sessionView = SessionView(viewer: viewer)
        sessionView.fullScreen.target = self; sessionView.fullScreen.action = #selector(toggleFullScreen)
        sessionView.leave.target = self; sessionView.leave.action = #selector(disconnectViewer)

        split = NSSplitViewController()
        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 200; side.maximumThickness = 280; side.canCollapse = true
        let main = NSSplitViewItem(viewController: content)
        split.addSplitViewItem(side); split.addSplitViewItem(main)
        _ = content.view
        content.setup(pages: [computers, connectionPage(), settings.view], session: sessionView)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 720))
        // The viewer starts below the title bar so the traffic lights never cover the remote screen.
        if let guide = window.contentLayoutGuide as? NSLayoutGuide { viewer.topAnchor.constraint(equalTo: guide.topAnchor).isActive = true }
        refreshHostState()
    }
    func connectionPage() -> NSView {
        status.font = .systemFont(ofSize: 13); status.textColor = Palette.secondary; status.maximumNumberOfLines = 0
        code.placeholderString = "Pulsar 연결코드를 붙여넣으세요 (비밀값 포함)"
        code.lineBreakMode = .byTruncatingMiddle
        code.setContentHuggingPriority(.init(1), for: .horizontal)
        let copy = NSButton(title: "연결코드 복사", target: self, action: #selector(copyCode))
        let stop = redTextButton("긴급 중지", self, #selector(stopAll))
        let connect = navyButton("접속", self, #selector(connectViewer))
        let disconnect = NSButton(title: "연결 해제", target: self, action: #selector(disconnectViewer))
        let codeRow = hstack([code, connect, disconnect], 8); codeRow.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        let note = label("다른 네트워크에서는 두 Mac 모두 같은 Tailscale 네트워크에 있어야 합니다.", 11, .regular, Palette.secondary)
        return scrollPage([
            heading("연결코드"), status, gap(16),
            sectionTitle("이 Mac 공유"),
            group([
                settingRow("공유", "켜 두면 같은 Tailscale 계정의 Mac이나 연결코드를 가진 Mac 한 대가 이 화면을 볼 수 있습니다.", [hostButton]),
                settingRow("Tailscale 바로 연결", "같은 Tailscale 계정의 Mac은 컴퓨터 목록에서 코드 없이 연결합니다.", [tailnetState]),
                settingRow("주소", "연결코드에 넣을 주소입니다. 다른 네트워크에서는 Tailscale 주소를 고르세요.", [addresses]),
                settingRow("연결코드", "주소, 포트, 비밀키가 들어 있습니다. 믿을 수 있는 경로로만 전달하세요.", [copy]),
                settingRow("연결코드 접속자에게 마우스·키보드 허용", "끄면 연결코드로 접속한 상대는 화면만 볼 수 있습니다.", [guestInput]),
                settingRow("긴급 중지", "공유와 접속을 모두 끊습니다. 원격 화면에서는 ⌘⌥⎋", [stop]),
            ]), gap(20),
            sectionTitle("다른 Mac에 접속"),
            group([codeRow]), note,
        ])
    }
    func select(_ page: Int) { sidebar.select(page); show(page) }
    func show(_ page: Int) {
        if page != 2 { settings.stopRecording() }
        content.show(page); tick()
    }
    @objc func showSettings() { select(2) }
    // During a session this switches between the all-screens presentation and the Pulsar window.
    @objc func toggleFullScreen() {
        guard inSession else { window.toggleFullScreen(nil); return }
        wantsScreens = presentation != .screens
        if wantsScreens { presentScreens() } else { presentWindow() }
    }
    func perform(_ action: ShortcutAction) {
        switch action {
        case .disconnect: disconnectViewer(); statusText = "연결을 종료했습니다."
        case .overlay: currentBoard.togglePinned()
        case .fullScreen: toggleFullScreen()
        }
    }
    var boards: [SessionView] { [sessionView] + remoteScreens.map(\.view) }
    var currentBoard: SessionView {
        guard presentation == .screens else { return sessionView }
        return remoteScreen(at: NSEvent.mouseLocation)?.view ?? remoteScreens.first?.view ?? sessionView
    }
    func remoteScreen(at p: NSPoint) -> RemoteScreen? { remoteScreens.first { NSMouseInRect(p, $0.window.frame, false) } }
    func isSessionWindow(_ w: NSWindow?) -> Bool { w != nil && (w === window || remoteScreens.contains { $0.window === w }) }
    func sendInput(_ m: InputMessage) {
        if m.kind == .release { heldEdgeKeys.removeAll() }
        if let data = try? JSONEncoder().encode(m) { outbound?.send(Data([2]) + data) }
    }
    func refreshHostState() {
        hostButton.title = hosting ? "공유 중지" : "공유 시작"
        allowAccess.state = hosting ? .on : .off
        computers.hosting = hosting
        updateSleepAssertion()
    }
    func updateSleepAssertion() {
        sleepAssertion.set(hosting && preventSleep.state == .on)
    }
    func refreshDevices() {
        guard !fetching else { return }
        fetching = true
        TailscaleDevice.fetch { [weak self] net in
            guard let self else { return }
            self.devices = net?.devices ?? []; self.selfLogin = net?.login
            self.computers.update(devices: net?.devices)
            if self.hosting && self.tailnetListener == nil { self.startTailnetListener() }
            let ips = self.devices.filter { $0.state == .online || $0.state == .otherAccount }.compactMap(\.ipv4)
            DispatchQueue.global(qos: .utility).async {
                var found = [String: Probe](), lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: ips.count) { i in let p = Probe.run(ips[i]); lock.lock(); found[ips[i]] = p; lock.unlock() }
                DispatchQueue.main.async { self.computers.probes = found; self.fetching = false }
            }
        }
    }
    func tick() {
        if inSession {
            guard outbound?.ready == true else { return }
            let text = stats.text(fps: frames, mbps: Double(bytes) * 8 / 1_000_000, timing: hostTiming)
            for b in boards { b.live(peer: peerName, metrics: text) }
            frames = 0; bytes = 0; stats.reset()
        } else if window.isVisible {
            if content.current == 0 { computers.refreshPermissions() }
            if content.current == 2 { settings.refreshPermissions() }
        }
    }
    var peerName: String {
        guard let h = session.target?.host else { return "" }
        return devices.first { $0.ips.contains(h) }?.name ?? h
    }
    func enterSession() {
        frames = 0; bytes = 0; stats = LiveStats()
        if !inSession {
            inSession = true; settings.stopRecording()
            sessionView.setQuality("")
            split.splitViewItems[0].isCollapsed = true
            sessionView.isHidden = false
            buildScreenWindows()
            updateStatusItem()
            if wantsScreens { presentScreens() } else { presentWindow() }
        }
        settings.setConnected(true)
        for b in boards { b.live(peer: peerName, metrics: "측정 중") }
        if presentation != .local { currentBoard.flash(3) }
    }
    func leaveSession() {
        guard inSession else { return }
        inSession = false; sessionView.pinned = false; sessionView.setBoard(false)
        sessionView.setQuality(""); settings.setConnected(false)
        sessionView.isHidden = true
        split.splitViewItems[0].isCollapsed = false
        tearDownScreenWindows()
        presentation = .window; localPortal = nil; edgePressure = nil; edgeOverlay.reset()
        hostCursor = false; hostDockGesture = false; remoteCursor.reset(); NSCursor.arrow.set()
        screenMap = nil; legacyHost = false; layoutChosen = false; sessionView.setMonitors([], current: nil)
        updateStatusItem()
        if NSApp.isHidden { NSApp.unhide(nil) }
        window.makeKeyAndOrderFront(nil)
        select(returnPage)
    }

    // MARK: Viewer screens

    func buildScreenWindows() {
        tearDownScreenWindows()
        let screens = Array(NSScreen.screens.prefix(maxScreenStreams))
        for (i, screen) in screens.enumerated() where clientScreens.indices.contains(i) {
            let viewer = Viewer(); viewer.tracksMouse = false
            viewer.onNeedKeyframe = { [weak self] in self?.sendKeyframeRequest(i) }
            let view = SessionView(viewer: viewer); view.tracksMouse = false
            viewer.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
            view.fullScreen.title = "창으로 보기"; view.fullScreen.target = self; view.fullScreen.action = #selector(toggleFullScreen)
            view.leave.target = self; view.leave.action = #selector(disconnectViewer)
            view.monitors.target = self; view.monitors.action = #selector(switchMonitor(_:)); view.monitors.tag = i
            let w = ScreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; w.backgroundColor = .black; w.hidesOnDeactivate = false
            w.acceptsMouseMovedEvents = true; w.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            // The remote cursor is set on every pointer event; window cursor rects would reset it to the arrow.
            w.disableCursorRects()
            w.contentView = view; w.setFrame(screen.frame, display: false)
            remoteScreens.append(RemoteScreen(id: i, window: w, view: view))
        }
        refreshMonitorMenus()
    }
    func tearDownScreenWindows() {
        for rs in remoteScreens { rs.viewer.clear(); rs.window.orderOut(nil); rs.window.close() }
        remoteScreens = []
        NSApp.presentationOptions = []
    }
    func presentScreens() {
        guard inSession, !remoteScreens.isEmpty else { presentWindow(); return }
        let prefs = StreamQualityPreferences.load()
        edgeReturn = prefs.edgeReturn; remoteSide = prefs.remoteSide
        presentation = .screens; localPortal = nil; edgePressure = nil; heldEdgeKeys.removeAll()
        window.orderOut(nil)
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        for rs in remoteScreens { rs.window.orderFrontRegardless() }
        (remoteScreen(at: NSEvent.mouseLocation) ?? remoteScreens[0]).window.makeKeyAndOrderFront(nil)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        sessionView.viewer.format = nil
        requestKeyframes()
        updateSystemInput()
    }
    func presentWindow() {
        presentation = .window; localPortal = nil; edgePressure = nil
        hideScreens()
        if NSApp.isHidden { NSApp.unhide(nil) }
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(viewer)
        requestKeyframes()
        updateSystemInput()
    }
    // Hidden viewers drop their decoder state so they resume from the next keyframe, not from stale references.
    func hideScreens() {
        for rs in remoteScreens { rs.window.orderOut(nil); rs.viewer.format = nil }
        NSApp.presentationOptions = []
    }
    func land(on key: EdgePressure.Key, y: CGFloat) -> CGPoint {
        let f = clientScreens[key.screen].frame
        let p = CGPoint(x: key.side == .left ? f.minX + 4 : f.maxX - 5, y: min(max(y, f.minY + 1), f.maxY - 1))
        CGWarpMouseCursorPosition(CGPoint(x: p.x, y: (NSScreen.screens.first?.frame.maxY ?? f.maxY) - p.y))
        CGAssociateMouseAndMouseCursorPosition(1)
        return p
    }
    func goLocal(_ key: EdgePressure.Key, at point: NSPoint) {
        guard let landing = key.side.opposite.outerScreen(clientScreens.map(\.frame), y: point.y) else { return }
        sendInput(InputMessage(kind: .release))
        presentation = .local; localPortal = landing; reentry = PortalReentry()
        NSCursor.arrow.set()
        hideScreens()
        updateSystemInput()
        _ = land(on: landing, y: point.y)
        // Hiding hands keyboard focus to the app underneath. The edge surface sets canHide = false.
        NSApp.hide(nil)
    }
    func requestKeyframes() {
        for v in presentation == .screens ? remoteScreens.map(\.viewer) : [viewer] { v.requestKeyframe() }
    }
    // 0.8 hosts send no ScreenMap and would close on type 11.
    func sendKeyframeRequest(_ id: Int) {
        guard screenMap != nil else { return }
        outbound?.send(KeyframeRequest.wire(id))
    }
    func refreshMonitorMenus() {
        guard let map = screenMap else { for b in boards { b.setMonitors([], current: nil) }; return }
        // Agreed screen rules: host monitors pair with this Mac's screens, extra screens here get virtual displays
        // automatically, and only host monitors left over (more there than screens here) are offered to switch to.
        let choices = map.switchable.count > clientScreens.count ? map.switchable.map { (title: $0.name, wire: $0.id) } : []
        func current(_ id: Int) -> String? { map.screens.first { $0.clientScreenId == id }?.hostDisplayId }
        for rs in remoteScreens { rs.view.setMonitors(choices, current: current(rs.id)) }
        sessionView.setMonitors(choices, current: current(0))
    }
    var currentChoices: [Int: String] { Dictionary((screenMap?.screens ?? []).map { ($0.clientScreenId, $0.hostDisplayId) }, uniquingKeysWith: { a, _ in a }) }
    @objc func switchMonitor(_ sender: NSPopUpButton) {
        guard screenMap != nil, let wire = sender.selectedItem?.representedObject as? String, clientScreens.indices.contains(sender.tag) else { return }
        outbound?.send(ScreenSwitch(clientScreenId: sender.tag, show: wire).wireMessage())
        var choices = currentChoices; choices[sender.tag] = wire
        layoutChosen = true
        ScreenLayoutMemory.save(host: layoutHost, screens: clientScreens, choices: choices)
    }
    func updateStatusItem() {
        if inSession, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Pulsar")
            let menu = NSMenu()
            menu.addItem(withTitle: "원격 화면으로 들어가기", action: #selector(returnToRemote), keyEquivalent: "").target = self
            menu.addItem(withTitle: "연결 종료", action: #selector(disconnectViewer), keyEquivalent: "").target = self
            item.menu = menu; statusItem = item
        } else if !inSession, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item); statusItem = nil
        }
    }
    @objc func returnToRemote() { guard inSession else { return }; wantsScreens = true; presentScreens() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard inSession, presentation == .local else { if !flag { window.makeKeyAndOrderFront(nil) }; return true }
        presentScreens(); return false
    }
    static func pointerKind(_ type: NSEvent.EventType) -> InputMessage.Kind? {
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return .move
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return .down
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return .up
        case .scrollWheel: return .scroll
        case .magnify, .rotate, .swipe, .smartMagnify: return .gesture
        default: return nil
        }
    }
    // Returns nil when the event went to the remote Mac. Board controls and the windowed viewer keep normal dispatch.
    func routePointer(_ e: NSEvent) -> NSEvent? {
        switch presentation {
        case .local: if e.type == .mouseMoved { localEdge(e) }; return e
        case .window: refreshCursor(); return e
        case .screens: refreshCursor()
        }
        let global = NSEvent.mouseLocation
        guard inSession, let rs = remoteScreen(at: global), let kind = Self.pointerKind(e.type) else { return e }
        let windowPoint = rs.window.convertPoint(fromScreen: global)
        if kind == .move {
            for o in remoteScreens {
                if o.id == rs.id { o.view.pointer(atY: o.viewer.convert(windowPoint, from: nil).y) } else { o.view.pointerLeft() }
            }
        }
        // A press that starts on a board control stays with the board until its mouse-up; any other
        // mouse-up goes to the remote Mac so no remote button is left held.
        if kind == .down, rs.view.boardContains(windowPoint: windowPoint) { boardPressed = true }
        if boardPressed {
            if kind == .up { boardPressed = false }
            advanceEdge(nil, point: global, now: e.timestamp); return e
        }
        let p = rs.viewer.convert(windowPoint, from: nil), r = rs.viewer.contentRect
        if r.width > 0, r.height > 0,
           var m = kind == .gesture ? Viewer.gestureMessage(e, point: p, rect: r) : Viewer.inputMessage(e, kind, point: p, rect: r) {
            m.screen = rs.id
            sendInput(m)
        }
        if e.type == .mouseMoved, edgeReturn, !blocksEdge(e),
           let side = portalEdge(screens: clientScreens.map(\.frame), index: rs.id, point: global, dx: e.deltaX),
           side == remoteSide.opposite, side.outerScreen(clientScreens.map(\.frame), y: global.y)?.screen == rs.id {
            advanceEdge(EdgePressure.Key(screen: rs.id, side: side), point: global, now: e.timestamp, distance: abs(e.deltaX))
        } else {
            advanceEdge(nil, point: global, now: e.timestamp)
        }
        return nil
    }
    func pointerOverRemote() -> Bool {
        guard inSession, outbound?.ready == true else { return false }
        let g = NSEvent.mouseLocation
        switch presentation {
        case .screens:
            guard let rs = remoteScreen(at: g) else { return false }
            return !rs.view.boardContains(windowPoint: rs.window.convertPoint(fromScreen: g))
        case .window:
            guard window.isVisible, NSMouseInRect(g, window.frame, false) else { return false }
            return viewer.contentRect.contains(viewer.convert(window.convertPoint(fromScreen: g), from: nil))
        case .local: return false
        }
    }
    // Only for a host that sends its cursor; others keep this Mac's arrow and the cursor in the video.
    func refreshCursor() {
        guard hostCursor, let c = remoteCursor.shown else { return }
        (pointerOverRemote() ? c : NSCursor.arrow).set()
    }
    // While local, only the edge the pointer came back through leads into the remote screens again.
    func localEdge(_ e: NSEvent) {
        guard presentation == .local, inSession, let key = localPortal else { return }
        let global = NSEvent.mouseLocation
        if reentry.crosses(key, screens: clientScreens.map(\.frame), point: global, dx: e.deltaX,
                           blocked: !edgeReturn || blocksEdge(e) || outbound?.ready != true),
           key.side.outerScreen(clientScreens.map(\.frame), y: global.y) == key,
           let target = key.side.opposite.outerScreen(clientScreens.map(\.frame), y: global.y),
           let rs = remoteScreens.first(where: { $0.id == target.screen }) {
            let landed = land(on: target, y: global.y)
            presentScreens()
            let r = rs.viewer.contentRect
            if r.width > 0, r.height > 0 {
                let p = rs.viewer.convert(rs.window.convertPoint(fromScreen: landed), from: nil)
                var m = Viewer.inputMessage(e, .move, point: p, rect: r); m.screen = rs.id; sendInput(m)
            }
        }
    }
    func advanceEdge(_ key: EdgePressure.Key?, point: NSPoint, now: Double, distance: Double = 0) {
        let had = edgePressure != nil
        if EdgePressure.advance(&edgePressure, key: key, now: now, distance: distance), let key {
            edgeOverlay.release(crossed: true)
            goLocal(key, at: point)
        } else if let p = edgePressure, clientScreens.indices.contains(p.key.screen) {
            edgeOverlay.push(key: p.key, screenFrame: clientScreens[p.key.screen].frame, point: point, distance: p.distance)
        } else if had {
            edgeOverlay.release(crossed: false)
        }
    }
    @objc func allowAccessChanged() {
        if allowAccess.state == .on {
            guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
                allowAccess.state = .off
                HostPreferences.setAllowRemoteAccess(false)
                statusText = "화면 기록 권한이 필요합니다. 설정(Command+,)에서 허용한 뒤 다시 켜세요."
                return
            }
            HostPreferences.setAllowRemoteAccess(true)
            if !hosting { startHost() }
        } else {
            HostPreferences.setAllowRemoteAccess(false)
            if hosting { stopHost() }
        }
    }
    @objc func preventSleepChanged() {
        HostPreferences.setPreventSleep(preventSleep.state == .on)
        updateSleepAssertion()
    }
    @objc func guestInputChanged() {
        if guestInput.state == .on && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            guestInput.state = .off
            HostPreferences.setAllowGuestInput(false)
            statusText = "기기 제어 및 데이터 접근 권한이 필요합니다. 설정에서 허용한 뒤 다시 켜세요."
            select(2)
            return
        }
        HostPreferences.setAllowGuestInput(guestInput.state == .on)
        if guestInput.state == .off && host.active?.kind == .guest { injector.release() }
    }
    @objc func toggleHost() {
        if hosting { stopHost(); return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { statusText = "화면 기록 권한이 필요합니다. 설정(Command+,)에서 허용한 뒤 앱을 다시 여세요."; return }
        startHost()
    }
    func startHost() {
        do {
            let t = try ConnectionCode.randomToken(); token = t
            let c = ConnectionCode(host: "localhost", port: 1, token: t); secret = c.secret
            let l = try NWListener(using: tlsParameters(secret: c.secret), on: .any)
            listener = l; hosting = true; refreshHostState()
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self = self, self.listener === l else { return }
                switch state {
                case .ready: self.statusText = "공유 대기 중. 연결코드를 복사해 상대 Mac에 전달하세요."
                case .failed: self.stopHost(); self.statusText = "공유를 시작하지 못했습니다."
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] connection in guard let self, self.hosting else { connection.cancel(); return }; self.host.accept(connection) }
            l.start(queue: .main)
            startTailnetListener()
        } catch { stopHost(); statusText = "보안 공유를 시작할 수 없습니다." }
    }
    // Bound to this Mac's Tailscale address only. Retried from the 10 s device refresh when
    // Tailscale was not up yet or the port was busy.
    func startTailnetListener() {
        guard let address = tailnetBindAddress(ips), let l = try? plainListener(address: address, port: tailnetPort) else {
            tailnetState.stringValue = "Tailscale 주소 없음"; return
        }
        tailnetListener = l
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.tailnetListener === l else { return }
            switch state {
            case .ready: self.tailnetState.stringValue = "\(address):\(tailnetPort) 대기 중"
            case .failed(let e):
                l.cancel(); self.tailnetListener = nil
                self.tailnetState.stringValue = e == .posix(.EADDRINUSE) ? "포트 \(tailnetPort) 사용 중" : "열지 못함"
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in
            guard let self, self.hosting else { c.cancel(); return }
            self.host.acceptTailnet(c) { [weak self] ip, done in self?.authorize(ip, done) ?? done(false) }
        }
        l.start(queue: .main)
    }
    func authorize(_ ip: String, _ done: @escaping (Bool) -> Void) {
        let login = selfLogin
        DispatchQueue.global(qos: .utility).async {
            let whois = TailscaleDevice.run(["whois", "--json", ip], timeout: 2).flatMap { $0.ok ? $0.out : nil }
            let ok = tailnetAllows(whois: whois, selfLogin: login)
            DispatchQueue.main.async { done(ok) }
        }
    }
    func awaitQuality(for p: Peer) {
        qualityWait?.cancel(); qualityWait = nil
        awaitedPeer = p
        statusText = (p.greet ? "Tailscale로 연결됨." : "암호화 연결됨.") + " 화면 품질 확인 중…"
        let work = DispatchWorkItem { [weak self, weak p] in
            guard let self, let p, self.host.active === p, self.awaitedPeer === p, self.streams.isEmpty else { return }
            self.awaitedPeer = nil; self.qualityWait = nil
            self.startCapture(for: p, request: nil)
        }
        qualityWait = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
    func stopStreams() {
        cursorTracker.stop()
        for s in streams { s.stop() }
        streams = []; streamRequest = nil; injector.rects = [:]
    }
    // A 0.8 viewer (no screen list) gets one stream in the 0.8 wire format: the main display, or a virtual
    // display when it asked for one. A 0.9 viewer gets one stream per screen as decided by mapScreens.
    func startCapture(for p: Peer, request: QualityRequest?) {
        gestureNoted = false
        stopStreams()
        streamRequest = request
        statusText = (p.greet ? "Tailscale로 연결됨." : "암호화 연결됨.") + " 화면 전송 준비 중…"
        guard let screens = request?.screens else {
            let vd = request?.virtualDisplay.flatMap { $0.enabled ? ($0.width, $0.height, $0.scale) : nil }
            startStream(for: p, request: request, screen: 0, streamed: false, source: vd == nil ? nil : .virtual, size: vd)
            return
        }
        if request?.cursor == true {
            cursorTracker.send = { [weak self, weak p] u in if let self, let p, self.host.active === p { p.send(u.wireMessage()) } }
            cursorTracker.start()
        }
        let assignment = mapScreens(client: screens, host: HostDisplay.streamable(HostDisplay.online()), singleScreenVirtual: request?.virtualDisplay?.enabled ?? false)
        for c in screens {
            startStream(for: p, request: request, screen: c.id, streamed: true, source: assignment.sources[c.id] ?? .virtual, size: (c.pixelWidth, c.pixelHeight, c.scale))
        }
    }
    // `source` nil or a missing physical display captures the main display.
    func startStream(for p: Peer, request: QualityRequest?, screen: Int, streamed: Bool, source: ScreenSource?, size: (Int, Int, Int)?) {
        let prefix = p.greet ? "Tailscale로 연결됨." : "암호화 연결됨."
        let inputNote = p.kind == .owner ? "같은 계정: 마우스·키보드 허용" : (guestInput.state == .on ? "연결코드: 마우스·키보드 허용" : "연결코드: 보기 전용")
        let s = HostStream(screen: screen); streams.append(s)
        let capture = s.capture
        capture.streamIndex = streamed ? UInt8(screen) : nil
        capture.onFrame = { [weak self, weak p, weak s] data, sent in
            guard let self, let s, self.host.active === p, self.streams.contains(where: { $0 === s }) else { return }
            p?.frame(data, sent: sent)
        }
        capture.onError = { [weak self, weak p] message in guard let self = self, self.host.active === p else { return }; p?.close(); self.statusText = message }
        var target: CGDirectDisplayID?
        var vdFallback = false
        switch source {
        case .virtual?:
            if let size, let vd = VirtualDisplay(width: size.0, height: size.1, scale: size.2) { s.virtualDisplay = vd } else { vdFallback = true }
        case .physical(let id)?:
            target = HostDisplay.online().first { $0.id == id }?.cgID
        case nil: break
        }
        Task { @MainActor in
            let alive = { self.host.active === p && self.streams.contains { $0 === s } }
            do {
                let actual: EffectiveQuality
                if let vd = s.virtualDisplay {
                    do {
                        actual = try await capture.start(request: request, targetDisplayID: vd.displayID, isVirtual: true, fallbackPixelSize: (vd.pixelWidth, vd.pixelHeight))
                    } catch where alive() {
                        s.virtualDisplay?.destroy(); s.virtualDisplay = nil
                        vdFallback = true
                        actual = try await capture.start(request: request, targetDisplayID: nil)
                    }
                } else {
                    actual = try await capture.start(request: request, targetDisplayID: target)
                }
                guard alive() else { s.stop(); return }
                if request != nil { p.send(actual.wireMessage()) }
                if streamed { p.send(self.hostScreenMap().wireMessage()) }
                let fallbackNote = vdFallback ? " 가상 화면을 만들지 못해 기본 화면을 전송합니다." : ""
                let count = self.streams.count > 1 ? " 화면 \(self.streams.count)개," : ""
                self.statusText = prefix + " 화면 전송 중 (\(count)\(actual.summary), \(inputNote))." + fallbackNote
            } catch {
                s.stop()
                guard alive() else { return }
                p.close(); self.statusText = "화면 캡처 실패. 화면 기록 권한과 로그인 상태를 확인하세요."
            }
        }
    }
    func hostScreenMap() -> ScreenMap {
        let displays = HostDisplay.streamable(HostDisplay.online())
        let entries = streams.sorted { $0.screen < $1.screen }.map { s -> ScreenMap.Entry in
            let w = max(2, s.capture.outputSize.width), h = max(2, s.capture.outputSize.height)
            if s.virtualDisplay != nil {
                return ScreenMap.Entry(clientScreenId: s.screen, kind: .virtual, hostDisplayName: "가상 화면", hostDisplayId: ScreenSource.virtualWire, pixelWidth: w, pixelHeight: h)
            }
            let d = displays.first { $0.cgID == s.capture.displayID }
            return ScreenMap.Entry(clientScreenId: s.screen, kind: .physical, hostDisplayName: String((d?.name ?? "기본 화면").prefix(128)),
                                   hostDisplayId: d?.id ?? "display-\(s.capture.displayID)", pixelWidth: w, pixelHeight: h)
        }
        return ScreenMap(screens: entries, switchable: displays.prefix(16).map { ScreenMap.Display(id: $0.id, name: String($0.name.prefix(128))) })
    }
    func hostPacket(_ p: Peer, _ data: Data) {
        if data == Data([3]) { return }
        if data.first == 3 {
            guard let ping = TimedPing.decode(data) else { p.close(); return }
            if ping.pong { hostRtt = TimedPing.msSince(ping.time) ?? hostRtt } else { p.send(TimedPing.pong(ping.time)) }
            return
        }
        if data.first == QualityRequest.messageType {
            guard awaitedPeer === p, streams.isEmpty, let req = QualityRequest.decodeWire(data) else { p.close(); return }
            qualityWait?.cancel(); qualityWait = nil; awaitedPeer = nil
            startCapture(for: p, request: req)
            return
        }
        if data.first == ScreenSwitch.messageType {
            guard let sw = ScreenSwitch.decodeWire(data), let req = streamRequest, let c = req.screens?.first(where: { $0.id == sw.clientScreenId }) else { p.close(); return }
            if let old = streams.first(where: { $0.screen == c.id }) { old.stop(); streams.removeAll { $0 === old }; injector.rects[c.id] = nil }
            startStream(for: p, request: req, screen: c.id, streamed: true, source: ScreenSource(wire: sw.show), size: (c.pixelWidth, c.pixelHeight, c.scale))
            return
        }
        if data.first == KeyframeRequest.messageType {
            guard let id = KeyframeRequest.decode(data) else { p.close(); return }
            streams.first { $0.screen == id }?.capture.requestKeyframe()
            return
        }
        if data.first == DockGesture.messageType {
            guard let d = DockGesture.decodeWire(data) else { p.close(); return }
            guard hostAllowsInput(peerKind: p.kind, guestInputAllowed: guestInput.state == .on, accessibilityTrusted: AXIsProcessTrusted()),
                  streamRequest?.dockGesture == osBuild, DockGesture.supported else { return }
            injector.applyDock(d)
            return
        }
        // Malformed messages close the connection; a well-formed gesture the host cannot replay is ignored.
        guard data.first == 2, data.count <= 100_000, let m = try? JSONDecoder().decode(InputMessage.self, from: data.dropFirst()), m.valid,
              m.kind == .gesture || data.count <= 2048 else { p.close(); return }
        if m.kind == .release { injector.release(); return }
        guard hostAllowsInput(peerKind: p.kind, guestInputAllowed: guestInput.state == .on, accessibilityTrusted: AXIsProcessTrusted()) else { return }
        if m.kind == .gesture && m.build != osBuild {
            if !gestureNoted { gestureNoted = true; statusText = "두 Mac의 macOS 빌드가 달라 트랙패드 제스처를 무시합니다." }
            return
        }
        // Read live: another virtual display appearing can move this one.
        let screen = m.screen ?? 0
        if let s = streams.first(where: { $0.screen == screen }), s.capture.displayID != 0 { injector.rects[screen] = CGDisplayBounds(s.capture.displayID) }
        injector.apply(m)
    }
    @objc func copyCode() {
        guard hosting, let t = token, let port = listener?.port?.rawValue else { statusText = "먼저 공유를 시작하세요."; return }
        let c = ConnectionCode(host: ips[addresses.indexOfSelectedItem], port: port, token: t)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.text, forType: .string)
        statusText = "연결코드 복사됨. 주소 \(c.host), 포트 \(port). 코드는 비밀값입니다."
    }
    @objc func connectViewer() {
        do {
            let c = try ConnectionCode.parse(code.stringValue); disconnectViewer(); code.stringValue = ""
            returnPage = 1; session.start(DialTarget(c)); statusText = "TLS 인증 중..."; dial()
        } catch { statusText = "유효하지 않은 연결코드입니다." }
    }
    func dial() {
        guard let t = session.target else { return }
        let p = Peer(NWConnection(host: NWEndpoint.Host(t.host), port: NWEndpoint.Port(rawValue: t.port)!, using: t.secret.map(tlsParameters) ?? plainParameters()), greet: t.secret == nil)
        outbound = p
        p.onReady = { [weak self, weak p] in
            guard let self, let p else { return }
            self.hostTiming = false; self.hostCursor = false; self.hostDockGesture = false; self.remoteCursor.reset()
            let prefs = StreamQualityPreferences.load()
            // A redial keeps the screens the session windows were built for.
            if !self.inSession { self.clientScreens = ClientScreen.list(NSScreen.screens); self.layoutHost = self.peerName }
            let saved = ScreenLayoutMemory.load(host: self.layoutHost, screens: self.clientScreens)
            for i in self.clientScreens.indices { self.clientScreens[i].show = saved[self.clientScreens[i].id] }
            let vd = VirtualDisplayRequest.forScreen(NSScreen.screens.first, enabled: prefs.singleScreenVirtual)
            let req = prefs.request(hevcDecode: VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC), virtualDisplay: vd, screens: self.clientScreens,
                                    dockGesture: DockGesture.supported ? osBuild : nil)
            p.send(req.wireMessage())
            self.session.connected()
            self.statusText = (p.greet ? "Tailscale로 연결됨." : "암호화 연결됨.") + " 화면을 클릭해 입력하세요. Command+Option+Escape는 긴급 중지입니다." + (AXIsProcessTrusted() ? "" : " 시스템 단축키와 제스처 전달에는 이 Mac의 기기 제어 및 데이터 접근과 입력 모니터링 권한이 필요합니다.")
            self.enterSession()
            self.updateSystemInput()
        }
        p.onPacket = { [weak self, weak p] data in
            if data == Data([3]) { return }
            guard let self = self else { return }
            if data.first == 3 {
                guard let ping = TimedPing.decode(data) else { p?.close(); return }
                if ping.pong { self.stats.rttMs = TimedPing.msSince(ping.time) ?? self.stats.rttMs } else { p?.send(TimedPing.pong(ping.time)) }
                return
            }
            if data.first == EffectiveQuality.messageType {
                guard let eff = EffectiveQuality.decodeWire(data) else { p?.close(); return }
                self.hostTiming = eff.timing; self.hostCursor = eff.cursor; self.hostDockGesture = eff.dockGesture
                self.refreshCursor(); self.updateSystemInput()
                for b in self.boards { b.setQuality(eff.summary) }
                self.settings.setLastEffective(eff.summary)
                return
            }
            if data.first == CursorUpdate.messageType {
                guard let u = CursorUpdate.decodeWire(data), self.remoteCursor.apply(u) else { p?.close(); return }
                if self.pointerOverRemote() { self.refreshCursor() }
                return
            }
            if data.first == ScreenMap.messageType {
                guard let map = ScreenMap.decodeWire(data) else { p?.close(); return }
                self.screenMap = map
                self.refreshMonitorMenus()
                // One screen remembers only an explicit choice, so the single-screen virtual setting keeps working.
                if self.clientScreens.count > 1 || self.layoutChosen {
                    ScreenLayoutMemory.save(host: self.layoutHost, screens: self.clientScreens, choices: self.currentChoices)
                }
                return
            }
            guard let frame = try? VideoFrame.parse(data) else { p?.close(); return }
            // A 0.8 host streams only its main display, so only this Mac's main screen keeps a window.
            if frame.stream == nil, !self.legacyHost {
                self.legacyHost = true
                for rs in self.remoteScreens where rs.id != 0 { rs.window.orderOut(nil); rs.window.close() }
                self.remoteScreens.removeAll { $0.id != 0 }
            }
            let id = Int(frame.stream ?? 0)
            let target: Viewer?
            switch self.presentation {
            case .screens: target = self.remoteScreens.first { $0.id == id }?.viewer
            case .window: target = id == 0 ? self.viewer : nil
            case .local: target = nil
            }
            if let target, !target.show(frame) { p?.close(); return }
            if let t = frame.timing { self.stats.add(t, displayMs: target == nil ? nil : TimedPing.msSince(p?.packetStart ?? 0)) }
            if id == 0 { self.frames += 1 }
            self.bytes += data.count
        }
        // The last frame stays on screen while redialing.
        p.onClose = { [weak self, weak p] in
            guard let self, let p, self.outbound === p else { return }
            self.outbound = nil; self.updateSystemInput()
            switch self.session.closed(failure: p.failure, refused: p.greet && p.connected) {
            case .retry(let attempt):
                self.statusText = "재연결 중… (\(attempt)회)"
                if self.inSession { for b in self.boards { b.reconnecting(attempt, peer: self.peerName) } }
                let generation = self.session.generation
                DispatchQueue.main.asyncAfter(deadline: .now() + ViewerSession.retryDelay) { [weak self] in
                    guard let self, self.session.generation == generation, self.outbound == nil else { return }
                    self.dial()
                }
            case .wrongCode: self.viewer.clear(); self.leaveSession(); self.statusText = "연결코드가 맞지 않습니다."
            case .refused: self.viewer.clear(); self.leaveSession(); self.statusText = "상대 Mac이 이 계정의 연결을 거부했습니다."
            case .giveUp: self.viewer.clear(); self.leaveSession(); self.statusText = "2분 동안 재연결하지 못했습니다. 네트워크와 Tailscale 상태를 확인하세요."
            case .idle: self.viewer.clear(); self.leaveSession()
            }
        }
        p.start()
    }
    @objc func disconnectViewer() { session.stop(); let p = outbound; outbound = nil; p?.close(); viewer.clear(); leaveSession(); updateSystemInput() }
    var forwardingKeys: Bool {
        guard outbound?.ready == true else { return false }
        switch presentation {
        case .window: return window.isKeyWindow && window.firstResponder === viewer
        case .screens: return remoteScreens.contains { $0.window.isKeyWindow }
        case .local: return false
        }
    }
    // Called on every focus, presentation and connection change. The DockSwipe tap exists only while input goes to the remote Mac.
    func updateSystemInput() {
        let remote = forwardingKeys && NSApp.isActive && AXIsProcessTrusted()
        hotKeys.set(remote && ShortcutAction.sendsSystem())
        dockTap.set(remote && hostDockGesture && DockGesture.supported)
    }
    func stopHost() {
        qualityWait?.cancel(); qualityWait = nil; awaitedPeer = nil
        hosting = false; listener?.cancel(); listener = nil; tailnetListener?.cancel(); tailnetListener = nil; tailnetState.stringValue = "꺼짐"
        host.closeAll()
        stopStreams(); injector.release(); token = nil; secret = nil
        refreshHostState(); statusText = "공유를 중지했습니다."
    }
    @objc func stopAll() { stopHost(); disconnectViewer(); statusText = "모든 연결을 중지했습니다. 새로 공유하면 새 비밀키를 만듭니다." }
    // Closing the main window keeps Pulsar running so this Mac stays reachable; quit only with ⌘Q.
    // During a session the close button ends the session instead, which brings the window back.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === window, inSession else { return true }
        disconnectViewer(); return false
    }
    func applicationWillTerminate(_ notification: Notification) { stopAll(); timer?.invalidate(); uiTimer?.invalidate(); deviceTimer?.invalidate() }
}
