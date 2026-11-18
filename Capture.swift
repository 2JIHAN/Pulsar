import AppKit
import ScreenCaptureKit
import VideoToolbox
import ApplicationServices

// Periodic keyframes cost 25-100 P-frames each (measured: ~0.6-0.8 MB vs 8-33 KB at 1440p60 20 Mbps),
// a burst every interval that queues behind itself on a slow link. A 0.10 viewer asks for one when it
// needs it, so it only gets a 60 s safety keyframe that bounds any corruption nobody detected.
// 0.8/0.9 viewers never ask after a renderer failure, so they keep the 2 s interval.
func keyframeInterval(fps: Int, onDemand: Bool) -> (frames: Int, seconds: Int) {
    onDemand ? (fps * 60, 60) : (fps * 2, 2)
}
enum EncodedFrame { case message(Data), dropped, failed }
// Pure, called once per second per stream. Ceiling is the user's 비트레이트 setting.
// Congestion: frames skipped because two were already in flight, encoder-output -> send-done time
// over three frame intervals, or RTT above the 30 s minimum by max(20 ms, that minimum).
// Congestion cuts 30% (then holds 2 s so the queue can drain); 5 calm seconds start +5% of the ceiling per second.
struct BitrateController {
    let ceiling: Int, floor: Int
    private(set) var target: Int
    private var calm = 0, hold = 0
    private var rtts = [Double]()
    init(ceilingBps: Int) {
        ceiling = ceilingBps; floor = min(ceilingBps, max(2_000_000, ceilingBps / 4)); target = ceilingBps
    }
    // Returns true when the target changed.
    mutating func update(skipped: Int, sendMs: Double?, rttMs: Double?, frameMs: Double) -> Bool {
        var rttRise = false
        if let r = rttMs {
            rtts.append(r); if rtts.count > 30 { rtts.removeFirst() }
            let base = rtts.min()!
            rttRise = r > base + max(20, base)
        }
        let congested = skipped >= 2 || rttRise || (sendMs ?? 0) > 3 * frameMs
        let old = target, held = hold > 0
        if held { hold -= 1 }
        if congested {
            calm = 0
            if !held { target = max(floor, Int(Double(target) * 0.7)); hold = 2 }
        } else {
            calm += 1
            if calm >= 5 { target = min(ceiling, target + max(250_000, ceiling / 20)) }
        }
        return target != old
    }
}
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
    private let onOutput: (EncodedFrame) -> Void

    private static func makeSession(width: Int, height: Int, quality: EffectiveQuality, onDemandKeyframes: Bool) -> VTCompressionSession? {
        var created: VTCompressionSession?
        // Not low-latency rate control: measured at 1440p60 5 Mbps it dropped 184-186 of 300 frames
        // (normal control dropped none) for under 1 ms of encode time, which fights the adaptive bitrate.
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
        let keyframes = keyframeInterval(fps: fps, onDemand: onDemandKeyframes)
        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_AverageBitRate: avgBitrate,
            kVTCompressionPropertyKey_DataRateLimits: [peakBytesPerSecond, 1],
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: keyframes.frames,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: keyframes.seconds,
        ]
        guard VTSessionSetProperties(session, propertyDictionary: properties as CFDictionary) == noErr, VTCompressionSessionPrepareToEncodeFrames(session) == noErr else {
            VTCompressionSessionInvalidate(session)
            return nil
        }
        return session
    }

    // onOutput runs on a VideoToolbox thread. `.dropped` is a frame the rate controller skipped, which
    // leaves the reference chain intact; `.failed` means the viewer needs a keyframe.
    init(width: Int, height: Int, quality: EffectiveQuality = .legacyDefaults, stream: UInt8? = nil, onDemandKeyframes: Bool = false, onOutput: @escaping (EncodedFrame) -> Void) throws {
        var resolved = quality
        func make(_ q: EffectiveQuality) -> VTCompressionSession? {
            Self.makeSession(width: width, height: height, quality: q, onDemandKeyframes: onDemandKeyframes)
        }
        var created = make(resolved)
        if created == nil, resolved.codec == .hevc && resolved.chroma == .yuv444 {
            resolved.chroma = .yuv420
            created = make(resolved)
        }
        guard let session = created else { throw WireError.invalid }
        self.session = session
        self.effectiveQuality = resolved
        self.stream = stream
        self.onOutput = onOutput
    }
    deinit { VTCompressionSessionInvalidate(session) }
    // Live change; both properties are accepted mid-session (measured, output follows within a second).
    func setBitrate(_ bps: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bps * 3 / 16, 1] as CFArray)
    }
    // `timing` (without the encode time) goes into the frame for 0.10 viewers; `capturedAt` is mach host time.
    func encode(_ pixel: CVImageBuffer, time: CMTime, keyframe: Bool, timing: FrameTiming? = nil, capturedAt: UInt64 = 0) -> Bool {
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let codec = effectiveQuality.codec, stream = stream
        return VTCompressionSessionEncodeFrame(session, imageBuffer: pixel, presentationTimeStamp: time, duration: .invalid, frameProperties: options, infoFlagsOut: nil) { [onOutput] status, flags, sample in
            guard status == noErr else { onOutput(.failed); return }
            // A frame the encoder drops arrives with .frameDropped; a 0.10 viewer re-asks for a keyframe after 2 s if needed.
            guard let sample else { onOutput(flags.contains(.frameDropped) ? .dropped : .failed); return }
            var t = timing
            t?.encodeTenthsMs = FrameTiming(encodeMs: hostTimeMs(since: capturedAt), skipped: 0, bitrateBps: 0).encodeTenthsMs
            onOutput(videoMessage(sample, codec: codec, stream: stream, timing: t).map { .message($0) } ?? .failed)
        } == noErr
    }
}
private let hostTimebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()
func hostTimeMs(since start: UInt64, now: UInt64 = mach_absolute_time()) -> Double {
    guard start > 0, now > start else { return 0 }
    return Double(now - start) * Double(hostTimebase.numer) / Double(hostTimebase.denom) / 1_000_000
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
    // Owned by queue. `timing`: the viewer announced 0.10 timing support. `bitrate` is nil when the
    // viewer turned automatic adjustment off or is older than 0.10.
    private var timing = false
    private var bitrate: BitrateController?
    private var ceilingBps = 0, fps = 30
    private var skippedSinceFrame = 0, skippedThisSecond = 0
    private var sendMsSum = 0.0, sendCount = 0
    func requestKeyframe() { queue.async { self.needsKeyframe = true } }
    // Called once per second on main with the newest timed-ping RTT, if one arrived.
    func tick(rttMs: Double?) {
        queue.async {
            let skipped = self.skippedThisSecond, send = self.sendCount > 0 ? self.sendMsSum / Double(self.sendCount) : nil
            self.skippedThisSecond = 0; self.sendMsSum = 0; self.sendCount = 0
            if self.bitrate?.update(skipped: skipped, sendMs: send, rttMs: rttMs, frameMs: 1000 / Double(self.fps)) == true, let b = self.bitrate {
                self.encoder?.setBitrate(b.target)
            }
        }
    }
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
            let encoder = try VideoEncoder(width: scaled.width, height: scaled.height, quality: quality, stream: streamIndex, onDemandKeyframes: quality.timing) { [weak self] out in self?.deliver(out) }
            let actual = encoder.effectiveQuality
            let config = SCStreamConfiguration()
            config.width = scaled.width
            config.height = scaled.height
            config.pixelFormat = actual.chroma == .yuv444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(actual.fps.rawValue))
            config.queueDepth = 3; config.showsCursor = capturesCursor(request); config.capturesAudio = false
            let adaptive = request?.adaptive == true
            queue.sync {
                self.encoder = encoder; self.needsKeyframe = true; self.inFlight = 0
                self.timing = actual.timing; self.fps = actual.fps.rawValue; self.ceilingBps = actual.bitrateMbps * 1_000_000
                self.bitrate = adaptive ? BitrateController(ceilingBps: self.ceilingBps) : nil
                self.skippedSinceFrame = 0; self.skippedThisSecond = 0; self.sendMsSum = 0; self.sendCount = 0
            }
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
        guard type == .screen, let encoder, let pixel = CMSampleBufferGetImageBuffer(sampleBuffer),
              let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = info.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue else { return }
        guard inFlight < 2 else { skippedSinceFrame += 1; skippedThisSecond += 1; return }
        // displayTime is mach host time of the screen update; arrival time stands in if it is missing.
        let captured = (info.first?[.displayTime] as? UInt64).flatMap { $0 > 0 && $0 <= mach_absolute_time() ? $0 : nil } ?? mach_absolute_time()
        let t = timing ? FrameTiming(encodeMs: 0, skipped: skippedSinceFrame, bitrateBps: bitrate?.target ?? ceilingBps) : nil
        inFlight += 1
        if encoder.encode(pixel, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), keyframe: needsKeyframe, timing: t, capturedAt: captured) {
            needsKeyframe = false; skippedSinceFrame = 0
        } else { needsKeyframe = true; inFlight -= 1 }
    }
    private func deliver(_ out: EncodedFrame) {
        guard case .message(let message) = out else {
            queue.async { if case .failed = out { self.needsKeyframe = true }; self.inFlight -= 1 }
            return
        }
        let encoded = mach_absolute_time()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, let onFrame = self.onFrame else { return }
            onFrame(message) {
                let ms = hostTimeMs(since: encoded)
                self.queue.async { self.inFlight -= 1; self.sendMsSum += ms; self.sendCount += 1 }
            }
        }
    }
}
// 0.11 viewers draw the cursor themselves from CursorUpdate; older ones need it in the video.
func capturesCursor(_ request: QualityRequest?) -> Bool { request?.cursor != true }

