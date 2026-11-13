import AppKit
import ApplicationServices

struct Permission {
    let title: String
    let use: String
    let pane: String
    let granted: () -> Bool
    let request: () -> Void
    var grantedText = "허용됨"

    static let all = [
        Permission(title: "화면 기록", use: "호스트: 이 Mac 화면을 보낼 때",
                   pane: "Privacy_ScreenCapture",
                   granted: { CGPreflightScreenCaptureAccess() },
                   request: { _ = CGRequestScreenCaptureAccess() }),
        Permission(title: "손쉬운 사용", use: "호스트: 원격 마우스와 키보드 입력 / 뷰어: 시스템 단축키 전달",
                   pane: "Privacy_Accessibility",
                   granted: { AXIsProcessTrusted() },
                   request: { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }),
        // macOS answers "can listen" here, and Accessibility alone already makes that true,
        // so this can read as available while Pulsar is absent from the Input Monitoring list.
        Permission(title: "입력 모니터링", use: "뷰어: 단축키와 트랙패드 제스처 전달. 손쉬운 사용이 허용되면 목록에 없어도 사용 가능으로 표시됩니다.",
                   pane: "Privacy_ListenEvent",
                   granted: { CGPreflightListenEventAccess() },
                   request: { _ = CGRequestListenEventAccess() },
                   grantedText: "사용 가능"),
    ]

    func openSettings() {
        // Requesting first makes macOS add Pulsar to the list, so the user only has to flip the switch.
        if !granted() { request() }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

final class PermissionsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var labels: [NSTextField] = []
    private var timer: Timer?

    func show() {
        if window == nil { build() }
        refresh()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 260), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Pulsar 환경설정"
        w.isReleasedWhenClosed = false
        w.delegate = self
        let root = NSStackView()
        root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        root.addArrangedSubview(NSTextField(labelWithString: "필요한 macOS 권한"))
        for (index, p) in Permission.all.enumerated() {
            let status = NSTextField(labelWithString: "")
            status.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            labels.append(status)
            let text = NSStackView(views: [NSTextField(labelWithString: p.title), status])
            text.spacing = 8
            let use = NSTextField(labelWithString: p.use)
            use.textColor = .secondaryLabelColor
            use.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            let column = NSStackView(views: [text, use]); column.orientation = .vertical; column.alignment = .leading; column.spacing = 2
            let button = NSButton(title: "설정 열기", target: self, action: #selector(open(_:)))
            button.tag = index
            let row = NSStackView(views: [column, NSView(), button])
            row.distribution = .fill
            root.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: 524).isActive = true
        }
        let note = NSTextField(wrappingLabelWithString: "권한을 바꾼 뒤에는 Pulsar를 종료했다가 다시 열어야 적용될 수 있습니다. 화면 기록은 다시 열기 전까지 허용 안 됨으로 보일 수 있습니다.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 524
        root.addArrangedSubview(note)
        w.contentView = root
        window = w
    }

    private func refresh() {
        for (label, p) in zip(labels, Permission.all) {
            let ok = p.granted()
            label.stringValue = ok ? p.grantedText : "허용 안 됨"
            label.textColor = ok ? .systemGreen : .systemRed
        }
    }

    @objc private func open(_ sender: NSButton) { Permission.all[sender.tag].openSettings() }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }
}
