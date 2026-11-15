import AppKit
import ScreenCaptureKit
import VideoToolbox
import ApplicationServices

final class VideoEncoder {
    static let supportsHardwareHEVC: Bool = {
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        guard VTCompressionSessionCreate(allocator: nil, width: 1280, height: 720, codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created) == noErr, let s = created else { return false }
        defer { VTCompressionSessionInvalidate(s) }
        return VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel) == noErr
    }()

    private let session: VTCompressionSession
    let effectiveQuality: EffectiveQuality
    private let stream: UInt8?
    private let onOutput: (Data?) -> Void

    private static func makeSession(width: Int, height: Int, quality: EffectiveQuality) -> VTCompressionSession? {
        var created: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let codec: CMVideoCodecType = quality.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let imageAttrs: CFDictionary? = (quality.codec == .hevc && quality.chroma == .yuv444)
            ? [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange] as CFDictionary
            : nil
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec, encoderSpecification: spec, imageBufferAttributes: imageAttrs, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created) == noErr, let session = created else { return nil }
        let profile: CFString = quality.codec == .h264
            ? kVTProfileLevel_H264_High_AutoLevel
            : (quality.chroma == .yuv444 ? ("HEVC_Main444_AutoLevel" as CFString) : kVTProfileLevel_HEVC_Main_AutoLevel)
        let avgBitrate = quality.bitrateMbps * 1_000_000
        let peakBytesPerSecond = quality.bitrateMbps * 187_500 // 1.5x average in bytes/sec
        let fps = quality.fps.rawValue
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_AverageBitRate: avgBitrate,
            kVTCompressionPropertyKey_DataRateLimits: [peakBytesPerSecond, 1],
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * 2,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2,
        ]
        guard VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr, VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            return nil
        }
        return session
    }

    // onOutput runs on a VideoToolbox thread with a wire message, or nil when the frame was dropped.
    init(width: Int, height: Int, quality: EffectiveQuality = .legacyDefaults, stream: UInt8? = nil, onOutput: @escaping (Data?) -> Void) throws {
        var resolved = quality
        var created = Self.makeSession(width: width, height: height, quality: resolved)
        if created == nil, resolved.codec == .hevc && resolved.chroma == .yuv444 {
            resolved.chroma = .yuv420
            created = Self.makeSession(width: width, height: height, quality: resolved)
        }
        guard let session = created else { throw WireError.invalid }
        self.session = session
        self.effectiveQuality = resolved
        self.stream = stream
        self.onOutput = onOutput
    }
    deinit { VTCompressionSessionInvalidate(session) }
    func encode(_ pixel: CVImageBuffer, time: CMTime, keyframe: Bool) -> Bool {
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let codec = effectiveQuality.codec, stream = stream
        return VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: time, duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [onOutput] status, _, sample in
            onOutput(status == noErr ? sample.flatMap { videoMessage($0, codec: codec, stream: stream) } : nil)
        } == noErr
    }
}
final class VirtualDisplay {
    static var isAvailable: Bool { PulsarVirtualDisplayAPIAvailable() }
    private var handle: NSObject?
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int
    let scale: Int

    init?(width: Int, height: Int, scale: Int) {
        guard Self.isAvailable,
              (640...6016).contains(width), (480...3384).contains(height),
              scale == 1 || scale == 2 else { return nil }
        let pointW = scale == 2 ? width / 2 : width
        let pointH = scale == 2 ? height / 2 : height
        let pixelW = pointW * scale
        let pixelH = pointH * scale

        var preIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var preCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &preIDs, &preCount)
        let preList = preIDs.prefix(Int(preCount))

        var createdID: CGDirectDisplayID = 0
        guard let disp = PulsarCreateVirtualDisplay(UInt32(pixelW), UInt32(pixelH), UInt32(scale), &createdID),
              createdID != 0,
              !preList.contains(createdID) else { return nil }

        self.handle = disp
        self.displayID = createdID
        self.pixelWidth = pixelW
        self.pixelHeight = pixelH
        self.scale = scale

    }

    func destroy() { handle = nil }
    deinit { handle = nil }
}