@_silgen_name("CGSCurrentCursorSeed") private func CGSCurrentCursorSeed() -> Int32
// Deprecated and unavailable to Swift, but on macOS 27.2.1 it still reads the window server's global
// state: measured 0 while another process hid the cursor or it was hidden until the mouse moves, 1 otherwise.
@_silgen_name("CGCursorIsVisible") private func CGCursorIsVisibleGlobal() -> Int32

extension CursorUpdate.Image {
    // At most 2x and at most 256 px on the long side; a 1x viewer screen downsamples.
    static func renderScale(width: Double, height: Double) -> Double { min(2, Double(CursorUpdate.maxPixels) / max(1, width, height)) }
    // NSCursor.currentSystem is the cursor any app has set (measured with another process setting
    // I-beam and resize cursors). Its image has 1x to 10x representations, so it is redrawn at a bounded size.
    init?(cursor: NSCursor) {
        let size = cursor.image.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let scale = Self.renderScale(width: size.width, height: size.height)
        let pw = max(1, Int((size.width * scale).rounded())), ph = max(1, Int((size.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        cursor.image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        self.init(png: png, pixelWidth: pw, pixelHeight: ph, width: size.width, height: size.height, hotX: cursor.hotSpot.x, hotY: cursor.hotSpot.y)
        guard valid else { return nil }
    }
    // Viewer side. nil when the PNG does not decode to the announced pixel size.
    func cursor() -> NSCursor? {
        guard valid, let rep = NSBitmapImageRep(data: png), rep.pixelsWide == pixelWidth, rep.pixelsHigh == pixelHeight else { return nil }
        rep.size = NSSize(width: width, height: height)
        let image = NSImage(size: rep.size); image.addRepresentation(rep)
        return NSCursor(image: image, hotSpot: NSPoint(x: hotX, y: hotY))
    }
}
// Host: polls the system cursor at 60 Hz while a 0.11 viewer is connected. The seed changes with the
// shape (~0.04 ms per read); the image is only fetched and encoded when it does (~0.5 ms).
// Cursor warps by host apps are not reported; the viewer's own pointer position stays authoritative.
final class CursorTracker {
    var send: ((CursorUpdate) -> Void)?
    private var timer: Timer?
    private var seed: Int32?
    private var shape: (hash: String, image: CursorUpdate.Image)?
    private var sentHash: String?, sentVisible: Bool?
    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
    }
    func stop() { timer?.invalidate(); timer = nil; seed = nil; shape = nil; sentHash = nil; sentVisible = nil }
    private func tick() {
        let s = CGSCurrentCursorSeed()
        if s != seed, let c = NSCursor.currentSystem, let image = CursorUpdate.Image(cursor: c) {
            seed = s; shape = (fnv1a64(image.png), image)
        }
        guard let shape, let u = CursorUpdate.next(hash: shape.hash, image: shape.image, visible: CGCursorIsVisibleGlobal() != 0, sentHash: sentHash, sentVisible: sentVisible) else { return }
        sentHash = u.hash; sentVisible = u.visible
        send?(u)
    }
}
final class InputInjector {
    var postEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }
    // DockSwipe replays go where Dock reads them, like ThunderControl's receiver.
    var postDock: (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }
    // The DockSwipe stream being replayed; cancelled by release() so Dock is not left mid-swipe.
    private(set) var dock: DockGesture?
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
    func applyDock(_ d: DockGesture) {
        guard d.valid else { return }
        if d.phase == 1 { if let old = dock { postDockEvent(old.cancelled) } }
        else if dock?.motion != d.motion { return }
        dock = d.terminal ? nil : d
        postDockEvent(d)
    }
    private func postDockEvent(_ d: DockGesture) {
        guard let event = d.event() else { return }
        event.location = CGEvent(source: nil)?.location ?? lastPoint
        postDock(event)
    }
    func release() {
        if let d = dock { dock = nil; postDockEvent(d.cancelled) }
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
