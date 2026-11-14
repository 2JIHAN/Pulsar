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
        Permission(title: "기기 제어 및 데이터 접근", use: "호스트: 원격 마우스와 키보드 입력 / 뷰어: 시스템 단축키 전달",
                   pane: "Privacy_Accessibility",
                   granted: { AXIsProcessTrusted() },
                   request: { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }),
        // macOS answers "can listen" here, and Accessibility alone already makes that true,
        // so this can read as available while Pulsar is absent from the Input Monitoring list.
        Permission(title: "입력 모니터링", use: "뷰어: 단축키와 트랙패드 제스처 전달. 기기 제어 및 데이터 접근이 허용되면 목록에 없어도 사용 가능으로 표시됩니다.",
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

