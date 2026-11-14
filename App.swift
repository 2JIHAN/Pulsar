import AppKit
import Network
import ApplicationServices
import AVFoundation
import Carbon

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

final class Viewer: NSView {
    let display = AVSampleBufferDisplayLayer()
    var format: CMVideoFormatDescription?
    var videoSize = CGSize.zero { didSet { needsLayout = true; needsDisplay = true } }
    var sendInput: ((InputMessage) -> Void)?
    var emergency: (() -> Void)?
    var focusChanged: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    var contentRect: NSRect {
        let size = videoSize
        guard size.width > 0, size.height > 0 else { return .zero }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        return NSRect(x: (bounds.width - size.width * s) / 2, y: (bounds.height - size.height * s) / 2, width: size.width * s, height: size.height * s)
    }
    // Returns false for a frame that must close the connection. Non-keyframes without a usable
    // decoder state are skipped until the next keyframe, which the host sends at least every 2 s.
    func show(_ frame: VideoFrame) -> Bool {
        let renderer = display.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush(); format = nil }
        if frame.keyframe {
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
    func clear() { format = nil; videoSize = .zero; display.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
    override func layout() {
        super.layout()
        if display.superlayer == nil { wantsLayer = true; display.videoGravity = .resize; layer?.addSublayer(display) }
        CATransaction.begin(); CATransaction.setDisableActions(true); display.frame = contentRect; CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        if videoSize == .zero { ("연결 후 이 화면을 클릭하면 입력이 전달됩니다." as NSString).draw(at: NSPoint(x: 20, y: 20), withAttributes: [.foregroundColor: NSColor.white]) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
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
        return InputMessage(kind: kind, x: min(1, max(0, (p.x-r.minX)/r.width)), y: min(1, max(0, (p.y-r.minY)/r.height)),
            code: scroll ? 0 : UInt16(min(2, max(0, e.buttonNumber))), flags: UInt64(e.modifierFlags.rawValue),
            dx: scroll ? min(1000, max(-1000, Double(e.scrollingDeltaX))) : 0, dy: scroll ? min(1000, max(-1000, Double(e.scrollingDeltaY))) : 0)
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
    let allow = NSSwitch()
    let viewer = Viewer()
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
    var gestureNoted = false
    var capture: Capture?
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
        // First responder changes only after become/resign return, so re-evaluate afterwards.
        viewer.focusChanged = { [weak self] in DispatchQueue.main.async { self?.updateHotKeys() } }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.outbound?.send(Data([2]) + (try! JSONEncoder().encode(InputMessage(kind: .release)))); self?.updateHotKeys() }
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateHotKeys() }
        }
        // A local monitor sees key events before menus and also the keyUp of Command combinations,
        // which AppKit never delivers to the view, so remote keys are not left held down.
        // Session shortcuts are matched first and stay on this Mac, along with their keyUp.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] e in
            guard let self, e.window === self.window else { return e }
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
        host.onActive = { [weak self] p in self?.startCapture(for: p) }
        host.onInactive = { [weak self] in
            guard let self else { return }
            self.capture?.stop(); self.capture = nil; self.injector.release(); self.statusText = "연결 해제됨. 공유는 대기 중입니다."
        }
        host.onPacket = { [weak self] p, data in self?.hostPacket(p, data) }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for p in self.host.peers where p.ready {
                if Date().timeIntervalSince(p.lastReceive) > 20 { p.close() } else { p.send(Data([3])) }
            }
            if let p = self.outbound, p.ready {
                if Date().timeIntervalSince(p.lastReceive) > ViewerSession.silenceLimit { p.close() } else { p.send(Data([3])) }
            }
        }
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.refreshDevices() }
        refreshDevices()
        settings.onSystemChanged = { [weak self] in self?.updateHotKeys() }
        if let listen = Permission.all.first(where: { $0.pane == "Privacy_ListenEvent" }), !listen.granted() { listen.request() }
        if UserDefaults.standard.bool(forKey: allowKey) && AXIsProcessTrusted() { allow.state = .on }
        if SettingsPage.autoShares() {
            if CGPreflightScreenCaptureAccess() { startHost() }
            else { statusText = "자동 공유를 시작하지 못했습니다. 화면 기록 권한이 필요합니다." }
        }
        // Launch argument `-PulsarStartPage 0|1|2` opens a page directly (used for screenshots).
        select(min(2, max(0, UserDefaults.standard.integer(forKey: "PulsarStartPage"))))
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Pulsar"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.titlebarSeparatorStyle = .none
        window.delegate = self; window.minSize = NSSize(width: 960, height: 600)
        let found = localAddresses().sorted { rank($0) < rank($1) }; ips = found.map { $0.1 }; addresses.addItems(withTitles: found.map { $0.0 }); if ips.isEmpty { ips = ["127.0.0.1"]; addresses.addItem(withTitle: "로컬 테스트 127.0.0.1") }
        hostButton.target = self; hostButton.action = #selector(toggleHost)
        allow.target = self; allow.action = #selector(permission)

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
        settings = SettingsPage(allow: allow)
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
        let note = label("다른 네트워크에서는 두 Mac 모두 같은 Tailscale 네트워크에 있어야 합니다. 화면은 기본 디스플레이 한 개입니다.", 11, .regular, Palette.secondary)
        return scrollPage([
            heading("연결코드"), status, gap(16),
            sectionTitle("이 Mac 공유"),
            group([
                settingRow("공유", "켜 두면 같은 Tailscale 계정의 Mac이나 연결코드를 가진 Mac 한 대가 이 화면을 볼 수 있습니다.", [hostButton]),
                settingRow("Tailscale 바로 연결", "같은 Tailscale 계정의 Mac은 컴퓨터 목록에서 코드 없이 연결합니다.", [tailnetState]),
                settingRow("주소", "연결코드에 넣을 주소입니다. 다른 네트워크에서는 Tailscale 주소를 고르세요.", [addresses]),
                settingRow("연결코드", "주소, 포트, 비밀키가 들어 있습니다. 믿을 수 있는 경로로만 전달하세요.", [copy]),
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
    @objc func toggleFullScreen() { window.toggleFullScreen(nil) }
    func perform(_ action: ShortcutAction) {
        switch action {
        case .disconnect: disconnectViewer(); statusText = "연결을 종료했습니다."
        case .overlay: sessionView.togglePinned()
        case .fullScreen: toggleFullScreen()
        }
    }
    func refreshHostState() {
        hostButton.title = hosting ? "공유 중지" : "공유 시작"
        computers.hosting = hosting
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
            sessionView.live(peer: peerName, metrics: String(format: "%d fps  ·  %.1f Mbps", frames, Double(bytes) * 8 / 1_000_000))
            frames = 0; bytes = 0
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
        frames = 0; bytes = 0
        if !inSession {
            inSession = true; settings.stopRecording()
            split.splitViewItems[0].isCollapsed = true
            sessionView.isHidden = false
        }
        sessionView.live(peer: peerName, metrics: "측정 중")
        sessionView.flash(3)
    }
    func leaveSession() {
        guard inSession else { return }
        inSession = false; sessionView.pinned = false; sessionView.setBoard(false)
        sessionView.isHidden = true
        split.splitViewItems[0].isCollapsed = false
        select(returnPage)
    }
    @objc func permission() {
        if allow.state == .on && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            allow.state = .off; statusText = "기기 제어 및 데이터 접근 권한이 필요합니다. 설정에서 허용한 뒤 원격 입력 허용을 다시 켜세요."
            select(2)
        }
        UserDefaults.standard.set(allow.state == .on, forKey: allowKey)
        if allow.state == .off { injector.release() }
    }
    let allowKey = "allowRemoteInput"
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
    func startCapture(for p: Peer) {
        gestureNoted = false
        statusText = (p.greet ? "Tailscale로 연결됨." : "암호화 연결됨.") + " 화면 전송 중. 원격 입력은 설정 > 일반에서 제어합니다."
        let capture = Capture(); self.capture = capture
        capture.onFrame = { [weak self, weak p, weak capture] data, sent in guard let self = self, let capture = capture, self.host.active === p, self.capture === capture else { return }; p?.frame(data, sent: sent) }
        capture.onError = { [weak self, weak p] message in guard let self = self, self.host.active === p else { return }; p?.close(); self.statusText = message }
        Task { @MainActor in
            do { try await capture.start(); if self.host.active === p { self.injector.rect = capture.rect } else { capture.stop() } }
            catch { guard self.host.active === p, self.capture === capture else { return }; p.close(); self.statusText = "화면 캡처 실패. 화면 기록 권한과 로그인 상태를 확인하세요." }
        }
    }
    func hostPacket(_ p: Peer, _ data: Data) {
        if data == Data([3]) { return }
        // Malformed messages close the connection; a well-formed gesture the host cannot replay is ignored.
        guard data.first == 2, data.count <= 100_000, let m = try? JSONDecoder().decode(InputMessage.self, from: data.dropFirst()), m.valid,
              m.kind == .gesture || data.count <= 2048 else { p.close(); return }
        if m.kind == .release { injector.release(); return }
        guard allow.state == .on && AXIsProcessTrusted() else { return }
        if m.kind == .gesture && m.build != osBuild {
            if !gestureNoted { gestureNoted = true; statusText = "두 Mac의 macOS 빌드가 달라 트랙패드 제스처를 무시합니다." }
            return
        }
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
        let p = Peer(NWConnection(host: NWEndpoint.Host(t.host), port: NWEndpoint.Port(rawValue: t.port)!, using: t.secret.map(tlsParameters) ?? .tcp), greet: t.secret == nil)
        outbound = p
        p.onReady = { [weak self] in
            guard let self else { return }
            self.session.connected()
            self.statusText = (p.greet ? "Tailscale로 연결됨." : "암호화 연결됨.") + " 화면을 클릭해 입력하세요. Command+Option+Escape는 긴급 중지입니다." + (AXIsProcessTrusted() ? "" : " 시스템 단축키와 제스처 전달에는 이 Mac의 기기 제어 및 데이터 접근과 입력 모니터링 권한이 필요합니다.")
            self.enterSession()
            self.updateHotKeys()
        }
        p.onPacket = { [weak self, weak p] data in
            if data == Data([3]) { return }
            guard let self = self, let frame = try? VideoFrame.parse(data), self.viewer.show(frame) else { p?.close(); return }
            self.frames += 1; self.bytes += data.count
        }
        // The last frame stays on screen while redialing.
        p.onClose = { [weak self, weak p] in
            guard let self, let p, self.outbound === p else { return }
            self.outbound = nil; self.updateHotKeys()
            switch self.session.closed(failure: p.failure, refused: p.greet && p.connected) {
            case .retry(let attempt):
                self.statusText = "재연결 중… (\(attempt)회)"
                if self.inSession { self.sessionView.reconnecting(attempt, peer: self.peerName) }
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
    @objc func disconnectViewer() { session.stop(); let p = outbound; outbound = nil; p?.close(); viewer.clear(); leaveSession(); updateHotKeys() }
    var forwardingKeys: Bool { outbound?.ready == true && window.isKeyWindow && window.firstResponder === viewer }
    func updateHotKeys() { hotKeys.set(forwardingKeys && NSApp.isActive && AXIsProcessTrusted() && ShortcutAction.sendsSystem()) }
    func stopHost() {
        hosting = false; listener?.cancel(); listener = nil; tailnetListener?.cancel(); tailnetListener = nil; tailnetState.stringValue = "꺼짐"
        host.closeAll()
        capture?.stop(); capture = nil; injector.release(); token = nil; secret = nil
        refreshHostState(); statusText = "공유를 중지했습니다."
    }
    @objc func stopAll() { stopHost(); disconnectViewer(); statusText = "모든 연결을 중지했습니다. 새로 공유하면 새 비밀키를 만듭니다." }
    func windowWillClose(_ notification: Notification) { if (notification.object as? NSWindow) === window { NSApp.terminate(nil) } }
    func applicationWillTerminate(_ notification: Notification) { stopAll(); timer?.invalidate(); uiTimer?.invalidate(); deviceTimer?.invalidate() }
}
