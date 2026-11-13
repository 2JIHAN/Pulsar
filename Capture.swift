import AppKit
import ScreenCaptureKit
import VideoToolbox
import ApplicationServices

final class VideoEncoder {
    private let session: VTCompressionSession
    private let onOutput: (Data?) -> Void
    // onOutput runs on a VideoToolbox thread with a wire message, or nil when the frame was dropped.
    init(width: Int, height: Int, onOutput: @escaping (Data?) -> Void) throws {
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created) == noErr, let session = created else { throw WireError.invalid }
        self.session = session; self.onOutput = onOutput
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: 6_000_000,
            kVTCompressionPropertyKey_DataRateLimits: [1_125_000, 1], // bytes per second: 9 Mbps peak
            kVTCompressionPropertyKey_ExpectedFrameRate: 30,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
        ]
        guard VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr, VTCompressionSessionPrepareToEncodeFrames(session) == noErr else { VTCompressionSessionInvalidate(session); throw WireError.invalid }
    }
    deinit { VTCompressionSessionInvalidate(session) }
    func encode(_ pixel: CVImageBuffer, time: CMTime, keyframe: Bool) -> Bool {
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        return VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: time, duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [onOutput] status, _, sample in
            onOutput(status == noErr ? sample.flatMap(videoMessage) : nil)
        } == noErr
    }
}
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    // The completion must be called once the frame has been handed to the network.
    var onFrame: ((Data, @escaping () -> Void) -> Void)?
    var onError: ((String) -> Void)?
    var rect = CGRect.zero
    var active = false
    private var stopped = false
    private let queue = DispatchQueue(label: "Pulsar.capture")
    private var encoder: VideoEncoder?
    // Owned by queue. Captured frames are skipped before encoding while two are in flight,
    // because dropping an encoded frame would break the decoder's reference chain.
    private var inFlight = 0
    private var needsKeyframe = true
    @MainActor func start() async throws {
        guard !stopped else { throw WireError.invalid }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !stopped else { throw WireError.invalid }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw WireError.invalid }
        rect = CGDisplayBounds(display.displayID)
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let width = Double(mode?.pixelWidth ?? display.width), height = Double(mode?.pixelHeight ?? display.height)
        let config = SCStreamConfiguration()
        let scale = min(1, min(1920 / width, 1200 / height))
        config.width = max(2, Int(width * scale) / 2 * 2)
        config.height = max(2, Int(height * scale) / 2 * 2)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3; config.showsCursor = true; config.capturesAudio = false
        let encoder = try VideoEncoder(width: config.width, height: config.height) { [weak self] message in self?.deliver(message) }
        queue.sync { self.encoder = encoder }
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
        guard type == .screen, inFlight < 2, let encoder, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer),
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        inFlight += 1
        if encoder.encode(pixel, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), keyframe: needsKeyframe) { needsKeyframe = false }
        else { needsKeyframe = true; inFlight -= 1 }
    }
    private func deliver(_ message: Data?) {
        guard let message else { queue.async { self.needsKeyframe = true; self.inFlight -= 1 }; return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let onFrame = self.onFrame else { return }
            onFrame(message) { self.queue.async { self.inFlight -= 1 } }
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
        // Gesture streams left open by a disconnect are not ended synthetically.
        if m.kind == .gesture { post(gestureEvent(m, hostBuild: osBuild, rect: rect)); return }
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
        case .release, .gesture: break
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
