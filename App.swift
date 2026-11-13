import AppKit
import Network
import ApplicationServices
import AVFoundation

final class Viewer: NSView {
    let display = AVSampleBufferDisplayLayer()
    var format: CMVideoFormatDescription?
    var videoSize = CGSize.zero { didSet { needsLayout = true; needsDisplay = true } }
    var sendInput: ((InputMessage) -> Void)?
    var emergency: (() -> Void)?
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
    override func resignFirstResponder() -> Bool { sendInput?(InputMessage(kind: .release)); return true }
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
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self { keyDown(with: event); return true }; return false
    }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 && e.modifierFlags.contains([.command, .option]) { emergency?(); return }
        sendInput?(InputMessage(kind: .keyDown, code: e.keyCode, flags: UInt64(e.modifierFlags.rawValue)))
    }
    override func keyUp(with e: NSEvent) { sendInput?(InputMessage(kind: .keyUp, code: e.keyCode, flags: UInt64(e.modifierFlags.rawValue))) }
    override func flagsChanged(with e: NSEvent) { sendInput?(InputMessage(kind: .flags, code: e.keyCode, flags: UInt64(e.modifierFlags.rawValue))) }
}
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let status = NSTextField(labelWithString: "호스트를 시작하거나 연결코드를 붙여넣으세요.")
    let addresses = NSPopUpButton()
    let code = NSSecureTextField()
    let allow = NSButton(checkboxWithTitle: "원격 마우스와 키보드 허용 (기본 꺼짐)", target: nil, action: nil)
    let viewer = Viewer()
    let hostButton = NSButton(title: "호스트 시작", target: nil, action: nil)
    var listener: NWListener?
    var secret: Data?
    var token: String?
    var peers = [Peer]()
    var active: Peer?
    var outbound: Peer?
    var capture: Capture?
    let injector = InputInjector()
    var timer: Timer?
    var ips = [String]()
    var hosting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let mainMenu = NSMenu(); let item = NSMenuItem(); mainMenu.addItem(item)
        let menu = NSMenu(); menu.addItem(withTitle: "Pulsar 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); item.submenu = menu; NSApp.mainMenu = mainMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Pulsar 0.2.0"; window.delegate = self
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 10; root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        let found = localAddresses(); ips = found.map { $0.1 }; addresses.addItems(withTitles: found.map { $0.0 }); if ips.isEmpty { ips = ["127.0.0.1"]; addresses.addItem(withTitle: "로컬 테스트 127.0.0.1") }
        hostButton.target = self; hostButton.action = #selector(toggleHost)
        let copy = NSButton(title: "연결코드 복사", target: self, action: #selector(copyCode))
        let stop = NSButton(title: "긴급 중지 (모든 연결)", target: self, action: #selector(stopAll))
        let row = NSStackView(views: [hostButton, addresses, copy, stop]); row.spacing = 8; root.addArrangedSubview(row)
        allow.target = self; allow.action = #selector(permission); root.addArrangedSubview(allow)
        root.addArrangedSubview(NSTextField(labelWithString: "외부망은 두 Mac 모두 같은 Tailscale 네트워크에 연결해야 합니다. 화면은 기본 디스플레이 한 개입니다."))
        code.placeholderString = "Pulsar 연결코드를 붙여넣으세요 (비밀값 포함)"
        code.lineBreakMode = .byTruncatingMiddle
        let connect = NSButton(title: "접속", target: self, action: #selector(connectViewer))
        let disconnect = NSButton(title: "뷰어 연결 해제", target: self, action: #selector(disconnectViewer))
        let connectionRow = NSStackView(views: [code, connect, disconnect]); connectionRow.spacing = 8; root.addArrangedSubview(connectionRow)
        root.addArrangedSubview(status); root.addArrangedSubview(viewer)
        NSLayoutConstraint.activate([viewer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32), viewer.heightAnchor.constraint(greaterThanOrEqualToConstant: 300), connectionRow.widthAnchor.constraint(equalTo: viewer.widthAnchor)])
        viewer.setContentHuggingPriority(.defaultLow, for: .vertical)
        viewer.sendInput = { [weak self] m in guard let data = try? JSONEncoder().encode(m) else { return }; self?.outbound?.send(Data([2]) + data) }
        viewer.emergency = { [weak self] in self?.stopAll() }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.outbound?.send(Data([2]) + (try! JSONEncoder().encode(InputMessage(kind: .release)))) }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            for p in self.peers + [self.outbound].compactMap({ $0 }) where p.ready {
                if Date().timeIntervalSince(p.lastReceive) > 10 { p.close() } else { p.send(Data([3])) }
            }
        }
        window.initialFirstResponder = hostButton
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func permission() {
        if allow.state == .on && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            allow.state = .off; status.stringValue = "시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 Pulsar을 허용한 뒤 다시 체크하세요."
        }
        if allow.state == .off { injector.release() }
    }
    @objc func toggleHost() {
        if hosting { stopHost(); return }
        disconnectViewer()
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { status.stringValue = "화면 기록 권한이 필요합니다. 시스템 설정에서 Pulsar을 허용한 뒤 앱을 다시 여세요."; return }
        do {
            let t = try ConnectionCode.randomToken(); token = t
            let c = ConnectionCode(host: "localhost", port: 1, token: t); secret = c.secret
            let l = try NWListener(using: tlsParameters(secret: c.secret), on: .any)
            listener = l; hosting = true; hostButton.title = "호스트 중지"
            l.stateUpdateHandler = { [weak self, weak l] state in
                guard let self = self, self.listener === l else { return }
                switch state {
                case .ready: self.status.stringValue = "호스트 대기 중. 연결코드를 복사해 상대 Mac에 전달하세요."
                case .failed: self.stopHost(); self.status.stringValue = "호스트 시작에 실패했습니다."
                default: break
                }
            }
            l.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            l.start(queue: .main)
        } catch { stopHost(); status.stringValue = "보안 호스트를 시작할 수 없습니다." }
    }
    func accept(_ c: NWConnection) {
        guard hosting, active == nil, peers.count < 3 else { c.cancel(); return }
        let p = Peer(c); peers.append(p)
        p.onReady = { [weak self, weak p] in
            guard let self = self, let p = p, self.hosting, self.active == nil else { p?.close(); return }
            self.active = p
            for other in self.peers where other !== p { other.close() }
            self.status.stringValue = "암호화 연결됨. 화면 전송 중. 입력 허용은 체크박스로 제어합니다."
            let capture = Capture(); self.capture = capture
            capture.onFrame = { [weak self, weak p, weak capture] data, sent in guard let self = self, let capture = capture, self.active === p, self.capture === capture else { return }; p?.frame(data, sent: sent) }
            capture.onError = { [weak self, weak p] message in guard let self = self, self.active === p else { return }; p?.close(); self.status.stringValue = message }
            Task { @MainActor in
                do { try await capture.start(); if self.active === p { self.injector.rect = capture.rect } else { capture.stop() } }
                catch { guard self.active === p, self.capture === capture else { return }; p.close(); self.status.stringValue = "화면 캡처 실패. 화면 기록 권한과 로그인 상태를 확인하세요." }
            }
        }
        p.onPacket = { [weak self, weak p] data in
            guard let self = self, let p = p, self.active === p else { return }
            if data == Data([3]) { return }
            guard data.first == 2, data.count <= 2048, let m = try? JSONDecoder().decode(InputMessage.self, from: data.dropFirst()), m.valid else { p.close(); return }
            if m.kind == .release { self.injector.release() }
            else if self.allow.state == .on && AXIsProcessTrusted() { self.injector.apply(m) }
        }
        p.onClose = { [weak self, weak p] in
            guard let self = self, let p = p else { return }
            self.peers.removeAll { $0 === p }
            if self.active === p { self.active = nil; self.capture?.stop(); self.capture = nil; self.injector.release(); self.status.stringValue = "연결 해제됨. 호스트는 대기 중입니다." }
        }
        p.start()
    }
    @objc func copyCode() {
        guard hosting, let t = token, let port = listener?.port?.rawValue else { status.stringValue = "먼저 호스트를 시작하세요."; return }
        let c = ConnectionCode(host: ips[addresses.indexOfSelectedItem], port: port, token: t)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(c.text, forType: .string)
        status.stringValue = "연결코드 복사됨. 호스트 주소 \(c.host), 포트 \(port). 코드는 비밀값입니다."
    }
    @objc func connectViewer() {
        guard !hosting else { status.stringValue = "뷰어로 접속하려면 호스트를 중지하세요."; return }
        do {
            let c = try ConnectionCode.parse(code.stringValue); disconnectViewer(); code.stringValue = ""
            let p = Peer(NWConnection(host: NWEndpoint.Host(c.host), port: NWEndpoint.Port(rawValue: c.port)!, using: tlsParameters(secret: c.secret)))
            outbound = p; status.stringValue = "TLS 인증 중..."
            p.onReady = { [weak self] in self?.status.stringValue = "암호화 연결됨. 화면을 클릭해 입력하세요. Command+Option+Escape는 긴급 중지입니다." }
            p.onPacket = { [weak self, weak p] data in
                if data == Data([3]) { return }
                guard let self = self, let frame = try? VideoFrame.parse(data), self.viewer.show(frame) else { p?.close(); return }
            }
            p.onClose = { [weak self, weak p] in guard let self = self, self.outbound === p else { return }; self.outbound = nil; self.viewer.clear(); self.status.stringValue = "연결 종료. 코드, 네트워크와 Tailscale 상태를 확인하세요. 잘못된 비밀키도 거부됩니다." }
            p.start()
        } catch { status.stringValue = "유효하지 않은 연결코드입니다." }
    }
    @objc func disconnectViewer() { outbound?.close(); outbound = nil; viewer.clear() }
    func stopHost() {
        hosting = false; listener?.cancel(); listener = nil
        for p in peers { p.close() }; peers.removeAll(); active = nil
        capture?.stop(); capture = nil; injector.release(); token = nil; secret = nil
        allow.state = .off; hostButton.title = "호스트 시작"; status.stringValue = "호스트가 중지되었습니다."
    }
    @objc func stopAll() { stopHost(); disconnectViewer(); status.stringValue = "모든 연결을 중지했습니다. 새 호스트 세션은 새 비밀키를 만듭니다." }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { stopAll(); timer?.invalidate() }
}
