import AppKit
import ScreenCaptureKit
import CoreImage
import ApplicationServices

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    var onFrame: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    var rect = CGRect.zero
    var active = false
    private var stopped = false
    private let queue = DispatchQueue(label: "Pulsar.capture")
    private let context = CIContext()
    private let delivery = DispatchSemaphore(value: 1)
    @MainActor func start() async throws {
        guard !stopped else { throw WireError.invalid }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !stopped else { throw WireError.invalid }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw WireError.invalid }
        rect = CGDisplayBounds(display.displayID)
        let config = SCStreamConfiguration()
        let scale = min(1, min(1440 / Double(display.width), 900 / Double(display.height)))
        config.width = max(2, Int(Double(display.width) * scale) / 2 * 2)
        config.height = max(2, Int(Double(display.height) * scale) / 2 * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.queueDepth = 3; config.showsCursor = true; config.capturesAudio = false
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = s; active = true
        do {
            try await s.startCapture()
            if stopped { try? await s.stopCapture(); throw WireError.invalid }
        } catch { active = false; stream = nil; throw error }
    }
    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopped = true; active = false
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?("화면 캡처가 중단되었습니다.") }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer), delivery.wait(timeout: .now()) == .success else { return }
        guard let cg = context.createCGImage(CIImage(cvPixelBuffer: pixel), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))),
              let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.55]), jpeg.count + 1 <= PacketParser.limit else { delivery.signal(); return }
        DispatchQueue.main.async { [weak self] in
            defer { self?.delivery.signal() }
            guard let self = self, self.active else { return }
            self.onFrame?(Data([1]) + jpeg)
        }
    }
}
final class InputInjector {
    var postEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    private func post(_ event: CGEvent?) { if let event = event { postEvent(event) } }
    var rect = CGRect.zero
    var keys = Set<UInt16>()
    var buttons = Set<UInt16>()
    var modifiers = Set<UInt16>()
    var lastPoint = CGPoint.zero
    func apply(_ m: InputMessage) {
        guard m.valid else { return }
        if m.kind == .release { release(); return }
        guard let point = normalizedPoint(x: m.x, y: m.y, rect: rect) else { return }
        let flags = CGEventFlags(rawValue: m.flags & 0x00ff0000)
        var event: CGEvent?
        switch m.kind {
        case .move:
            let type: CGEventType = buttons.contains(0) ? .leftMouseDragged : buttons.contains(1) ? .rightMouseDragged : buttons.isEmpty ? .mouseMoved : .otherMouseDragged
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: CGMouseButton(rawValue: UInt32(buttons.contains(0) ? 0 : buttons.contains(1) ? 1 : buttons.contains(2) ? 2 : 0)) ?? .left)
            lastPoint = point
        case .down, .up:
            guard m.code <= 2 else { return }
            let down = m.kind == .down
            if down { buttons.insert(m.code) } else { buttons.remove(m.code) }
            let type: CGEventType = m.code == 0 ? (down ? .leftMouseDown : .leftMouseUp) : m.code == 1 ? (down ? .rightMouseDown : .rightMouseUp) : (down ? .otherMouseDown : .otherMouseUp)
            event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: CGMouseButton(rawValue: UInt32(m.code))!)
            lastPoint = point
        case .scroll:
            event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(m.dy), wheel2: Int32(m.dx), wheel3: 0)
            event?.location = point
        case .keyDown, .keyUp:
            if m.kind == .keyDown { keys.insert(m.code) } else { keys.remove(m.code) }
            event = CGEvent(keyboardEventSource: nil, virtualKey: m.code, keyDown: m.kind == .keyDown)
        case .flags:
            let masks: [UInt16: CGEventFlags] = [54: .maskCommand, 55: .maskCommand, 56: .maskShift, 60: .maskShift, 58: .maskAlternate, 61: .maskAlternate, 59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn]
            if let mask = masks[m.code], flags.contains(mask) { modifiers.insert(m.code) } else { modifiers.remove(m.code) }
            event = CGEvent(keyboardEventSource: nil, virtualKey: m.code, keyDown: false); event?.type = .flagsChanged
        case .release: break
        }
        event?.flags = flags; post(event)
    }
    func release() {
        for key in keys { post(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)) }
        for b in buttons {
            let type: CGEventType = b == 0 ? .leftMouseUp : b == 1 ? .rightMouseUp : .otherMouseUp
            post(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: lastPoint, mouseButton: CGMouseButton(rawValue: UInt32(b))!))
        }
        for key in modifiers {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
            event?.flags = []; event?.type = .flagsChanged; post(event)
        }
        keys.removeAll(); buttons.removeAll(); modifiers.removeAll()
    }
}