final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    var stream: SCStream?
    // The completion must be called once the frame has been handed to the network.
    var onFrame: ((Data, @escaping () -> Void) -> Void)?
    var onError: ((String) -> Void)?
    var rect = CGRect.zero
    var displayID: CGDirectDisplayID = 0
    var outputSize = (width: 0, height: 0)
    // Viewer screen id written into every frame; nil keeps the 0.8 wire format.
    var streamIndex: UInt8?
    var active = false
    private var stopped = false
    private let queue = DispatchQueue(label: "Pulsar.capture")
    private var encoder: VideoEncoder?
    // Owned by queue. Captured frames are skipped before encoding while two are in flight,
    // because dropping an encoded frame would break the decoder's reference chain.
    private var inFlight = 0
    private var needsKeyframe = true
    func requestKeyframe() { queue.async { self.needsKeyframe = true } }
    // `targetDisplayID` nil captures the main display. A virtual target may need a moment to report its mode.
    @MainActor func start(request: QualityRequest? = nil, targetDisplayID: CGDirectDisplayID? = nil, isVirtual: Bool = false, fallbackPixelSize: (Int, Int)? = nil) async throws -> EffectiveQuality {
        guard !stopped else { throw WireError.invalid }
        let display: SCDisplay
        if let targetDisplayID {
            var matched: SCDisplay?
            for attempt in 0..<10 {
                guard !stopped else { throw WireError.invalid }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                if let found = content.displays.first(where: { $0.displayID == targetDisplayID }) {
                    let mode = CGDisplayCopyDisplayMode(targetDisplayID)
                    if (mode?.pixelWidth ?? 0) > 0 || attempt == 9 {
                        matched = found
                        break
                    }
                }
                if attempt < 9 { try await Task.sleep(nanoseconds: 200_000_000) }
            }
            guard let matched else { throw WireError.invalid }
            display = matched
        } else {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !stopped else { throw WireError.invalid }
            guard let found = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else { throw WireError.invalid }
            display = found
        }
        guard !stopped else { throw WireError.invalid }
        rect = CGDisplayBounds(display.displayID)
        displayID = display.displayID
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let modeW = mode?.pixelWidth ?? 0, modeH = mode?.pixelHeight ?? 0
        let width = Double(modeW > 0 ? modeW : (fallbackPixelSize?.0 ?? display.width))
        let height = Double(modeH > 0 ? modeH : (fallbackPixelSize?.1 ?? display.height))
        let targetQuality = request.map { EffectiveQuality.resolve($0, hostHEVCEncode: VideoEncoder.supportsHardwareHEVC, virtualDisplay: isVirtual) } ?? .legacyDefaults
        let bounds = request == nil ? (1920.0, 1200.0) : targetQuality.maxResolution.maxBounds
        let scaled = MaxResolutionOption.scaledSize(displayWidth: width, displayHeight: height, bounds: bounds)
        outputSize = scaled

        func startWith(_ quality: EffectiveQuality) async throws -> EffectiveQuality {
            let encoder = try VideoEncoder(width: scaled.width, height: scaled.height, quality: quality, stream: streamIndex) { [weak self] message in self?.deliver(message) }
            let actual = encoder.effectiveQuality
            let config = SCStreamConfiguration()
            config.width = scaled.width
            config.height = scaled.height
            config.pixelFormat = actual.chroma == .yuv444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(actual.fps.rawValue))
            config.queueDepth = 3; config.showsCursor = true; config.capturesAudio = false
            queue.sync { self.encoder = encoder; self.needsKeyframe = true; self.inFlight = 0 }
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            stream = s; active = true
            do {
                try await s.startCapture()
                if stopped { try? await s.stopCapture(); throw WireError.invalid }
                return actual
            } catch {
                active = false; stream = nil
                throw error
            }
        }

        do {
            return try await startWith(targetQuality)
        } catch where targetQuality.chroma == .yuv444 && !stopped {
            var fallback = targetQuality; fallback.chroma = .yuv420
            return try await startWith(fallback)
        }
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
    // Host display bounds per viewer screen id. Each stream maps 0...1 into its own display.
    var rects = [Int: CGRect]()
    var keys = Set<UInt16>()
    var buttons = Set<UInt16>()
    var modifiers = Set<UInt16>()
    var lastPoint = CGPoint.zero
    func apply(_ m: InputMessage) {
        guard m.valid else { return }
        if m.kind == .release { release(); return }
        // Keys carry no point, but the shared guard below needs a valid rect. Pointer events need their own screen.
        let isKey = m.kind == .keyDown || m.kind == .keyUp || m.kind == .flags
        let rect = rects[m.screen ?? 0] ?? (isKey ? rects.values.first : nil) ?? .zero
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
