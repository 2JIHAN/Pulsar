import AppKit
import ApplicationServices
import IOKit.hidsystem

struct Permission {
    let title: String
    let use: String
    let pane: String
    let verifiable: Bool
    let granted: () -> Bool
    let request: () -> Void

    static let all = [
        Permission(title: "화면 기록", use: "호스트: 이 Mac 화면을 보낼 때",
                   pane: "Privacy_ScreenCapture", verifiable: true,
                   granted: { CGPreflightScreenCaptureAccess() },
                   request: { _ = CGRequestScreenCaptureAccess() }),
        Permission(title: "기기 제어 및 데이터 접근", use: "호스트: 원격 마우스와 키보드 입력 / 뷰어: 시스템 단축키 전달",
                   pane: "Privacy_Accessibility", verifiable: true,
                   granted: { AXIsProcessTrusted() },
                   request: { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }),
        Permission(title: "입력 모니터링", use: "뷰어: 단축키와 트랙패드 제스처 전달",
                   pane: "Privacy_ListenEvent", verifiable: false,
                   granted: { IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted },
                   request: { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }),
    ]

    func openSettings() {
        // Requesting first makes macOS add Pulsar to the list, so the user only has to flip the switch.
        if !verifiable || !granted() { request() }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

