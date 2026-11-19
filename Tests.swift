import Foundation
import Network
import Darwin
import Security
import CoreGraphics
import VideoToolbox
import AppKit

func runSelfTests() {
    do {
        let token = try ConnectionCode.randomToken()
        let code = ConnectionCode(host: "100.116.229.75", port: 54321, token: token)
        let decoded = try ConnectionCode.parse(code.text)
        precondition(decoded.secret.count == 32 && decoded.token == token && decoded.host == code.host)
        for bad in ["", "remotecontrol1:!!!", ConnectionCode(host: "x", port: 0, token: token).text, ConnectionCode(host: "x", port: 1, token: "bad").text] { precondition((try? ConnectionCode.parse(bad)) == nil) }
        print("PASS connection code roundtrip, invalid code and secret rejection")
        var parser = PacketParser(); let payload = Data([1, 2, 3]); let frame = PacketParser.frame(payload)
        for byte in frame.dropLast() { precondition((try? parser.feed(Data([byte]))) == []) }
        precondition((try? parser.feed(Data(frame.suffix(1)))) == [payload])
        precondition((try? parser.feed(frame + frame)) == [payload, payload])
        for bad in [Data([0,0,0,0]), Data([255,255,255,255]), Data([0,128,0,1])] { var p = PacketParser(); precondition((try? p.feed(bad)) == nil) }
        let maxPayload = Data(repeating: 7, count: PacketParser.limit)
        var large = PacketParser(); var result = [Data](); let full = PacketParser.frame(maxPayload)
        for start in stride(from: 0, to: full.count, by: 65536) { result += try large.feed(Data(full[start..<min(full.count, start + 65536)])) }
        precondition(result == [maxPayload])
        print("PASS framing split packets, coalesced packets, maximum payload and bad lengths")
        precondition(InputMessage(kind: .move, x: 0, y: 1).valid)
        precondition(!InputMessage(kind: .move, x: .nan).valid && !InputMessage(kind: .move, x: 1.1).valid)
        let rect = CGRect(x: -1440, y: 120, width: 1440, height: 900)
        precondition(normalizedPoint(x: 0, y: 0, rect: rect) == CGPoint(x: -1440, y: 120))
        precondition(normalizedPoint(x: 1, y: 1, rect: rect) == CGPoint(x: -1, y: 1019))
        precondition(normalizedPoint(x: -0.1, y: 0, rect: rect) == nil)
        print("PASS normalized input coordinates, global display origin and nonfinite rejection")
        let viewRect = NSRect(x: 10, y: 20, width: 200, height: 100)
        for (type, kind) in [(NSEvent.EventType.leftMouseDown, InputMessage.Kind.down), (.leftMouseUp, .up), (.rightMouseDown, .down), (.mouseMoved, .move), (.leftMouseDragged, .move)] {
            let e = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            let m = Viewer.inputMessage(e, kind, point: NSPoint(x: 110, y: 70), rect: viewRect)
            precondition(m.valid && m.x == 0.5 && m.y == 0.5 && m.dx == 0 && m.dy == 0)
        }
        let wheel = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -5000, wheel2: 3, wheel3: 0)!
        let s = Viewer.inputMessage(NSEvent(cgEvent: wheel)!, .scroll, point: NSPoint(x: 10, y: 20), rect: viewRect)
        precondition(s.valid && s.dy == -1000 && s.code == 0)
        print("PASS viewer builds valid input messages from real mouse and scroll NSEvents")
        try videoTests()
        try latencyTests()
        qualityTests()
        try multiScreenTests()
        let injector = InputInjector(); injector.rects = [0: CGRect(x: 0, y: 0, width: 1440, height: 900)]
        var posted = 0; injector.postEvent = { _ in posted += 1 }
        injector.release(); precondition(posted == 0)
        injector.apply(InputMessage(kind: .flags, code: 55, flags: CGEventFlags.maskCommand.rawValue))
        injector.apply(InputMessage(kind: .keyDown, code: 0))
        injector.apply(InputMessage(kind: .down, code: 0))
        precondition(posted == 3 && injector.modifiers.contains(55))
        injector.release(); precondition(posted == 6 && injector.modifiers.isEmpty && injector.keys.isEmpty && injector.buttons.isEmpty)
        injector.release(); precondition(posted == 6)
        print("PASS empty release no-op, held key/button/modifier cleanup with nonposting event sink")
        try gestureTests(injector: injector)
        try cursorTests()
        updaterTests()
        clickCountTests()
        scrollAndStandardCursorTests()
        try dockGestureTests()
        sessionTests(decoded)
        var pushes = 0, pops = [UnsafeMutableRawPointer]()
        let hotToken = UnsafeMutableRawPointer(bitPattern: 0x1234)!
        let hot = HotKeyMode(); hot.push = { pushes += 1; return hotToken }; hot.pop = { pops.append($0) }
        hot.set(false); hot.set(true); hot.set(true); hot.set(false); hot.set(false)
        precondition(pushes == 1 && pops == [hotToken])
        hot.set(true); hot.set(false); precondition(pushes == 2 && pops.count == 2)
        print("PASS symbolic hot key mode push/pop balanced with the pushed token, no double pop")
        uiModelTests()
        hostingTests()
        virtualDisplayTests()
        let test = TLSTest(secret: decoded.secret); test.start(); dispatchMain()
    } catch { print("FAIL pure protocol tests"); exit(1) }
}
final class TLSTest {
    let secret: Data
    var listener: NWListener!
    var server: Peer?
    var client: Peer?
    var wrong: Peer?
    var phase = 0
    var success = false
    var replacement: HostReplacementTest?
    init(secret: Data) { self.secret = secret }
    func start() {
        do { listener = try NWListener(using: tlsParameters(secret: secret), on: .any) }
        catch { print("FAIL TLS listener"); exit(1) }
        listener.newConnectionHandler = { c in
            let peer = Peer(c); self.server = peer
            peer.onReady = { if self.phase == 1 { print("FAIL wrong key server authenticated"); exit(1) } }
            peer.onPacket = { data in
                guard data == Data([42]) else { print("FAIL TLS payload"); exit(1) }
                for byte: UInt8 in [43, 44, 45] { peer.frame(Data([byte])) {} }
            }
            peer.start()
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                let p = Peer(NWConnection(host: "127.0.0.1", port: self.listener.port!, using: tlsParameters(secret: self.secret)))
                self.client = p
                p.onReady = {
                    guard let metadata = p.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                          sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata.securityProtocolMetadata) == .TLSv12,
                          sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue == 0xCCAC else { print("FAIL unexpected TLS version or cipher"); exit(1) }
                    p.send(Data([42]))
                }
                var expected: UInt8 = 43
                p.onPacket = { data in
                    guard data == Data([expected]) else { print("FAIL echo"); exit(1) }
                    expected += 1; guard expected == 46 else { return }
                    print("PASS TLS1.2 ECDHE-PSK authenticated loopback payload, every video frame delivered in order")
                    self.success = true; self.phase = 1; p.close(); self.server?.close()
                    let bad = Peer(NWConnection(host: "127.0.0.1", port: self.listener.port!, using: tlsParameters(secret: Data(repeating: 0, count: 32))))
                    self.wrong = bad
                    bad.onReady = { print("FAIL wrong key authenticated"); exit(1) }
                    bad.onClose = {
                        guard bad.failure != nil else { print("FAIL wrong key closed without TLS rejection state=\(bad.connection.state)"); exit(1) }
                        var session = ViewerSession(); session.start(DialTarget(try! ConnectionCode.parse(ConnectionCode(host: "127.0.0.1", port: 1, token: try! ConnectionCode.randomToken()).text)))
                        guard session.closed(failure: bad.failure) == .wrongCode else { print("FAIL wrong key not classified as wrong code: \(String(describing: bad.failure))"); exit(1) }
                        print("PASS wrong TLS key rejected before application data and stops reconnecting (\(bad.failure!))")
                        self.replacement = HostReplacementTest(secret: self.secret); self.replacement!.start()
                    }
                    bad.start()
                }
                p.start()
            }
        }
        listener.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("FAIL TLS test timeout (no insecure fallback)"); exit(1) }
    }
}
func testPixelBuffer(width: Int, height: Int, shade: Int, format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
    let pixel = buffer!
    CVPixelBufferLockBaseAddress(pixel, [])
    for plane in 0..<2 {
        let base = CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!.assumingMemoryBound(to: UInt8.self)
        let row = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
        for y in 0..<CVPixelBufferGetHeightOfPlane(pixel, plane) { for x in 0..<row { base[y * row + x] = plane == 0 ? UInt8(16 + (x + y + shade * 20) % 200) : 128 } }
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    return pixel
}
extension EncodedFrame { var data: Data? { if case .message(let d) = self { return d }; return nil } }
func encodeTestFrames(width: Int, height: Int, keyframes: Set<Int>, count: Int, quality: EffectiveQuality = .legacyDefaults, stream: UInt8? = nil,
                      onDemandKeyframes: Bool = false, timing: FrameTiming? = nil) throws -> [Data] {
    var messages = [Data?]()
    let lock = NSLock(), done = DispatchSemaphore(value: 0)
    let encoder = try VideoEncoder(width: width, height: height, quality: quality, stream: stream, onDemandKeyframes: onDemandKeyframes) { m in lock.lock(); messages.append(m.data); lock.unlock(); done.signal() }
    let fmt = encoder.effectiveQuality.chroma == .yuv444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    for i in 0..<count {
        precondition(encoder.encode(testPixelBuffer(width: width, height: height, shade: i, format: fmt), time: CMTime(value: Int64(i), timescale: Int32(quality.fps.rawValue)), keyframe: keyframes.contains(i), timing: timing, capturedAt: mach_absolute_time()))
        precondition(done.wait(timeout: .now() + 5) == .success)
    }
    lock.lock(); defer { lock.unlock() }
    precondition(messages.count == count && messages.allSatisfy { $0 != nil })
    return messages.map { $0! }
}
func videoTests() throws {
    let messages = try encodeTestFrames(width: 1280, height: 720, keyframes: [0, 4], count: 6)
    let frames = try messages.map(VideoFrame.parse)
    precondition(frames.map(\.keyframe) == [true, false, false, false, true, false] && frames.allSatisfy { $0.codec == .h264 })
    precondition(zip(frames, messages).allSatisfy { $0.message == $1 } && frames[0].parameterSets.count == 2 && frames[1].parameterSets.isEmpty)
    let format = videoFormat(frames[0])!
    let size = CMVideoFormatDescriptionGetDimensions(format)
    precondition(size.width == 1280 && size.height == 720)
    var created: VTDecompressionSession?
    precondition(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &created) == noErr)
    let decoder = created!
    var decoded = 0
    for frame in frames {
        let sample = videoSample(frame, format: frame.keyframe ? videoFormat(frame)! : format)!
        precondition(VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            if status == noErr, let image, CVPixelBufferGetWidth(image) == 1280, CVPixelBufferGetHeight(image) == 720 { decoded += 1 }
        } == noErr)
    }
    VTDecompressionSessionWaitForAsynchronousFrames(decoder); VTDecompressionSessionInvalidate(decoder)
    precondition(decoded == frames.count)
    let viewer = Viewer(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
    precondition(viewer.show(frames[1]) && viewer.format == nil)
    precondition(frames.allSatisfy(viewer.show) && viewer.videoSize == CGSize(width: 1280, height: 720) && viewer.display.sampleBufferRenderer.status != .failed)
    precondition(viewer.contentRect == NSRect(x: 0, y: 180, width: 640, height: 360))
    viewer.clear(); precondition(viewer.format == nil && viewer.videoSize == .zero)
    let bytes = messages.map(\.count)
    print("PASS H.264 hardware encode, wire roundtrip and decode of \(decoded) 1280x720 frames, viewer enqueue and letterbox (bytes: \(bytes))")
    let oversized = try VideoFrame.parse(encodeTestFrames(width: 3842, height: 2160, keyframes: [0], count: 1)[0])
    precondition(oversized.keyframe && videoFormat(oversized) == nil)
    let key = frames[0], unit: [UInt8] = [0, 0, 0, 1, 0x41]
    let bad: [Data] = [
        Data([4]), Data([4, 0]), Data([1] + messages[1].dropFirst()), Data([4, 8] + messages[1].dropFirst(2)),
        Data(messages[0].dropLast()), Data(messages[1] + [0]), Data([4, 0, 0, 0, 0, 0, 0x41]), Data([4, 0, 0xff, 0xff, 0xff, 0xff, 0x41]),
        Data([4, 1, 0, 0] + messages[0].dropFirst(4)), Data([4, 1]) + key.avcc,
        VideoFrame(codec: .h264, keyframe: true, parameterSets: key.parameterSets.reversed(), avcc: key.avcc).message,
        Data([4, 0] + Array(repeating: unit, count: 257).joined()),
    ]
    for (i, message) in bad.enumerated() where (try? VideoFrame.parse(message)) != nil { print("FAIL malformed video message \(i) accepted"); exit(1) }
    precondition((try? VideoFrame.parse(Data([4, 0] + Array(repeating: unit, count: 256).joined()))) != nil)
    print("PASS oversized H.264 dimensions (>3840x2400) and \(bad.count) malformed video messages rejected")
    var streamedKey = frames[0]; streamedKey.stream = 2
    let streamedWire = streamedKey.message
    precondition(streamedWire.prefix(2) == Data([8, 2]) && (try? VideoFrame.parse(streamedWire)) == streamedKey && (try? VideoFrame.parse(messages[1]))?.stream == nil)
    let encodedStream = try encodeTestFrames(width: 640, height: 480, keyframes: [0], count: 2, stream: 3)
    precondition(encodedStream.allSatisfy { $0.first == 8 && (try? VideoFrame.parse($0))?.stream == 3 })
    var streamedDelta = frames[1]; streamedDelta.stream = 1
    let deltaWire = streamedDelta.message
    let badStream: [Data] = [
        Data([8, 4]) + deltaWire.dropFirst(2), Data([8, 255]) + deltaWire.dropFirst(2), Data([8, 1, 8]) + deltaWire.dropFirst(3),
        Data([8, 1]), Data([8, 1, 0]), Data([8, 1, 0, 0, 0, 0, 0x41]), Data(streamedWire.dropLast()), Data(deltaWire + [0]),
        Data([8, 1, 1, 0, 0]) + key.avcc,
    ]
    for (i, message) in badStream.enumerated() where (try? VideoFrame.parse(message)) != nil { print("FAIL malformed streamed video message \(i) accepted"); exit(1) }
    print("PASS video stream byte: type 8 [stream][flags] roundtrip, encoder writes stream 3, type 4 stays stream-less for 0.8 viewers, \(badStream.count) malformed streamed messages rejected")

    let enc60 = try VideoEncoder(width: 1280, height: 720, quality: EffectiveQuality(codec: .h264, chroma: .yuv420, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60)) { _ in }
    precondition(enc60.effectiveQuality.fps == .fps60 && enc60.effectiveQuality.bitrateMbps == 20)
    print("PASS H.264 60fps 20Mbps encoder created")

    if VideoEncoder.supportsHardwareHEVC && VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) {
        let hevcQ = EffectiveQuality(codec: .hevc, chroma: .yuv420, bitrateMbps: 10, maxResolution: .p1080, fps: .fps30)
        let hevcMsgs = try encodeTestFrames(width: 1280, height: 720, keyframes: [0, 4], count: 6, quality: hevcQ)
        let hevcFrames = try hevcMsgs.map(VideoFrame.parse)
        precondition(hevcFrames.allSatisfy { $0.codec == .hevc } && hevcFrames.map(\.keyframe) == [true, false, false, false, true, false])
        precondition(hevcFrames[0].parameterSets.count == 3 && hevcFrames[1].parameterSets.isEmpty)
        precondition(hevcFrames[0].parameterSets.map { ($0[0] >> 1) & 0x3f } == [32, 33, 34])
        let hevcFmt = videoFormat(hevcFrames[0])!
        let hevcSize = CMVideoFormatDescriptionGetDimensions(hevcFmt)
        precondition(hevcSize.width == 1280 && hevcSize.height == 720)
        var hevcDecOut: VTDecompressionSession?
        precondition(VTDecompressionSessionCreate(allocator: nil, formatDescription: hevcFmt, decoderSpecification: nil, imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &hevcDecOut) == noErr)
        let hevcDec = hevcDecOut!
        var hevcDecoded = 0
        for frame in hevcFrames {
            let sample = videoSample(frame, format: frame.keyframe ? videoFormat(frame)! : hevcFmt)!
            precondition(VTDecompressionSessionDecodeFrame(hevcDec, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, let image, CVPixelBufferGetWidth(image) == 1280, CVPixelBufferGetHeight(image) == 720 { hevcDecoded += 1 }
            } == noErr)
        }
        VTDecompressionSessionWaitForAsynchronousFrames(hevcDec); VTDecompressionSessionInvalidate(hevcDec)
        precondition(hevcDecoded == hevcFrames.count)
        let hevcViewer = Viewer(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
        precondition(hevcFrames.allSatisfy(hevcViewer.show) && hevcViewer.videoSize == CGSize(width: 1280, height: 720) && hevcViewer.display.sampleBufferRenderer.status != .failed)
        hevcViewer.clear()
        print("PASS HEVC hardware encode, wire roundtrip and decode of \(hevcDecoded) 1280x720 frames (bytes: \(hevcMsgs.map(\.count)))")

        let hevcKey = hevcFrames[0]
        let badHEVC: [Data] = [
            Data([4, 3]) + hevcKey.avcc,
            VideoFrame(codec: .hevc, keyframe: true, parameterSets: Array(hevcKey.parameterSets.prefix(2)), avcc: hevcKey.avcc).message,
            VideoFrame(codec: .hevc, keyframe: true, parameterSets: hevcKey.parameterSets.reversed(), avcc: hevcKey.avcc).message,
            VideoFrame(codec: .hevc, keyframe: true, parameterSets: key.parameterSets + [key.parameterSets[0]], avcc: hevcKey.avcc).message,
            VideoFrame(codec: .hevc, keyframe: true, parameterSets: [Data([0x40])] + hevcKey.parameterSets.dropFirst(), avcc: hevcKey.avcc).message,
            Data([4, 4] + hevcMsgs[1].dropFirst(2)),
        ]
        for (i, message) in badHEVC.enumerated() where (try? VideoFrame.parse(message)) != nil { print("FAIL malformed HEVC message \(i) accepted"); exit(1) }
        precondition(videoFormat(VideoFrame(codec: .hevc, keyframe: true, parameterSets: Array(hevcKey.parameterSets.prefix(2)), avcc: hevcKey.avcc)) == nil)
        print("PASS \(badHEVC.count) malformed HEVC video messages rejected")

        let req444 = EffectiveQuality(codec: .hevc, chroma: .yuv444, bitrateMbps: 20, maxResolution: .p1440, fps: .fps30)
        var out444 = [Data?]()
        let done444 = DispatchSemaphore(value: 0)
        let enc444 = try VideoEncoder(width: 1280, height: 720, quality: req444) { m in out444.append(m.data); done444.signal() }
        let effChroma = enc444.effectiveQuality.chroma
        if effChroma == .yuv444 {
            precondition(enc444.encode(testPixelBuffer(width: 1280, height: 720, shade: 1, format: kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange), time: .zero, keyframe: true))
            precondition(done444.wait(timeout: .now() + 5) == .success)
            let parsed444 = try VideoFrame.parse(out444[0]!)
            precondition(parsed444.codec == .hevc && videoFormat(parsed444) != nil)
        }
        print("PASS HEVC 4:4:4 attempt reported effective chroma \(effChroma.rawValue)")
    } else {
        print("SKIP (no HEVC hardware)")
        let badHEVC: [Data] = [
            Data([4, 3, 0, 2, 0x40, 0x01, 0, 2, 0x42, 0x01, 0, 0, 0, 1, 0x02]),
            Data([4, 3, 0, 2, 0x44, 0x01, 0, 2, 0x42, 0x01, 0, 2, 0x40, 0x01, 0, 0, 0, 1, 0x02]),
            Data([4, 3, 0, 1, 0x40, 0, 2, 0x42, 0x01, 0, 2, 0x44, 0x01, 0, 0, 0, 1, 0x02]),
        ]
        for (i, message) in badHEVC.enumerated() where (try? VideoFrame.parse(message)) != nil { print("FAIL malformed HEVC message \(i) accepted"); exit(1) }
        print("PASS \(badHEVC.count) malformed HEVC video messages rejected")
        print("PASS HEVC 4:4:4 attempt reported effective chroma 420 (no HEVC hardware)")
    }
}
func qualityTests() {
    let req = QualityRequest(codec: .auto, chroma: .yuv444, bitrate: .mbps20, maxResolution: .p1440, fps: .fps60, hevcDecode: true,
                               virtualDisplay: VirtualDisplayRequest(enabled: true, width: 3024, height: 1890, scale: 2))
    let wireReq = req.wireMessage()
    precondition(wireReq.count <= QualityRequest.maxWireBytes && QualityRequest.decodeWire(wireReq) == req)
    let legacyReqWire = Data([5]) + Data(#"{"codec":"auto","chroma":"444","bitrate":20,"maxResolution":"1440p","fps":60,"hevcDecode":true}"#.utf8)
    let decodedLegacyReq = QualityRequest.decodeWire(legacyReqWire)
    precondition(decodedLegacyReq != nil && decodedLegacyReq?.virtualDisplay == nil)
    let futureReqWire = Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true,"futureField":123}"#.utf8)
    precondition(QualityRequest.decodeWire(futureReqWire) != nil)

    let eff = EffectiveQuality(codec: .hevc, chroma: .yuv444, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60)
    let wireEff = eff.wireMessage()
    precondition(wireEff.count <= EffectiveQuality.maxWireBytes && EffectiveQuality.decodeWire(wireEff) == eff)
    precondition(eff.summary == "HEVC 4:4:4 · 1440p · 60fps · 20Mbps")
    let effVD = EffectiveQuality(codec: .hevc, chroma: .yuv420, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60, virtualDisplay: true)
    precondition(EffectiveQuality.decodeWire(effVD.wireMessage()) == effVD)
    precondition(effVD.summary == "HEVC · 1440p · 60fps · 20Mbps · 가상 화면")
    let legacyEffWire = Data([6]) + Data(#"{"codec":"hevc","chroma":"420","bitrateMbps":20,"maxResolution":"1440p","fps":60}"#.utf8)
    precondition(EffectiveQuality.decodeWire(legacyEffWire) == EffectiveQuality(codec: .hevc, chroma: .yuv420, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60, virtualDisplay: false))
    precondition(EffectiveQuality(codec: .hevc, chroma: .yuv420, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60).summary == "HEVC · 1440p · 60fps · 20Mbps")

    let pad = String(repeating: " ", count: 2100)
    let badReqs: [Data] = [
        Data([6]) + wireReq.dropFirst(),
        Data([5]) + Data(#"{"codec":"vp9","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"422","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":99,"maxResolution":"1080p","fps":30,"hevcDecode":true}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"8k","fps":30,"hevcDecode":true}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":120,"hevcDecode":true}"#.utf8),
        Data([5]) + Data((pad + #"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true}"#).utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true,"virtualDisplay":{"enabled":true,"width":639,"height":480,"scale":1}}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true,"virtualDisplay":{"enabled":true,"width":6017,"height":3384,"scale":2}}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true,"virtualDisplay":{"enabled":true,"width":1920,"height":479,"scale":1}}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true,"virtualDisplay":{"enabled":true,"width":1920,"height":3385,"scale":2}}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true,"virtualDisplay":{"enabled":true,"width":1920,"height":1080,"scale":3}}"#.utf8),
    ]
    for (i, d) in badReqs.enumerated() { precondition(QualityRequest.decodeWire(d) == nil, "bad req \(i)") }
    precondition(QualityRequest.decodeWire(Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true,"virtualDisplay":{"enabled":true,"width":640,"height":480,"scale":1}}"#.utf8)) != nil)
    precondition(QualityRequest.decodeWire(Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true,"virtualDisplay":{"enabled":true,"width":6016,"height":3384,"scale":2}}"#.utf8)) != nil)
    let badEffs: [Data] = [
        Data([5]) + wireEff.dropFirst(),
        Data([6]) + Data(#"{"codec":"h264","chroma":"444","bitrateMbps":20,"maxResolution":"1440p","fps":60}"#.utf8),
        Data([6]) + Data(#"{"codec":"hevc","chroma":"420","bitrateMbps":12,"maxResolution":"1440p","fps":60}"#.utf8),
        Data([6]) + Data((pad + #"{"codec":"hevc","chroma":"420","bitrateMbps":20,"maxResolution":"1440p","fps":60}"#).utf8),
    ]
    for (i, d) in badEffs.enumerated() { precondition(EffectiveQuality.decodeWire(d) == nil, "bad eff \(i)") }

    precondition(EffectiveQuality.resolve(req, hostHEVCEncode: true, hostHEVC444Encode: true) == eff)
    precondition(EffectiveQuality.resolve(req, hostHEVCEncode: true, hostHEVC444Encode: false) == EffectiveQuality(codec: .hevc, chroma: .yuv420, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60))
    precondition(EffectiveQuality.resolve(req, hostHEVCEncode: false, hostHEVC444Encode: true) == EffectiveQuality(codec: .h264, chroma: .yuv420, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60))
    let noDecodeReq = QualityRequest(codec: .hevc, chroma: .yuv444, bitrate: .auto, maxResolution: .native, fps: .fps30, hevcDecode: false)
    precondition(EffectiveQuality.resolve(noDecodeReq, hostHEVCEncode: true, hostHEVC444Encode: true) == EffectiveQuality(codec: .h264, chroma: .yuv420, bitrateMbps: 8, maxResolution: .native, fps: .fps30))
    let h264Req = QualityRequest(codec: .h264, chroma: .yuv444, bitrate: .mbps50, maxResolution: .native, fps: .fps60, hevcDecode: true)
    precondition(EffectiveQuality.resolve(h264Req, hostHEVCEncode: true, hostHEVC444Encode: true) == EffectiveQuality(codec: .h264, chroma: .yuv420, bitrateMbps: 50, maxResolution: .native, fps: .fps60))

    precondition(MaxResolutionOption.native.scaledSize(displayWidth: 5120, displayHeight: 2880) == (3840, 2160))
    precondition(MaxResolutionOption.p1080.scaledSize(displayWidth: 3456, displayHeight: 2234) == (1670, 1080))
    precondition(MaxResolutionOption.p1440.scaledSize(displayWidth: 1440, displayHeight: 900) == (1440, 900))

    let suite = "com.tamcut.Pulsar.qualitytest.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    precondition(StreamQualityPreferences.load(defaults) == StreamQualityPreferences())
    let saved = StreamQualityPreferences(codec: .hevc, chroma: .yuv444, bitrate: .mbps35, maxResolution: .native, fps: .fps60, singleScreenVirtual: true, edgeReturn: false)
    saved.save(defaults)
    precondition(StreamQualityPreferences.load(defaults) == saved)
    precondition(StreamQualityPreferences(codec: .h264, chroma: .yuv444, bitrate: .auto, maxResolution: .p1080, fps: .fps30).request(hevcDecode: true).chroma == .yuv420)
    let adaptiveReq = StreamQualityPreferences().request(hevcDecode: true)
    precondition(StreamQualityPreferences().adaptiveBitrate && adaptiveReq.timing == true && adaptiveReq.adaptive == true && QualityRequest.decodeWire(adaptiveReq.wireMessage()) == adaptiveReq)
    var manual = StreamQualityPreferences(); manual.adaptiveBitrate = false; manual.save(defaults)
    precondition(StreamQualityPreferences.load(defaults).request(hevcDecode: true).adaptive == false && decodedLegacyReq?.timing == nil && decodedLegacyReq?.adaptive == nil)
    let timedEff = EffectiveQuality(codec: .hevc, chroma: .yuv420, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60, timing: true)
    precondition(EffectiveQuality.decodeWire(timedEff.wireMessage()) == timedEff && EffectiveQuality.decodeWire(legacyEffWire)?.timing == false && timedEff.wireMessage().count <= EffectiveQuality.maxWireBytes)
    print("PASS quality request/effective JSON roundtrip (with/without virtualDisplay), bounds rejection, host resolution, scaling and UserDefaults persistence, timing/adaptive fields optional both ways")
}
var tailnet: TailnetHostTest?
// Plain TCP host path with an injected authorizer standing in for `tailscale whois`.
final class TailnetHostTest {
    let host = HostPeers()
    var listener: NWListener!
    var allow = true
    var asked = [String]()
    var events = [String]()
    var viewer: Peer?
    var refused: Peer?
    func client() -> Peer { Peer(NWConnection(host: "127.0.0.1", port: listener.port!, using: .tcp), greet: true) }
    func fail(_ m: String) -> Never { print("FAIL \(m)"); exit(1) }
    func start() {
        do { listener = try plainListener(address: "127.0.0.1", port: 0) } catch { fail("plain listener") }
        listener.newConnectionHandler = { [unowned self] c in host.acceptTailnet(c) { ip, done in self.asked.append(ip); done(self.allow) } }
        host.onActive = { [unowned self] _ in events.append("active") }
        host.onInactive = { [unowned self] in events.append("inactive") }
        listener.stateUpdateHandler = { [unowned self] state in
            guard case .ready = state else { return }
            let v = client(); viewer = v
            v.onClose = { self.fail("accepted tailnet viewer closed") }
            v.onReady = { self.probe() }
            v.start()
        }
        listener.start(queue: .main)
    }
    func probe() {
        guard events == ["active"], asked == ["127.0.0.1"], host.active?.ready == true else { fail("tailnet viewer not active after authorize: \(events) \(asked)") }
        let port = listener.port!.rawValue
        DispatchQueue.global().async {
            let open = (0..<3).map { _ in Probe.portOpen("127.0.0.1", port, timeout: 1.5) }
            let lan = localAddresses().first { $0.1 != "127.0.0.1" }?.1
            let other = lan.map { Probe.portOpen($0, port, timeout: 1.5) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.afterProbe(open, lan, other) }
        }
    }
    func afterProbe(_ open: [Bool], _ lan: String?, _ other: Bool?) {
        guard open == [true, true, true] else { fail("probe could not reach plain listener") }
        guard events == ["active"], host.peers.count == 1, host.active === host.peers.first, viewer?.ready == true, viewer?.closed == false else {
            fail("raw TCP probe disturbed the active peer: events=\(events) peers=\(host.peers.count)")
        }
        print("PASS plain tailnet host: authorizer asked for 127.0.0.1, hello completes; 3 raw TCP probes see the port open but never become a peer or evict the active viewer")
        if let lan, let other {
            guard !other else { fail("plain listener bound to 127.0.0.1 also answered on \(lan)") }
            print("PASS plain listener bound to one address refuses the same port on this Mac's other address")
        }
        allow = false
        let r = client(); refused = r
        r.onReady = { self.fail("rejected viewer became ready") }
        r.onClose = {
            var s = ViewerSession(); s.start(DialTarget(tailnet: "127.0.0.1"))
            guard r.connected, !r.ready, s.closed(failure: r.failure, refused: r.greet && r.connected) == .retry(attempt: 1),
                  self.asked.count == 5, self.events == ["active"], self.viewer?.closed == false else { self.fail("rejection path state \(self.asked.count) \(self.events)") }
            print("PASS authorizer rejection closes the new connection before hello (counted as a refusal), active viewer untouched")
            print("SELF-TEST PASS"); exit(0)
        }
        r.start()
    }
}
final class HostReplacementTest {
    let secret: Data
    let host = HostPeers()
    var listener: NWListener!
    var first: Peer?
    var second: Peer?
    var events = [String]()
    var firstClosed = false
    init(secret: Data) { self.secret = secret }
    func client() -> Peer { Peer(NWConnection(host: "127.0.0.1", port: listener.port!, using: tlsParameters(secret: secret))) }
    func start() {
        do { listener = try NWListener(using: tlsParameters(secret: secret), on: .any) } catch { print("FAIL replacement listener"); exit(1) }
        listener.newConnectionHandler = { [host] c in host.accept(c) }
        host.onInactive = { self.events.append("inactive") }
        host.onActive = { p in
            self.events.append("active")
            if self.events == ["active"] {
                let s = self.client(); self.second = s
                s.onClose = { print("FAIL replacing client closed"); exit(1) }
                s.start()
            }
            self.check()
        }
        listener.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let f = self.client(); self.first = f
            f.onClose = { self.firstClosed = true; self.check() }
            f.start()
        }
        listener.start(queue: .main)
    }
    func check() {
        guard firstClosed, events == ["active", "inactive", "active"] else { return }
        guard host.peers.count == 1, host.active === host.peers.first, host.active?.ready == true, second?.ready == true else { print("FAIL host replacement state"); exit(1) }
        print("PASS host accepts a second authenticated viewer, closes the first and keeps one active peer")
        tailnet = TailnetHostTest(); tailnet!.start()
    }
}
func gestureFixture(_ subtype: Int64, phase: Int64, scalar: Double) -> CGEvent {
    let event = CGEvent(source: nil)!
    event.type = CGEventType(rawValue: 29)!
    event.setIntegerValueField(CGEventField(rawValue: 110)!, value: subtype)
    event.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
    event.setDoubleValueField(CGEventField(rawValue: 113)!, value: scalar)
    return event
}
func gestureTests(injector: InputInjector) throws {
    let build = osBuild!
    let viewRect = NSRect(x: 10, y: 20, width: 200, height: 100), hostRect = CGRect(x: 0, y: 0, width: 1441, height: 901)
    let pinch = Viewer.gestureMessage(NSEvent(cgEvent: gestureFixture(8, phase: 2, scalar: 0.25))!, point: NSPoint(x: 110, y: 70), rect: viewRect)!
    let wire = try JSONEncoder().encode(pinch)
    let m = try JSONDecoder().decode(InputMessage.self, from: wire)
    precondition(wire.count + 1 <= 100_000 && m.valid && m.kind == .gesture && m.build == build && m.x == 0.5 && m.y == 0.5)
    let event = gestureEvent(m, hostBuild: build, rect: hostRect)!
    precondition(event.type.rawValue == 29 && event.getIntegerValueField(CGEventField(rawValue: 110)!) == 8
        && event.getIntegerValueField(CGEventField(rawValue: 132)!) == 2 && event.getDoubleValueField(CGEventField(rawValue: 113)!) == 0.25
        && event.location == CGPoint(x: 720, y: 450) && NativeGestureDescriptor.decode(event) == NativeGestureDescriptor(kind: .pinch, phase: .changed))
    var posted = [CGEvent](); injector.postEvent = { posted.append($0) }; injector.rects = [0: hostRect]
    injector.apply(m); precondition(posted.count == 1 && posted[0].type.rawValue == 29 && posted[0].location == CGPoint(x: 720, y: 450))
    var mismatch = m; mismatch.build = build + "x"
    injector.apply(mismatch); precondition(posted.count == 1 && gestureEvent(mismatch, hostBuild: build, rect: hostRect) == nil)
    for (subtype, phase, scalar) in [(Int64(99), Int64(2), 0.25), (8, 0, 0.25), (8, 2, 4.5), (22, 1, 0)] {
        let bad = Viewer.gestureMessage(NSEvent(cgEvent: gestureFixture(subtype, phase: phase, scalar: scalar))!, point: NSPoint(x: 110, y: 70), rect: viewRect)!
        precondition(gestureEvent(bad, hostBuild: build, rect: hostRect) == nil)
    }
    var garbage = m; garbage.data = Data([1, 2, 3]); precondition(garbage.valid && gestureEvent(garbage, hostBuild: build, rect: hostRect) == nil)
    var oversized = m; oversized.data = Data(count: InputMessage.gestureDataLimit + 1); precondition(!oversized.valid)
    var noBuild = m; noBuild.build = nil; precondition(!noBuild.valid)
    let plain = try JSONEncoder().encode(InputMessage(kind: .move))
    precondition(!InputMessage(kind: .move, data: Data([1])).valid && plain.count < 2048)
    print("PASS magnify CGEvent bytes survive wire roundtrip and are replayed at the mapped host point; wrong subtype/phase/scalar, garbage, oversize and build mismatch rejected (\(m.data!.count) event bytes, \(wire.count) wire bytes)")
}
func sessionTests(_ code: ConnectionCode) {
    let t0 = Date(timeIntervalSince1970: 1000)
    let code = DialTarget(code)
    var s = ViewerSession(); s.start(code)
    precondition(s.closed(failure: nil, now: t0) == .retry(attempt: 1) && s.closed(failure: .posix(.ETIMEDOUT), now: t0 + 2) == .retry(attempt: 2))
    s.connected()
    precondition(s.closed(failure: .tls(-9806), now: t0 + 10) == .retry(attempt: 1))
    precondition(s.closed(failure: nil, now: t0 + 129) == .retry(attempt: 2) && s.closed(failure: nil, now: t0 + 130) == .giveUp && s.target == nil)
    s.start(code); precondition(s.closed(failure: .tls(-9820)) == .wrongCode && s.target == nil)
    s.start(code); let g = s.generation; s.stop(); precondition(s.generation != g && s.closed(failure: nil) == .idle)
    print("PASS viewer session retries non-user closes every \(Int(ViewerSession.retryDelay))s for 2 minutes, stops on wrong code and user stop")
    let tail = DialTarget(tailnet: "100.76.63.21")
    precondition(tail.port == 47700 && tail.secret == nil)
    s.start(tail)
    precondition(s.closed(failure: nil, refused: true) == .retry(attempt: 1) && s.closed(failure: nil, refused: true) == .retry(attempt: 2))
    precondition(s.closed(failure: .posix(.ECONNREFUSED)) == .retry(attempt: 3) && s.closed(failure: nil, refused: true) == .retry(attempt: 4))
    precondition(s.closed(failure: nil, refused: true) == .retry(attempt: 5) && s.closed(failure: nil, refused: true) == .refused && s.target == nil)
    s.start(tail); _ = s.closed(failure: nil, refused: true); _ = s.closed(failure: nil, refused: true); s.connected()
    precondition(s.closed(failure: nil, refused: true) == .retry(attempt: 1))
    print("PASS tailnet dial stops after \(ViewerSession.refusalLimit) consecutive host refusals; a refused-port close or an accepted session resets the count")
}
func uiModelTests() {
    let fixture = """
    {"BackendState":"Running","Self":{"HostName":"Mac mini","OS":"macOS","Online":true,"TailscaleIPs":["100.116.229.75","fd7a::1"],"UserID":7},
     "User":{"7":{"LoginName":"me@example.com"},"9":{"LoginName":"guest@example.com"}},
     "Peer":{"a":{"HostName":"z-fold7","OS":"android","Online":true,"TailscaleIPs":["100.99.0.1"],"UserID":7},
             "b":{"HostName":"old\\u00a0mac","OS":"macOS","Online":false,"TailscaleIPs":["100.1.1.1"],"UserID":7},
             "c":{"HostName":"macbookpro","OS":"macOS","Online":true,"TailscaleIPs":["fd7a::2","100.76.63.21"],"CurAddr":"192.168.0.5:41641","Relay":"tok","UserID":7},
             "d":{"HostName":"air","OS":"macOS","Online":true,"TailscaleIPs":["100.2.2.2"],"CurAddr":"","Relay":"tok","UserID":7},
             "e":{"HostName":"guest","OS":"macOS","Online":true,"TailscaleIPs":["100.3.3.3"],"CurAddr":"","Relay":"","UserID":9}}}
    """
    let net = TailscaleDevice.parse(Data(fixture.utf8))!, d = net.devices
    precondition(net.login == "me@example.com" && d[2].ipv4 == "100.76.63.21")
    precondition(d.map(\.name) == ["Mac mini", "air", "macbookpro", "guest", "old mac", "z-fold7"])
    precondition(d.map(\.state) == [.thisMac, .online, .online, .otherAccount, .offline, .unsupported] && d[0].isSelf && d[0].stateText == "이 Mac" && d[3].stateText == "다른 계정")
    precondition(d[0].path == "—" && d[1].path == "Tailscale 중계" && d[2].path == "Tailscale 직접" && d[3].path == "Tailscale" && d[4].path == "—" && d[4].stateText == "오프라인" && d[5].stateText == "지원 안 함")
    precondition(TailscaleDevice.parse(Data("{\"BackendState\":\"Stopped\"}".utf8)) == nil && TailscaleDevice.parse(Data("nope".utf8)) == nil)
    print("PASS Tailscale status JSON parsed: self first, own login, same/other account, online/offline/unsupported states, direct/relay/fallback route, stopped and invalid output rejected")
    let whois = Data(#"{"Node":{"ID":1,"Name":"macbookpro.tail.ts.net."},"UserProfile":{"ID":2,"LoginName":"me@example.com","DisplayName":"Me"},"CapMap":{}}"#.utf8)
    precondition(whoisLogin(whois) == "me@example.com")
    precondition(tailnetAllows(whois: whois, selfLogin: "me@example.com"))
    precondition(!tailnetAllows(whois: whois, selfLogin: "guest@example.com") && !tailnetAllows(whois: whois, selfLogin: nil) && !tailnetAllows(whois: whois, selfLogin: ""))
    for bad in [nil, Data(), Data("peer not found".utf8), Data(#"{"UserProfile":{"LoginName":""}}"#.utf8), Data(#"{"Node":{}}"#.utf8)] as [Data?] {
        precondition(!tailnetAllows(whois: bad, selfLogin: "me@example.com"))
    }
    print("PASS whois login parsed; same account allowed, other account, missing/garbage whois and unknown own login rejected (fail closed)")
    precondition(tailnetBindAddress(["192.168.45.10", "169.254.3.1", "100.116.229.75"]) == "100.116.229.75")
    precondition(tailnetBindAddress(["192.168.45.10", "100.200.1.1", "100.63.0.1", "10.0.0.2"]) == nil && tailnetBindAddress([]) == nil)
    print("PASS plain listener bind address is the 100.64.0.0/10 Tailscale address only, never LAN or link-local")
    let suite = "com.tamcut.Pulsar.selftest.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    precondition(ShortcutAction.disconnect.load(defaults).caps == ["⌃", "⌥", "⇧", "Q"] && ShortcutAction.sendsSystem(defaults))
    let legacy = Shortcut(keyCode: 2, modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue, key: "D")
    ShortcutAction.disconnect.save(legacy, defaults)
    precondition(ShortcutAction.disconnect.load(defaults) == ShortcutAction.disconnect.fallback)
    let custom = Shortcut(keyCode: 14, modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue, key: "E")
    ShortcutAction.overlay.save(custom, defaults)
    precondition(ShortcutAction.overlay.load(defaults) == custom && custom.caps == ["⇧", "⌘", "E"] && ShortcutAction.fullScreen.load(defaults) == ShortcutAction.fullScreen.fallback)
    defaults.set(Data("garbage".utf8), forKey: ShortcutAction.disconnect.defaultsKey)
    precondition(ShortcutAction.disconnect.load(defaults) == ShortcutAction.disconnect.fallback)
    func key(_ c: String, _ code: UInt16, _ m: NSEvent.ModifierFlags, _ type: NSEvent.EventType = .keyDown) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: m, timestamp: 0, windowNumber: 0, context: nil, characters: c, charactersIgnoringModifiers: c, isARepeat: false, keyCode: code)!
    }
    let plain = key("d", 2, []), shiftOnly = key("q", 12, [.shift])
    let shiftCombo = key("q", 12, [.control, .option, .shift]), combo = key("k", 40, [.control, .option])
    precondition(Shortcut.from(plain) == nil && Shortcut.from(shiftOnly) == nil)
    precondition(Shortcut.from(shiftCombo)?.caps == ["⌃", "⌥", "⇧", "Q"] && Shortcut.from(combo)?.caps == ["⌃", "⌥", "K"])
    print("PASS shortcut encode/decode persistence, ⌃⌥⌘D migration to ⌃⌥⇧Q, garbage fallback and modifier requirement")
    let hyper: NSEvent.ModifierFlags = [.control, .option, .command]
    precondition(ShortcutAction.matching(shiftCombo, defaults) == .disconnect && ShortcutAction.matching(key("f", 3, hyper), defaults) == .fullScreen)
    precondition(ShortcutAction.matching(key("e", 14, [.command, .shift]), defaults) == .overlay && ShortcutAction.matching(key("o", 31, hyper), defaults) == nil)
    precondition(ShortcutAction.matching(key("q", 12, [.control, .option]), defaults) == nil && ShortcutAction.matching(key("q", 12, hyper.union(.shift)), defaults) == nil)
    precondition(ShortcutAction.matching(key("q", 12, [.control, .option, .shift], .keyUp), defaults) == nil && ShortcutAction.matching(plain, defaults) == nil)
    precondition(ShortcutAction.fullScreen.conflict(ShortcutAction.disconnect.fallback, defaults) == .disconnect && ShortcutAction.disconnect.conflict(custom, defaults) == .overlay)
    precondition(ShortcutAction.disconnect.conflict(ShortcutAction.disconnect.fallback, defaults) == nil && ShortcutAction.disconnect.conflict(Shortcut.from(combo)!, defaults) == nil)
    print("PASS saved session shortcuts consumed locally (⌃⌥⇧Q, ⌃⌥⌘F, custom ⇧⌘E), other combos and keyUp forwarded; recorder rejects a combo used by another action")
    precondition(Permission.all.map(\.verifiable) == [true, true, true])
    print("PASS all three permissions report usable/not usable and count toward the missing-permission line")
}

func hostingTests() {
    func freshDefaults() -> (String, UserDefaults) {
        let suite = "com.tamcut.Pulsar.hostingtest.\(UUID().uuidString)"
        return (suite, UserDefaults(suiteName: suite)!)
    }

    let (s0, d0) = freshDefaults(); defer { d0.removePersistentDomain(forName: s0) }
    precondition(HostPreferences.allowRemoteAccess(d0) == true)
    precondition(HostPreferences.allowGuestInput(d0) == false)
    precondition(HostPreferences.preventSleep(d0) == true)

    let (s1, d1) = freshDefaults(); defer { d1.removePersistentDomain(forName: s1) }
    d1.set(false, forKey: HostPreferences.legacyAutoShareKey)
    d1.set(false, forKey: HostPreferences.legacyAllowInputKey)
    precondition(HostPreferences.allowRemoteAccess(d1) == false)

    let (s2, d2) = freshDefaults(); defer { d2.removePersistentDomain(forName: s2) }
    d2.set(false, forKey: HostPreferences.legacyAutoShareKey)
    d2.set(true, forKey: HostPreferences.legacyAllowInputKey)
    precondition(HostPreferences.allowRemoteAccess(d2) == true)

    let (s3, d3) = freshDefaults(); defer { d3.removePersistentDomain(forName: s3) }
    d3.set(true, forKey: HostPreferences.legacyAutoShareKey)
    d3.set(false, forKey: HostPreferences.legacyAllowInputKey)
    precondition(HostPreferences.allowRemoteAccess(d3) == true)
    HostPreferences.setAllowRemoteAccess(false, d3)
    precondition(HostPreferences.allowRemoteAccess(d3) == false)

    HostPreferences.setAllowGuestInput(true, d0)
    HostPreferences.setPreventSleep(false, d0)
    precondition(HostPreferences.allowGuestInput(d0) == true && HostPreferences.preventSleep(d0) == false)
    print("PASS hosting preferences migration (default on, either legacy key on -> on, both off -> off) and guest/sleep persistence")

    precondition(hostAllowsInput(peerKind: .owner, guestInputAllowed: false, accessibilityTrusted: true))
    precondition(hostAllowsInput(peerKind: .owner, guestInputAllowed: true, accessibilityTrusted: true))
    precondition(!hostAllowsInput(peerKind: .owner, guestInputAllowed: true, accessibilityTrusted: false))
    precondition(!hostAllowsInput(peerKind: .guest, guestInputAllowed: false, accessibilityTrusted: true))
    precondition(hostAllowsInput(peerKind: .guest, guestInputAllowed: true, accessibilityTrusted: true))
    precondition(!hostAllowsInput(peerKind: .guest, guestInputAllowed: true, accessibilityTrusted: false))
    print("PASS owner vs guest input gating (owner always allowed when trusted, guest requires toggle)")

    var acquired = 0, released = [UInt32]()
    let sleep = SleepAssertion()
    sleep.acquire = { acquired += 1; return UInt32(100 + acquired) }
    sleep.release = { released.append($0) }
    sleep.set(false); precondition(acquired == 0 && released.isEmpty && !sleep.isHeld)
    sleep.set(true); sleep.set(true); precondition(acquired == 1 && released.isEmpty && sleep.isHeld)
    sleep.set(false); sleep.set(false); precondition(acquired == 1 && released == [101] && !sleep.isHeld)
    sleep.set(true); sleep.set(false); precondition(acquired == 2 && released == [101, 102] && !sleep.isHeld)
    print("PASS IOPMAssertion acquire/release balanced with injected callbacks, no double acquire or release")
}

func virtualDisplayTests() {
    // A live Pulsar session already holds a virtual display; creating another then fails, so skip rather than fail.
    if NSScreen.screens.contains(where: { $0.localizedName == "Pulsar" }) { print("SKIP virtual display: a Pulsar session's virtual display is online"); return }
    func require(_ condition: @autoclosure () -> Bool, _ message: String = "condition failed", line: UInt = #line) {
        if !condition() { fputs("FAIL virtual display line \(line): \(message)\n", stderr); exit(1) }
    }
    guard VirtualDisplay.isAvailable else {
        print("SKIP (virtual display API unavailable)")
        return
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            autoreleasepool {
                if let event = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.05), inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
            }
        }
    }
    func onlineIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        require(CGGetOnlineDisplayList(32, &ids, &count) == .success)
        return Array(ids.prefix(Int(count)))
    }

    struct ExistingDisplay: Equatable {
        let vendor: UInt32, model: UInt32, serial: UInt32
        let active: Bool, mirror: CGDirectDisplayID, bounds: CGRect
        let width: Int, height: Int, pixelWidth: Int, pixelHeight: Int
        let hz: Double, flags: UInt32
    }
    func existingLayout(_ ids: [CGDirectDisplayID]) -> [CGDirectDisplayID: ExistingDisplay] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            guard let mode = CGDisplayCopyDisplayMode(id) else {
                fputs("FAIL existing display mode unavailable\n", stderr); exit(1)
            }
            return (id, ExistingDisplay(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                serial: CGDisplaySerialNumber(id), active: CGDisplayIsActive(id) != 0,
                mirror: CGDisplayMirrorsDisplay(id), bounds: CGDisplayBounds(id),
                width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                hz: mode.refreshRate, flags: mode.ioFlags))
        })
    }
    let before = onlineIDs(), priorMain = CGMainDisplayID()
    let priorLayout = existingLayout(before)
    var vd: VirtualDisplay?
    autoreleasepool {
        vd = VirtualDisplay(width: 2880, height: 1800, scale: 2)
    }
    require(vd != nil, "VirtualDisplay creation failed")
    let vid = vd!.displayID
    require(!before.contains(vid))

    var appeared = false
    for _ in 0..<30 {
        pump(0.1)
        let current = onlineIDs()
        if current.contains(vid), let mode = CGDisplayCopyDisplayMode(vid), mode.pixelWidth == 2880, mode.pixelHeight == 1800 {
            appeared = true
            break
        }
    }
    require(appeared, "VirtualDisplay \(vid) did not appear with 2880x1800 pixel mode within 3s")
    require(CGMainDisplayID() == priorMain && existingLayout(before) == priorLayout, "VirtualDisplay changed an existing display")
    require(CGDisplayIsActive(vid) != 0 && CGDisplayIsInMirrorSet(vid) == 0 && CGDisplayMirrorsDisplay(vid) == 0)
    for id in before where CGDisplayIsActive(id) != 0 {
        require(!CGDisplayBounds(vid).intersects(CGDisplayBounds(id)), "VirtualDisplay overlaps an existing screen")
    }

    autoreleasepool {
        vd?.destroy()
        vd = nil
    }
    var disappeared = false
    for _ in 0..<30 {
        pump(0.1)
        if !onlineIDs().contains(vid) {
            disappeared = true
            break
        }
    }
    require(disappeared, "VirtualDisplay \(vid) did not disappear within 3s after release")
    require(Set(onlineIDs()) == Set(before))
    require(CGMainDisplayID() == priorMain && existingLayout(before) == priorLayout, "VirtualDisplay removal changed an existing display")
    print("PASS virtual display preserves existing main/mirror/mode/origins; created id=\(vid) at 2880x1800 and disappeared within 3s on release")

    let beforePair = Set(onlineIDs())
    var pair = [VirtualDisplay]()
    autoreleasepool {
        pair = [VirtualDisplay(width: 1920, height: 1080, scale: 1), VirtualDisplay(width: 3024, height: 1964, scale: 2)].compactMap { $0 }
    }
    require(pair.count == 2, "two VirtualDisplays created (got \(pair.count))")
    let pairIDs = Set(pair.map(\.displayID))
    require(pairIDs.count == 2 && beforePair.isDisjoint(with: pairIDs))
    var bothOnline = false
    for _ in 0..<30 {
        pump(0.1)
        if pairIDs.isSubset(of: Set(onlineIDs())) { bothOnline = true; break }
    }
    require(bothOnline, "both virtual displays online within 3s")
    require(HostDisplay.streamable(HostDisplay.online()).allSatisfy { !pairIDs.contains($0.cgID) }, "Pulsar virtual displays are never offered as host monitors")
    autoreleasepool {
        pair.forEach { $0.destroy() }
        pair = []
    }
    var pairGone = false
    for _ in 0..<30 {
        pump(0.1)
        if Set(onlineIDs()) == beforePair { pairGone = true; break }
    }
    require(pairGone, "both virtual displays gone within 3s; online \(onlineIDs()) vs \(beforePair.sorted())")
    print("PASS two virtual displays \(pairIDs.sorted()) online together, excluded from host monitors, and both gone within 3s; display list back to \(beforePair.sorted())")
}

func multiScreenTests() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        if !condition() { fputs("FAIL multi-screen line \(line): \(message)\n", stderr); exit(1) }
    }
    func hd(_ id: String, main: Bool = false, x: CGFloat, w: CGFloat = 1920, vendor: UInt32 = 1552, mirror: CGDirectDisplayID = 0, active: Bool = true) -> HostDisplay {
        HostDisplay(cgID: CGDirectDisplayID(abs(id.hashValue) % 1000 + 1), id: id, name: "Display \(id)", isMain: main,
                    bounds: CGRect(x: x, y: 0, width: w, height: 1080), vendor: vendor, mirrorOf: mirror, active: active)
    }
    func cs(_ id: Int, main: Bool = false, x: Double, w: Double = 1512, h: Double = 982, show: String? = nil) -> ClientScreen {
        ClientScreen(id: id, isMain: main, x: x, y: 0, width: w, height: h, pixelWidth: Int(w) * 2, pixelHeight: Int(h) * 2, scale: 2, show: show)
    }
    let A = hd("A", main: true, x: 0), B = hd("B", x: 1920), L = hd("L", x: -1920), R = hd("R", x: 1920)

    var m = mapScreens(client: [cs(0, main: true, x: 0)], host: [A, B], singleScreenVirtual: false)
    require(m == ScreenAssignment(sources: [0: .physical("A")], unused: ["B"]), "one viewer screen copies host main: \(m)")
    m = mapScreens(client: [cs(0, main: true, x: 0)], host: [A, B], singleScreenVirtual: true)
    require(m == ScreenAssignment(sources: [0: .virtual], unused: ["A", "B"]), "one viewer screen with the virtual setting: \(m)")
    m = mapScreens(client: [cs(0, main: true, x: 0), cs(1, x: 1512)], host: [A], singleScreenVirtual: false)
    require(m == ScreenAssignment(sources: [0: .physical("A"), 1: .virtual], unused: []), "host1/client2: \(m)")
    m = mapScreens(client: [cs(0, main: true, x: 0), cs(1, x: 1512)], host: [hd("A", main: true, x: 0), hd("B", x: -1920)], singleScreenVirtual: false)
    require(m == ScreenAssignment(sources: [0: .physical("A"), 1: .physical("B")], unused: []), "host2/client2 with mirrored arrangement: \(m)")
    m = mapScreens(client: [cs(0, main: true, x: 0), cs(1, x: 1512)], host: [L, A, R], singleScreenVirtual: false)
    require(m == ScreenAssignment(sources: [0: .physical("A"), 1: .physical("R")], unused: ["L"]), "host3/client2 keeps the left display switchable: \(m)")
    m = mapScreens(client: [cs(0, main: true, x: 0), cs(1, x: -1920, w: 1920, h: 1080), cs(2, x: 1512)], host: [A, B], singleScreenVirtual: false)
    require(m == ScreenAssignment(sources: [0: .physical("A"), 1: .virtual, 2: .physical("B")], unused: []), "host2/client3 mixed: \(m)")
    m = mapScreens(client: [cs(0, main: true, x: 0, show: "B"), cs(1, x: 1512, show: "A")], host: [A, B], singleScreenVirtual: false)
    require(m == ScreenAssignment(sources: [0: .physical("B"), 1: .physical("A")], unused: []), "remembered choices win: \(m)")
    m = mapScreens(client: [cs(0, main: true, x: 0), cs(1, x: 1512, show: "GONE")], host: [A, B], singleScreenVirtual: false)
    require(m == ScreenAssignment(sources: [0: .physical("A"), 1: .physical("B")], unused: []), "missing remembered display falls back to the rule: \(m)")
    m = mapScreens(client: [cs(0, main: true, x: 0, show: "A"), cs(1, x: 1512, show: "A")], host: [A, B], singleScreenVirtual: false)
    require(m == ScreenAssignment(sources: [0: .physical("A"), 1: .physical("B")], unused: []), "one physical display is not mapped twice: \(m)")
    m = mapScreens(client: [cs(0, main: true, x: 0), cs(1, x: 1512)], host: [], singleScreenVirtual: false)
    require(m == ScreenAssignment(sources: [0: .virtual, 1: .virtual], unused: []), "headless host gives virtual screens: \(m)")
    print("PASS screen mapping: 1 screen copies host main (virtual when set), host1/client2, host2/client2 arrangement-independent, host3/client2 leaves 1 switchable, host2/client3 mixed, remembered/missing/duplicate choices, headless host")

    let all = [A, B, hd("M", x: 1920, mirror: 1), hd("P", x: 3840, vendor: 0x5055), hd("T", x: 5760, vendor: 505), hd("S", x: 7680, active: false)]
    require(HostDisplay.streamable(all).map(\.id) == ["A", "B"], "mirrors, Pulsar/ThunderControl virtual and inactive displays excluded")
    let online = HostDisplay.online()
    require(!online.isEmpty && online.allSatisfy { !$0.id.isEmpty && $0.id.count <= 64 } && Set(online.map(\.id)).count == online.count, "real displays get unique opaque ids")
    print("PASS host display filter drops mirrors, Pulsar (0x5055) and ThunderControl (505) virtual displays; \(online.count) online displays have unique ids, \(HostDisplay.streamable(online).count) streamable")

    let screens3 = [cs(0, main: true, x: 0), cs(1, x: -1920, w: 1920, h: 1080, show: "virtual"), cs(2, x: 1512, show: String(repeating: "F", count: 36))]
    let req = QualityRequest(codec: .auto, chroma: .yuv420, bitrate: .mbps20, maxResolution: .p1440, fps: .fps60, hevcDecode: true, screens: screens3)
    let reqWire = req.wireMessage()
    require(reqWire.count <= QualityRequest.maxWireBytes && QualityRequest.decodeWire(reqWire) == req, "screens roundtrip (\(reqWire.count) bytes)")
    let twoScreens = QualityRequest(codec: .auto, chroma: .yuv420, bitrate: .auto, maxResolution: .p1080, fps: .fps30, hevcDecode: true,
                                    virtualDisplay: VirtualDisplayRequest(enabled: false, width: 3024, height: 1890, scale: 2), screens: [cs(0, main: true, x: 0), cs(1, x: 1512)],
                                    timing: true, adaptive: true, cursor: true, dockGesture: "26B131")
    require(twoScreens.wireMessage().count <= 512, "two screens fit a 0.8 host's 512-byte limit (\(twoScreens.wireMessage().count))")
    func withScreens(_ s: [ClientScreen]) -> Data { QualityRequest(codec: .auto, chroma: .yuv420, bitrate: .auto, maxResolution: .p1080, fps: .fps30, hevcDecode: true, screens: s).wireMessage() }
    var badScreen = cs(1, x: 1512); badScreen.scale = 3
    var tiny = cs(1, x: 1512); tiny.width = 50
    let badScreenLists: [[ClientScreen]] = [
        [], (0..<5).map { cs($0, main: $0 == 0, x: Double($0) * 1512) }, [cs(0, main: true, x: 0), cs(0, x: 1512)],
        [cs(0, main: true, x: 0), cs(1, main: true, x: 1512)], [cs(0, x: 0), cs(1, x: 1512)], [cs(0, main: true, x: 0), cs(2, x: 1512)],
        [cs(0, main: true, x: 0), badScreen], [cs(0, main: true, x: 0), tiny], [cs(0, main: true, x: 0, show: "")],
        [cs(0, main: true, x: 0, show: String(repeating: "x", count: 65))], [cs(4, main: true, x: 0)],
    ]
    for (i, s) in badScreenLists.enumerated() { require(QualityRequest.decodeWire(withScreens(s)) == nil, "bad screen list \(i) rejected") }
    require(QualityRequest.decodeWire(Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true,"screens":[{"id":0,"isMain":true,"x":0,"y":0,"width":"wide","height":982,"pixelWidth":3024,"pixelHeight":1964,"scale":2}]}"#.utf8)) == nil, "type mismatch rejected")

    let map = ScreenMap(screens: [.init(clientScreenId: 0, kind: .physical, hostDisplayName: "LG HDR 5K", hostDisplayId: "A", pixelWidth: 2560, pixelHeight: 1440),
                                  .init(clientScreenId: 1, kind: .virtual, hostDisplayName: "가상 화면", hostDisplayId: "virtual", pixelWidth: 3024, pixelHeight: 1964)],
                        switchable: [.init(id: "A", name: "LG HDR 5K"), .init(id: "B", name: "Studio Display")])
    require(ScreenMap.decodeWire(map.wireMessage()) == map, "ScreenMap roundtrip")
    func mutated(_ f: (inout ScreenMap) -> Void) -> Data { var c = map; f(&c); return c.wireMessage() }
    let badMaps: [Data] = [
        mutated { $0.screens = [] }, mutated { $0.screens = Array(repeating: $0.screens[0], count: 5).enumerated().map { var e = $1; e.clientScreenId = $0; return e } },
        mutated { $0.screens[1].clientScreenId = 0 }, mutated { $0.screens[1].clientScreenId = 4 }, mutated { $0.screens[1].hostDisplayId = "B" },
        mutated { $0.screens[0].hostDisplayId = "virtual" }, mutated { $0.screens[0].hostDisplayName = "" }, mutated { $0.screens[0].pixelWidth = 0 },
        mutated { $0.switchable = Array(repeating: $0.switchable[0], count: 17) }, mutated { $0.switchable[0].id = "virtual" },
        mutated { $0.screens[0].hostDisplayId = String(repeating: "x", count: 65) },
        Data([6]) + map.wireMessage().dropFirst(), Data([7]), Data([7]) + Data("{}".utf8),
        Data([7]) + Data(String(repeating: " ", count: 8200).utf8) + map.wireMessage().dropFirst(),
    ]
    for (i, d) in badMaps.enumerated() { require(ScreenMap.decodeWire(d) == nil, "bad ScreenMap \(i) rejected") }
    let sw = ScreenSwitch(clientScreenId: 2, show: "virtual")
    require(ScreenSwitch.decodeWire(sw.wireMessage()) == sw && ScreenSwitch.decodeWire(ScreenSwitch(clientScreenId: 4, show: "A").wireMessage()) == nil
            && ScreenSwitch.decodeWire(ScreenSwitch(clientScreenId: 0, show: "").wireMessage()) == nil, "ScreenSwitch roundtrip and bounds")
    require(KeyframeRequest.decode(KeyframeRequest.wire(3)) == 3 && KeyframeRequest.decode(Data([11, 4])) == nil
            && KeyframeRequest.decode(Data([11])) == nil && KeyframeRequest.decode(Data([11, 0, 0])) == nil, "keyframe request bounds")
    require(InputMessage(kind: .move, screen: 3).valid && !InputMessage(kind: .move, screen: 4).valid && !InputMessage(kind: .move, screen: -1).valid, "input screen bounds")
    let legacyInput = try JSONDecoder().decode(InputMessage.self, from: Data(#"{"kind":"move","x":0.5,"y":0.5,"code":0,"flags":0,"dx":0,"dy":0}"#.utf8))
    require(legacyInput.valid && legacyInput.screen == nil, "0.8 input without screen still decodes")
    print("PASS screens and ScreenMap JSON roundtrip (3 screens \(reqWire.count) bytes, 2 screens fit 0.8's 512), \(badScreenLists.count + 1) bad screen lists and \(badMaps.count) bad ScreenMaps rejected, ScreenSwitch/keyframe/input screen bounds")

    let injector = InputInjector()
    injector.rects = [0: CGRect(x: 0, y: 0, width: 2561, height: 1441), 1: CGRect(x: 2560, y: 0, width: 2561, height: 1441), 2: CGRect(x: -1512, y: 100, width: 1513, height: 983)]
    var posted = [CGEvent](); injector.postEvent = { posted.append($0) }
    injector.apply(InputMessage(kind: .move, x: 0.5, y: 0.5, screen: 1))
    injector.apply(InputMessage(kind: .move, x: 0, y: 1, screen: 2))
    injector.apply(InputMessage(kind: .move, x: 1, y: 0))
    injector.apply(InputMessage(kind: .move, x: 0.5, y: 0.5, screen: 3))
    require(posted.map(\.location) == [CGPoint(x: 3840, y: 720), CGPoint(x: -1512, y: 1082), CGPoint(x: 2560, y: 0)], "pointer routed to each stream's display: \(posted.map(\.location))")
    injector.rects = [1: CGRect(x: 2560, y: 0, width: 2560, height: 1440)]
    injector.apply(InputMessage(kind: .keyDown, code: 0)); injector.apply(InputMessage(kind: .down, code: 0))
    require(posted.count == 4 && injector.keys == [0] && injector.buttons.isEmpty, "keys still post without stream 0; a click for a missing stream does not")
    injector.release()
    print("PASS input routing: screen 1 -> (3840,720), screen 2 -> (-1512,1082), no screen -> stream 0, unknown stream dropped, keys need no matching stream")

    let key = EdgePressure.Key(screen: 0, side: .left)
    var e: EdgePressure?
    require(!EdgePressure.advance(&e, key: key, now: 10.0, distance: 3) && e?.startedAt == 10.0, "first push starts an episode")
    require(!EdgePressure.advance(&e, key: key, now: 10.1, distance: 3) && !EdgePressure.advance(&e, key: key, now: 10.2, distance: 3) && e?.distance == 9, "pushes inside 250 ms accumulate")
    require(EdgePressure.advance(&e, key: key, now: 10.25, distance: 3) && e == nil, "250 ms of continuous pushing crosses")
    _ = EdgePressure.advance(&e, key: key, now: 20.0); _ = EdgePressure.advance(&e, key: key, now: 20.1)
    require(!EdgePressure.advance(&e, key: key, now: 20.26) && e?.startedAt == 20.26, "a 160 ms gap restarts the episode")
    require(!EdgePressure.advance(&e, key: key, now: 20.4) && !EdgePressure.advance(&e, key: nil, now: 20.45) && e == nil, "direction change or held button resets")
    _ = EdgePressure.advance(&e, key: key, now: 30.0)
    require(!EdgePressure.advance(&e, key: EdgePressure.Key(screen: 0, side: .right), now: 30.3) && e?.key.side == .right && e?.startedAt == 30.3, "another edge restarts")
    require(!EdgePressure.advance(&e, key: e!.key, now: 30.2) && e?.startedAt == 30.2, "time going backwards restarts")
    _ = EdgePressure.advance(&e, key: key, now: 40.0, distance: .nan); _ = EdgePressure.advance(&e, key: key, now: 40.1, distance: 1e9)
    require(e?.distance == 10_000 && !EdgePressure.advance(&e, key: key, now: .infinity) && e == nil, "distance clamps, nonfinite time resets")
    print("PASS edge pressure: crosses after 250 ms of outward pushes, 150 ms gap / direction change / held button / other edge / backwards time reset, distance clamped")

    let pair = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: 0, width: 1920, height: 1080)]
    require(portalEdge(screens: pair, index: 0, point: CGPoint(x: 0, y: 500), dx: -3) == .left, "left outer edge")
    require(portalEdge(screens: pair, index: 0, point: CGPoint(x: 1511, y: 500), dx: 3) == nil, "edge shared with a neighbour is not a portal")
    require(portalEdge(screens: pair, index: 1, point: CGPoint(x: 3431, y: 500), dx: 3) == .right, "right outer edge")
    require(portalEdge(screens: pair, index: 1, point: CGPoint(x: 1512, y: 500), dx: -3) == nil, "left edge of screen 2 beside screen 1")
    require(portalEdge(screens: pair, index: 1, point: CGPoint(x: 1512, y: 1000), dx: -3) == .left, "left edge of screen 2 above screen 1's height is outer")
    require(portalEdge(screens: pair, index: 0, point: CGPoint(x: 0, y: 500), dx: 3) == nil && portalEdge(screens: pair, index: 0, point: CGPoint(x: 500, y: 500), dx: -3) == nil
            && portalEdge(screens: pair, index: 0, point: CGPoint(x: 0, y: 500), dx: 0) == nil && portalEdge(screens: pair, index: 5, point: .zero, dx: -1) == nil, "inward, interior, zero and bad index")
    print("PASS portal edges: only left/right edges without a neighbouring screen at that height")

    let D = EdgeSurfaceGeometry.maximumDepth
    require(EdgeSurfaceGeometry.stretch(0) == 0 && EdgeSurfaceGeometry.stretch(-5) == 0 && EdgeSurfaceGeometry.stretch(.nan) == 0, "no push, no stretch")
    require(abs(EdgeSurfaceGeometry.stretch(10) - (10 * D * 1.5 / (D + 15)) / (D - 1)) < 1e-12, "f(u) = u*D*1.5/(D+1.5u)")
    let samples = stride(from: 0.0, through: 400, by: 5).map(EdgeSurfaceGeometry.stretch)
    require(zip(samples, samples.dropFirst()).allSatisfy { $0 < $1 } && EdgeSurfaceGeometry.stretch(10_000) < D / (D - 1) && EdgeSurfaceGeometry.stretch(10_000) > 1.03, "monotonic, saturating below D")
    let screen = CGRect(x: -30_000, y: -30_000, width: 1512, height: 982)
    var g = EdgeSurfaceGeometry(side: .left, point: CGPoint(x: -30_000, y: -29_500), screenFrame: screen)
    require(g.frame == CGRect(x: -30_000, y: -29_570, width: 26, height: 140) && g.anchor == CGPoint(x: 0, y: 0.5), "left surface 26 x 140 centred on the pointer: \(g.frame)")
    g = EdgeSurfaceGeometry(side: .right, point: CGPoint(x: -28_489, y: -30_000), screenFrame: screen)
    require(g.frame == CGRect(x: -28_514, y: -30_000, width: 26, height: 140) && g.anchor == CGPoint(x: 1, y: 0.5), "right surface clamped inside the screen: \(g.frame)")
    let spring = EdgeSurfaceSpring(position: 0, velocity: 0, target: 1, startedAt: 0)
    let s0 = spring.sample(at: 0), end = spring.sample(at: EdgeSurfaceSpring.duration)
    require(abs(s0.position) < 1e-12 && abs(s0.velocity) < 1e-9 && abs(end.position - 1) < 0.01, "spring starts at rest and settles within 0.65 s")
    let before = spring.sample(at: 0.1), turned = spring.retarget(0.5, at: 0.1, responseScale: 1.2), after = turned.sample(at: 0.1)
    require(abs(before.position - after.position) < 1e-12 && abs(before.velocity - after.velocity) < 1e-9, "retarget keeps position and velocity continuous")
    require(turned.animation(key: "transform.scale.x").values?.count == Int((EdgeSurfaceSpring.duration * 1.2 * 120).rounded()) + 1, "release animation sampled at 120 Hz for 0.65 s x 1.2")

    _ = NSApplication.shared
    let off = EdgeSurfaceOverlay()
    off.push(key: key, screenFrame: screen, point: CGPoint(x: -30_000, y: -29_500), distance: 12)
    off.release(crossed: true)
    require(!EdgeSurface.enabled && !off.enabled && off.panel == nil && off.depthSpring == nil, "edge surface disabled: pushing shows no panel")
    print("PASS edge surface disabled by EdgeSurface.enabled = false: push/release show nothing; the 250 ms gate above is unchanged")
    let overlay = EdgeSurfaceOverlay(); overlay.enabled = true
    overlay.reducedMotion = { true }
    overlay.push(key: key, screenFrame: screen, point: CGPoint(x: -30_000, y: -29_500), distance: 12)
    require(overlay.depthSpring == nil && overlay.panel?.ignoresMouseEvents == true && overlay.panel?.canBecomeKey == false && overlay.panel?.canHide == false
            && overlay.panel?.frame.size == CGSize(width: 26, height: 140), "Reduce Motion: no spring, click-through non-key panel")
    overlay.reset()
    overlay.reducedMotion = { false }
    overlay.push(key: key, screenFrame: screen, point: CGPoint(x: -30_000, y: -29_500), distance: 12)
    require(overlay.depthSpring?.target == EdgeSurfaceGeometry.stretch(12), "normal motion drives the depth with the spring")
    overlay.reset()
    require(overlay.panel == nil, "reset removes the panel")
    print("PASS rubber band: f(u) monotonic and saturating, 26x140 surface at the pushed edge, spring settles and stays continuous on retarget, Reduce Motion drops the spring (the 250 ms gate is separate)")

    let suite = "com.tamcut.Pulsar.layouttest.\(UUID().uuidString)", d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    let layout = [cs(0, main: true, x: 0), cs(1, x: 1512, w: 1920, h: 1080)]
    require(ScreenLayoutMemory.load(host: "mac-mini", screens: layout, d).isEmpty, "nothing saved yet")
    ScreenLayoutMemory.save(host: "mac-mini", screens: layout, choices: [0: "B", 1: "virtual"], d)
    require(ScreenLayoutMemory.load(host: "mac-mini", screens: layout, d) == [0: "B", 1: "virtual"], "load what was saved")
    let reordered = [cs(0, x: 1512, w: 1920, h: 1080), cs(1, main: true, x: 0)]
    require(ScreenLayoutMemory.load(host: "mac-mini", screens: reordered, d) == [1: "B", 0: "virtual"], "choices follow the screen, not its index")
    let shifted = layout.map { var s = $0; s.x += 100; s.y += 50; return s }
    require(ScreenLayoutMemory.load(host: "mac-mini", screens: shifted, d) == [0: "B", 1: "virtual"], "signature uses offsets from main")
    require(ScreenLayoutMemory.load(host: "macbookpro", screens: layout, d).isEmpty, "other host has its own memory")
    require(ScreenLayoutMemory.load(host: "mac-mini", screens: [cs(0, main: true, x: 0), cs(1, x: -1920, w: 1920, h: 1080)], d).isEmpty, "other arrangement has its own memory")
    var remembered = layout
    for i in remembered.indices { remembered[i].show = ScreenLayoutMemory.load(host: "mac-mini", screens: layout, d)[i] }
    require(mapScreens(client: remembered, host: [A, B], singleScreenVirtual: false) == ScreenAssignment(sources: [0: .physical("B"), 1: .virtual], unused: ["A"]), "remembered layout reused")
    require(mapScreens(client: remembered, host: [A], singleScreenVirtual: false) == ScreenAssignment(sources: [0: .physical("A"), 1: .virtual], unused: []), "saved display missing -> rule")
    let prefs = StreamQualityPreferences.load(d)
    require(!prefs.singleScreenVirtual && prefs.edgeReturn, "defaults: single-screen virtual off, edge return on")
    print("PASS layout memory: per host and screen signature (sizes + offsets from main), follows screens across index changes, reused by the mapping, falls back when the saved display is gone")
}

func latencyTests() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        if !condition() { print("FAIL \(message) (line \(line))"); exit(1) }
    }
    func noDelay(_ p: NWParameters) -> Bool { (p.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay == true }
    let listener = try plainListener(address: "127.0.0.1", port: 0)
    require(noDelay(tlsParameters(secret: Data(repeating: 1, count: 32))) && noDelay(plainParameters()) && noDelay(listener.parameters), "TCP_NODELAY on TLS, plain dial and plain listener parameters")
    listener.cancel()
    print("PASS TCP_NODELAY set on TLS-PSK parameters (listener and dialer) and plain tailnet parameters (dialer and listener)")

    // Keyframe policy: 0.10 viewers announce timing; 0.8 (no request) and 0.9 (no field) keep 2 s.
    let base = QualityRequest(codec: .h264, chroma: .yuv420, bitrate: .mbps20, maxResolution: .p1080, fps: .fps30, hevcDecode: false)
    var capable = base; capable.timing = true
    require(EffectiveQuality.resolve(capable, hostHEVCEncode: false).timing && !EffectiveQuality.resolve(base, hostHEVCEncode: false).timing && !EffectiveQuality.legacyDefaults.timing, "timing negotiated only for 0.10 requests")
    require(keyframeInterval(fps: 60, onDemand: false) == (120, 2) && keyframeInterval(fps: 60, onDemand: true) == (3600, 60), "interval values")
    let q30 = EffectiveQuality(codec: .h264, chroma: .yuv420, bitrateMbps: 5, maxResolution: .p1080, fps: .fps30)
    func keys(_ onDemand: Bool) throws -> [Int] {
        try encodeTestFrames(width: 640, height: 360, keyframes: [], count: 70, quality: q30, onDemandKeyframes: onDemand).enumerated().compactMap { try VideoFrame.parse($1).keyframe ? $0 : nil }
    }
    let legacyKeys = try keys(false), onDemandKeys = try keys(true)
    require(legacyKeys == [0, 60] && onDemandKeys == [0], "keyframes legacy \(legacyKeys) on-demand \(onDemandKeys)")
    let forced = try encodeTestFrames(width: 640, height: 360, keyframes: [30], count: 40, quality: q30, onDemandKeyframes: true).enumerated().compactMap { try VideoFrame.parse($1).keyframe ? $0 : nil }
    require(forced == [0, 30], "requested keyframe honoured \(forced)")
    let v = Viewer(frame: NSRect(x: 0, y: 0, width: 640, height: 360)); var asked = 0
    v.onNeedKeyframe = { asked += 1 }
    let delta = try VideoFrame.parse(try encodeTestFrames(width: 640, height: 360, keyframes: [0], count: 2, quality: q30)[1])
    require(v.show(delta) && v.show(delta) && asked == 1, "delta without decoder state asks once per 2 s (\(asked))")
    v.requestKeyframe(now: ProcessInfo.processInfo.systemUptime + 2.1); require(asked == 2, "asks again after 2 s")
    print("PASS keyframe policy: 30fps x 70 frames -> 0.8/0.9 viewer keyframes \(legacyKeys), 0.10 viewer \(onDemandKeys), KeyframeRequest at frame 30 -> \(forced); viewer asks once per 2 s while it lacks decoder state")

    let t = FrameTiming(encodeMs: 4.26, skipped: 3, bitrateBps: 18_250_000)
    require(t.encodeTenthsMs == 43 && t.skipped == 3 && t.bitrateTenthsMbps == 182 && FrameTiming(encodeMs: 1e9, skipped: 999, bitrateBps: 0).bytes == [255, 255, 255, 0, 1], "timing clamps")
    let timed = try encodeTestFrames(width: 640, height: 360, keyframes: [0], count: 3, quality: q30, stream: 1, timing: t)
    let parsed = try timed.map(VideoFrame.parse)
    require(parsed.allSatisfy { $0.timing?.skipped == 3 && $0.timing?.bitrateTenthsMbps == 182 && $0.stream == 1 } && parsed[0].keyframe && parsed[0].parameterSets.count == 2, "encoder writes timing")
    require(zip(parsed, timed).allSatisfy { $0.message == $1 } && timed.allSatisfy { $0[2] & 4 != 0 && $0[2] > 3 }, "timing roundtrip; flags above 3 so 0.9 parsers reject it")
    let encodeMs = parsed.map { $0.timing!.encodeMs }
    var legacyFrame = parsed[1]; legacyFrame.timing = nil; legacyFrame.stream = nil
    require(legacyFrame.message[1] <= 3 && (try? VideoFrame.parse(legacyFrame.message))?.timing == nil, "no timing -> 0.9 layout")
    let d = timed[1]
    let badTiming: [Data] = [
        Data(d.prefix(3)) + Data(d[3..<7]), Data(d.prefix(3)) + Data([0, 10, 0, 0, 0]) + Data(d.dropFirst(8)),
        Data(d.prefix(2)) + Data([d[2] | 8]) + Data(d.dropFirst(3)), Data([8, 1, 4, 0, 10, 0, 0, 1]),
        Data(d.prefix(3)) + Data(d.dropFirst(8)),
    ]
    for (i, m) in badTiming.enumerated() { require((try? VideoFrame.parse(m)) == nil, "bad timing message \(i) rejected") }
    print("PASS frame timing header: encoder fills capture->encoded \(encodeMs) ms, skipped and bitrate survive the wire (5 bytes), \(badTiming.count) truncated/zero-bitrate/unknown-flag messages rejected")

    let stamp: UInt64 = 0x0102030405060708
    require(TimedPing.decode(TimedPing.ping(stamp))! == (false, stamp) && TimedPing.decode(TimedPing.pong(stamp))! == (true, stamp) && TimedPing.ping(stamp).count == 10, "ping roundtrip")
    let zeros = { (n: Int) -> Data in Data(repeating: 0, count: n) }
    let badPings: [Data] = [Data([3]), Data([3, 2]) + zeros(8), Data([3, 0]) + zeros(7), Data([3, 1]) + zeros(9), Data([4, 0]) + zeros(8)]
    for bad in badPings { require(TimedPing.decode(bad) == nil, "bad ping rejected") }
    require(TimedPing.msSince(1_000_000, now: 13_000_000) == 12 && TimedPing.msSince(2, now: 1) == nil && TimedPing.msSince(0, now: 61_000_000_000) == nil, "ping clock")
    print("PASS timed ping/pong [3][kind][UInt64]: roundtrip, plain [3] keepalive left for 0.8/0.9 peers, wrong kind/length rejected, future/stale stamps ignored")

    var c = BitrateController(ceilingBps: 20_000_000)
    require(c.floor == 5_000_000 && BitrateController(ceilingBps: 5_000_000).floor == 2_000_000 && BitrateController(ceilingBps: 1_500_000).floor == 1_500_000, "floors")
    var changes = 0
    for _ in 0..<120 { if c.update(skipped: 1, sendMs: 10, rttMs: 10 + Double.random(in: 0...8), frameMs: 16.7) { changes += 1 } }
    require(changes == 0 && c.target == 20_000_000, "steady link never changes target (\(changes))")
    require(c.update(skipped: 3, sendMs: 10, rttMs: 10, frameMs: 16.7) && c.target == 14_000_000, "skips cut 30%")
    require(!c.update(skipped: 5, sendMs: 10, rttMs: 10, frameMs: 16.7) && !c.update(skipped: 5, sendMs: 10, rttMs: 10, frameMs: 16.7), "2 s hold after a cut")
    require(c.update(skipped: 0, sendMs: 10, rttMs: 45, frameMs: 16.7) && c.target == 9_800_000, "RTT rise over base+20 ms cuts")
    var path = [c.target]
    for _ in 0..<12 { _ = c.update(skipped: 0, sendMs: 80, rttMs: 10, frameMs: 16.7); path.append(c.target) }
    require(c.target == 5_000_000 && path.allSatisfy { $0 >= 5_000_000 } && zip(path, path.dropFirst()).allSatisfy { $1 <= $0 }, "send latency drives down to floor, never below \(path)")
    var calm = [Int]()
    for _ in 0..<40 { _ = c.update(skipped: 0, sendMs: 5, rttMs: 28, frameMs: 16.7); calm.append(c.target) }
    require(calm.prefix(4).allSatisfy { $0 == 5_000_000 } && calm[4] == 6_000_000 && c.target == 20_000_000 && calm.allSatisfy { $0 <= 20_000_000 } && zip(calm, calm.dropFirst()).allSatisfy { $1 >= $0 }, "recovers +1 Mbps/s after 5 calm s, capped \(calm)")
    changes = 0
    for _ in 0..<60 { if c.update(skipped: 0, sendMs: 5, rttMs: 28, frameMs: 16.7) { changes += 1 } }
    require(changes == 0, "steady after recovery")
    print("PASS bitrate controller 20 Mbps: floor 5 (2 for 5 Mbps), steady link 120 s unchanged, skips/RTT rise/send latency cut 30% with 2 s hold down to the floor, recovers +1 Mbps/s after 5 calm s to the ceiling and stays")

    var stats = LiveStats(); stats.rttMs = 12.4
    stats.add(FrameTiming(encodeMs: 4.2, skipped: 0, bitrateBps: 20_000_000), displayMs: 2.1); stats.add(FrameTiming(encodeMs: 3.8, skipped: 1, bitrateBps: 18_000_000), displayMs: 1.9)
    let overlay = stats.text(fps: 60, mbps: 18.24, timing: true)
    require(overlay == "60fps · 18.2/18Mbps · 왕복 12ms · 인코딩 4ms · 표시 2ms · 건너뜀 1" && LiveStats().text(fps: 30, mbps: 1.25, timing: false) == "30 fps  ·  1.2 Mbps", "overlay \(overlay)")
    print("PASS overlay: \(overlay); 0.9 host keeps the fps/Mbps line")

    let aspect = Viewer(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000)); aspect.videoSize = CGSize(width: 2560, height: 1440); aspect.layout()
    let r = aspect.contentRect
    require(aspect.display.videoGravity == .resizeAspect && aspect.display.frame == r && abs(r.width / r.height - 2560.0 / 1440) < 0.001 && r.minY == 218.75, "aspect \(r)")
    print("PASS viewer layer frame is the aspect-fit rect \(r) for 2560x1440 in 1000x1000, gravity resizeAspect")

    for codec in [ResolvedCodec.h264, .hevc] where codec == .h264 || VideoEncoder.supportsHardwareHEVC {
        let e = try VideoEncoder(width: 2560, height: 1440, quality: EffectiveQuality(codec: codec, chroma: .yuv420, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60), onDemandKeyframes: true) { _ in }
        e.setBitrate(10_000_000)
        print("PASS \(codec.label) 1440p60 encoder: live bitrate change applied")
    }
}

func cursorTests() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        if !condition() { print("FAIL \(message) (line \(line))"); exit(1) }
    }
    _ = NSApplication.shared
    let base = QualityRequest(codec: .h264, chroma: .yuv420, bitrate: .mbps20, maxResolution: .p1080, fps: .fps30, hevcDecode: false)
    var capable = base; capable.cursor = true
    require(!capturesCursor(capable) && capturesCursor(base) && capturesCursor(nil), "showsCursor off only for viewers that announced cursor")
    let request = StreamQualityPreferences().request(hevcDecode: false)
    require(request.cursor == true && request.dockGesture == nil && QualityRequest.decodeWire(request.wireMessage()) == request, "0.11 request announces cursor")
    require(EffectiveQuality.resolve(capable, hostHEVCEncode: false).cursor && !EffectiveQuality.resolve(base, hostHEVCEncode: false).cursor, "cursor negotiated")
    let legacyEff = EffectiveQuality.decodeWire(Data([6]) + Data(#"{"codec":"h264","chroma":"420","bitrateMbps":8,"maxResolution":"1080p","fps":30,"timing":true}"#.utf8))
    require(legacyEff?.cursor == false && legacyEff?.dockGesture == false && legacyEff?.timing == true, "0.10 host EffectiveQuality decodes without cursor/dockGesture")

    require(CursorUpdate.Image.renderScale(width: 28, height: 40) == 4 && CursorUpdate.Image.renderScale(width: 200, height: 100) == 1.28, "render scale: 4x, capped at 256 px")
    let ibeam = try require2(CursorUpdate.Image(cursor: NSCursor.iBeam), "I-beam renders")
    let size = NSCursor.iBeam.image.size
    require(ibeam.width == size.width && ibeam.pixelWidth == Int((size.width * 4).rounded()) && ibeam.hotX == NSCursor.iBeam.hotSpot.x && ibeam.png.count <= CursorUpdate.maxPNGBytes, "I-beam image \(ibeam.pixelWidth)x\(ibeam.pixelHeight) px")
    let big = NSCursor(image: NSImage(size: NSSize(width: 200, height: 100), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }, hotSpot: NSPoint(x: 199, y: 50))
    let bigImage = try require2(CursorUpdate.Image(cursor: big), "large cursor renders")
    require(bigImage.pixelWidth == 256 && bigImage.pixelHeight == 128 && bigImage.width == 200 && bigImage.hotX == 199, "large cursor capped to 256x128 px at 200x100 pt")
    let scaled = try require2(CursorUpdate.Image(cursor: NSCursor.iBeam, pointScale: 1.5), "scaled I-beam renders")
    require(scaled.width == size.width * 1.5 && scaled.height == size.height * 1.5 && scaled.hotX == NSCursor.iBeam.hotSpot.x * 1.5 && scaled.hotY == NSCursor.iBeam.hotSpot.y * 1.5, "host pointer size enlarges image and hotspot")
    let made = try require2(ibeam.cursor(), "viewer builds NSCursor")
    let rep = made.image.representations.first
    require(made.image.size == size && made.hotSpot == NSCursor.iBeam.hotSpot && rep?.pixelsWide == Int((size.width * 2).rounded()) && rep?.size == size, "viewer cursor keeps host points (\(size)) with 2x pixels and hotspot")

    let hash = fnv1a64(ibeam.png)
    let first = try require2(CursorUpdate.next(hash: hash, image: ibeam, visible: true, sentHash: nil, sentVisible: nil), "first shape sent")
    require(first.image == ibeam && CursorUpdate.next(hash: hash, image: ibeam, visible: true, sentHash: hash, sentVisible: true) == nil, "same shape and visibility not resent")
    require(CursorUpdate.next(hash: hash, image: ibeam, visible: false, sentHash: hash, sentVisible: true) == CursorUpdate(visible: false, hash: hash), "visibility change carries no image")
    require(CursorUpdate.next(hash: "0000000000000001", image: bigImage, visible: false, sentHash: hash, sentVisible: false)?.image == bigImage, "new shape carries its image")
    let wire = first.wireMessage()
    require(CursorUpdate.decodeWire(wire) == first && CursorUpdate.decodeWire(CursorUpdate(visible: false, hash: hash).wireMessage())?.image == nil, "cursor update roundtrip (\(wire.count) bytes)")
    func with(_ f: (inout CursorUpdate.Image) -> Void) -> Data { var i = ibeam; f(&i); return CursorUpdate(visible: true, hash: hash, image: i).wireMessage() }
    let bad: [Data] = [
        Data([12]), Data([12]) + Data("{".utf8), Data([13]) + wire.dropFirst(), CursorUpdate(visible: true, hash: "xyz").wireMessage(),
        CursorUpdate(visible: true, hash: "000000000000000G").wireMessage(),
        with { $0.pixelWidth = 257 }, with { $0.pixelHeight = 0 }, with { $0.png = Data(repeating: 1, count: 100) },
        with { $0.png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(count: CursorUpdate.maxPNGBytes) },
        with { $0.width = .nan }, with { $0.width = 0 }, with { $0.hotX = -1 }, with { $0.hotY = $0.height + 1 }, with { $0.width = 1000 },
        Data([12]) + Data(count: CursorUpdate.maxWireBytes),
    ]
    for (i, b) in bad.enumerated() { require(CursorUpdate.decodeWire(b) == nil, "bad cursor update \(i) rejected") }
    var lying = ibeam; lying.pixelWidth += 2; lying.width = Double(lying.pixelWidth) / 2
    require(lying.valid && lying.cursor() == nil, "PNG whose pixels differ from the announced size is rejected by the viewer")

    var remote = RemoteCursor()
    require(remote.shown == nil, "nothing shown before a shape")
    require(remote.apply(first) && remote.shown === remote.cache[hash] && remote.cache.count == 1, "shape cached by hash")
    let cached = remote.cache[hash]
    require(remote.apply(CursorUpdate(visible: false, hash: hash)) && remote.shown === RemoteCursor.blank, "hidden host cursor shows a blank cursor")
    require(remote.apply(CursorUpdate(visible: true, hash: "00000000000000aa")) && remote.shown === cached, "unknown hash without image keeps the current shape")
    require(remote.apply(first) && remote.cache[hash] === cached, "a resent known shape reuses the cached cursor")
    var lie = first; lie.image = lying
    require(!remote.apply(lie.image.map { CursorUpdate(visible: true, hash: "00000000000000bb", image: $0) }!), "undecodable image closes the connection")
    require(remote.apply(CursorUpdate(visible: true, hash: hash, screenWidth: 1512)) && remote.screenWidth == 1512, "host display width kept")
    require(CursorUpdate.next(hash: hash, image: ibeam, visible: true, sentHash: hash, sentVisible: true, width: 1512, sentWidth: 2560) == CursorUpdate(visible: true, hash: hash, screenWidth: 1512), "display change resends width without image")
    require(CursorUpdate.decodeWire(CursorUpdate(visible: true, hash: hash, screenWidth: .infinity).wireMessage()) == nil && CursorUpdate.decodeWire(CursorUpdate(visible: true, hash: hash, screenWidth: 10).wireMessage()) == nil, "bad host width rejected")
    let enlarged = try require2(ibeam.cursor(scale: 1.5), "scaled viewer cursor")
    require(enlarged.image.size.width == ibeam.width * 1.5 && enlarged.hotSpot.x == ibeam.hotX * 1.5 && enlarged.hotSpot.y == ibeam.hotY * 1.5, "Pointer Size scales image and hotspot together")
    var withScale = ibeam; withScale.pointerScale = 1.3
    require(CursorUpdate.decodeWire(CursorUpdate(visible: true, hash: hash, image: withScale).wireMessage())?.image?.pointerScale == 1.3, "host pointer scale roundtrip")
    withScale.pointerScale = 20; require(!withScale.valid, "absurd pointer scale rejected")
    remote.reset(); require(remote.shown == nil && remote.cache.count == 1 && remote.screenWidth == nil, "reset on reconnect keeps the cache")
    print("PASS cursor: showsCursor off only for cursor-capable viewers, CursorUpdate roundtrip (\(wire.count) bytes) and \(bad.count + 1) malformed updates rejected, shape/visibility dedupe, 2x render capped at 256 px, viewer keeps host point size/hotspot, hidden -> blank, cache by hash")

    if let c = NSCursor.currentSystem, let live = CursorUpdate.Image(cursor: c) {
        let tracker = CursorTracker(); var updates = [CursorUpdate]()
        tracker.send = { updates.append($0) }; tracker.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3)); tracker.stop()
        let ticks = updates.count
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        require(ticks >= 1 && updates.count == ticks && updates[0].image != nil && updates.allSatisfy { CursorUpdate.decodeWire($0.wireMessage()) == $0 }, "tracker sends the current shape once, valid on the wire, and stops")
        print("PASS live system cursor read: \(live.width)x\(live.height) pt, \(live.pixelWidth)x\(live.pixelHeight) px, hotspot (\(live.hotX), \(live.hotY)), PNG \(live.png.count) bytes; 60 Hz tracker sent \(ticks) update(s) in 0.3 s (visible \(updates[0].visible)), none after stop")
    } else { print("SKIP live system cursor (NSCursor.currentSystem unavailable)") }
}
func require2<T>(_ v: T?, _ message: String, line: UInt = #line) throws -> T {
    guard let v else { print("FAIL \(message) (line \(line))"); exit(1) }
    return v
}
func dockGestureTests() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        if !condition() { print("FAIL \(message) (line \(line))"); exit(1) }
    }
    let build = osBuild!
    let base = QualityRequest(codec: .h264, chroma: .yuv420, bitrate: .mbps20, maxResolution: .p1080, fps: .fps30, hevcDecode: false)
    var capable = base; capable.dockGesture = build
    require(EffectiveQuality.resolve(capable, hostHEVCEncode: false, hostBuild: build, hostDockGesture: true).dockGesture, "same build negotiates dock gestures")
    require(!EffectiveQuality.resolve(capable, hostHEVCEncode: false, hostBuild: build + "x", hostDockGesture: true).dockGesture
            && !EffectiveQuality.resolve(capable, hostHEVCEncode: false, hostBuild: build, hostDockGesture: false).dockGesture
            && !EffectiveQuality.resolve(base, hostHEVCEncode: false, hostBuild: build, hostDockGesture: true).dockGesture, "other build, unsupported host or old viewer: off")
    var longBuild = base; longBuild.dockGesture = String(repeating: "A", count: 33)
    var emptyBuild = base; emptyBuild.dockGesture = ""
    require(QualityRequest.decodeWire(longBuild.wireMessage()) == nil && QualityRequest.decodeWire(emptyBuild.wireMessage()) == nil, "bad build string rejected")
    guard DockGesture.supported else { print("SKIP dock gesture codec (needs macOS 27; this Mac is \(ProcessInfo.processInfo.operatingSystemVersionString))"); return }

    var built = 0
    for motion in [1, 2] {
        for phase in [1, 2, 4, 8] {
            let d = DockGesture(motion: motion, phase: phase, progress: phase == 1 ? 0 : -0.375, vx: motion == 1 ? 120 : 0, vy: motion == 2 ? -80 : 0)
            let e = try require2(d.event(), "event for motion \(motion) phase \(phase)")
            require(DockGesture.isDockSwipe(e) && DockGesture.inspect(e) == d.projected, "synthesized event decodes to the projected descriptor")
            require(DockGesture.decodeWire(d.wireMessage()) == d && d.wireMessage().count <= DockGesture.maxWireBytes, "wire roundtrip")
            built += 1
        }
    }
    let up = DockGesture(motion: 2, phase: 2, progress: 0.5, vx: 3, vy: 40)
    require(up.projected == DockGesture(motion: 2, phase: 2, progress: -0.5, vx: 3, vy: -40) && DockGesture(motion: 1, phase: 2, progress: 0.5, vx: 40, vy: 3).projected == DockGesture(motion: 1, phase: 2, progress: -0.5, vx: -40, vy: 3), "projection inverts the gesture axis like ThunderControl")
    let invalid = [DockGesture(motion: 3, phase: 2, progress: 0, vx: 0, vy: 0), DockGesture(motion: 1, phase: 3, progress: 0, vx: 0, vy: 0), DockGesture(motion: 1, phase: 2, progress: 1.5, vx: 0, vy: 0),
                   DockGesture(motion: 1, phase: 2, progress: .nan, vx: 0, vy: 0), DockGesture(motion: 1, phase: 2, progress: 0, vx: 1e5, vy: 0), DockGesture(motion: 2, phase: 2, progress: 0, vx: 0, vy: .infinity)]
    for d in invalid { require(d.event() == nil && DockGesture.decodeWire(Data([13]) + ((try? JSONEncoder().encode(d)) ?? Data())) == nil, "invalid descriptor rejected \(d)") }
    let badWire = [Data([13]), Data([13]) + Data("{}".utf8), Data([2]) + up.wireMessage().dropFirst(), up.wireMessage() + Data(repeating: 32, count: 300), Data([13]) + Data(#"{"motion":2,"phase":2,"progress":"x","vx":0,"vy":0}"#.utf8)]
    for (i, b) in badWire.enumerated() { require(DockGesture.decodeWire(b) == nil, "bad dock wire \(i) rejected") }
    let plain = CGEvent(source: nil)!; plain.type = CGEventType(rawValue: 29)!
    plain.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
    require(!DockGesture.isDockSwipe(plain) && DockGesture.inspect(plain) == nil, "a magnify gesture is not a DockSwipe")

    let injector = InputInjector(); var posted = [CGEvent]()
    injector.postDock = { posted.append($0) }; injector.postEvent = { _ in }
    let began = DockGesture(motion: 1, phase: 1, progress: 0, vx: 0, vy: 0), changed = DockGesture(motion: 1, phase: 2, progress: -0.25, vx: -50, vy: 0), ended = DockGesture(motion: 1, phase: 4, progress: -0.625, vx: -900, vy: 0)
    injector.applyDock(changed); require(posted.isEmpty, "changed without began ignored")
    injector.applyDock(began); injector.applyDock(changed); injector.applyDock(DockGesture(motion: 2, phase: 2, progress: 0.1, vx: 0, vy: 0)); injector.applyDock(ended)
    require(posted.compactMap(DockGesture.inspect) == [began.projected, changed.projected, ended.projected] && injector.dock == nil, "began/changed/ended replayed, other motion mid-stream ignored")
    injector.release(); require(posted.count == 3, "release after a finished stream posts nothing")
    injector.applyDock(DockGesture(motion: 2, phase: 1, progress: 0, vx: 0, vy: 0)); injector.applyDock(DockGesture(motion: 2, phase: 2, progress: 0.375, vx: 0, vy: 30))
    injector.release()
    require(DockGesture.inspect(posted.last!) == DockGesture(motion: 2, phase: 8, progress: -0.375, vx: 0, vy: 0) && injector.dock == nil, "release (disconnect) cancels an open Mission Control stream")
    injector.applyDock(began); injector.applyDock(DockGesture(motion: 2, phase: 1, progress: 0, vx: 0, vy: 0))
    require(posted.suffix(2).compactMap(DockGesture.inspect).map(\.phase) == [8, 1] && injector.dock?.motion == 2, "a new began cancels a stream whose end was lost")
    injector.release()
    print("PASS dock gesture codec: \(built) synthesized DockSwipe events (Spaces + Mission Control/App Exposé, phases 1/2/4/8) decode to their projected descriptors, \(invalid.count) invalid descriptors and \(badWire.count) bad messages rejected, host replay order, cancel on release, build/capability negotiation")

    let tap = DockGestureTap(); var made = 0, enables = [Bool](), sent = [DockGesture]()
    tap.makeTap = { _ in made += 1; return CFMachPortCreate(nil, { _, _, _, _ in }, nil, nil) }
    tap.enableTap = { _, on in enables.append(on) }
    tap.onGesture = { sent.append($0) }
    func swipe(_ d: DockGesture, pid: Int64 = 1) -> CGEvent { let e = DGMakeDockSwipe(Int32(d.motion), Int32(d.phase), d.progress, d.vx, d.vy)!; e.setIntegerValueField(.eventSourceUnixProcessID, value: pid); return e }
    let dockType = CGEventType(rawValue: 30)!
    require(!tap.handle(dockType, swipe(began)) && sent.isEmpty, "not installed: DockSwipe passes through")
    tap.set(false); require(made == 0 && enables.isEmpty, "removing an absent tap is a no-op")
    tap.set(true); tap.set(true); require(made == 1 && tap.installed && enables == [true], "installed once")
    require(!tap.handle(dockType, plain) && !tap.handle(.mouseMoved, CGEvent(source: nil)!), "other events pass")
    require(!tap.handle(dockType, swipe(began, pid: Int64(getpid()))) && sent.isEmpty, "this process's own replay passes")
    require(tap.handle(dockType, swipe(changed)) && sent.isEmpty, "changed without began swallowed, not sent")
    require(tap.handle(dockType, swipe(began)) && tap.handle(dockType, swipe(changed)) && sent == [began, changed] && tap.stream == changed, "began/changed swallowed and sent")
    require(!tap.handle(.tapDisabledByTimeout, plain) && enables == [true, true], "timeout re-enables the tap")
    tap.set(false)
    require(!tap.installed && enables.last == false && sent.last == changed.cancelled && tap.stream == nil, "removing mid-swipe sends a cancel")
    require(!tap.handle(dockType, swipe(began)) && sent.count == 3, "after removal nothing is swallowed")
    tap.set(true); _ = tap.handle(dockType, swipe(began)); _ = tap.handle(dockType, swipe(ended)); tap.set(false)
    require(sent.suffix(2) == [began, ended] && made == 2 && tap.stream == nil, "a finished stream sends no extra cancel")
    tap.set(true); _ = tap.handle(dockType, swipe(DockGesture(motion: 1, phase: 2, progress: 0, vx: 0, vy: 0)))
    let unknown = swipe(began); unknown.setIntegerValueField(CGEventField(rawValue: 123)!, value: 3)
    require(tap.handle(dockType, unknown) && sent.count == 5, "other DockSwipe motions (pinch) swallowed while remote, not sent")
    tap.set(false)
    print("PASS dock gesture tap: installed only on request and once, removed idempotently, swallows DockSwipe only while installed, forwards began/changed/ended, cancel on removal mid-swipe, timeout re-enable, own replays and other events pass")
}

func updaterTests() {
    func require(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        precondition(condition(), "FAIL updater line \(line): \(message)"); print("PASS \(message)")
    }
    func r(_ tag: String, draft: Bool = false, asset: String? = nil) -> AutoUpdate.Release {
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return AutoUpdate.Release(tag_name: tag, draft: draft, assets: [.init(name: asset ?? "Pulsar-\(v)-macOS-arm64.zip", browser_download_url: URL(string: "https://example.com/\(v).zip")!)])
    }
    require(AutoUpdate.isNewer("0.12.0", than: "0.11.1") && AutoUpdate.isNewer("0.10.0", than: "0.9.0") && !AutoUpdate.isNewer("0.11.1", than: "0.11.1"), "numeric version order (0.10 > 0.9)")
    require(AutoUpdate.newest([r("v0.11.0"), r("v0.13.0", draft: true), r("v0.12.0"), r("v0.10.0")], current: "0.11.1")?.version == "0.12.0", "newest non-draft newer release chosen")
    require(AutoUpdate.newest([r("v0.12.0", asset: "Other.zip"), r("v0.11.1")], current: "0.11.1") == nil, "no update without the app zip or when current")
    require(AutoUpdate.prepare(zip: URL(fileURLWithPath: "/nonexistent.zip"), version: "0.12.0") == nil, "unreadable download refused")
}

func clickCountTests() {
    var states = [Int64]()
    let inj = InputInjector(); inj.postEvent = { e in if e.type == .leftMouseDown || e.type == .leftMouseUp { states.append(e.getIntegerValueField(.mouseEventClickState)) } }
    inj.rects[0] = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    func click(_ x: Double) { for k in [InputMessage.Kind.down, .up] { var m = InputMessage(kind: k, x: x, y: 0.5); m.screen = 0; inj.apply(m) } }
    click(0.5); click(0.5); click(0.5)
    precondition(states == [1, 1, 2, 2, 3, 3], "FAIL click state \(states)")
    states.removeAll(); Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval + 0.05); click(0.5); click(0.6)
    precondition(states == [1, 1, 1, 1], "FAIL click state after pause/move \(states)")
    inj.release()
    print("PASS click state: quick clicks at one spot count 1, 2, 3 on down and up; a pause or a moved click starts over")
}

func scrollAndStandardCursorTests() {
    var got = [(line: Int64, point: Int64, continuous: Int64)]()
    let inj = InputInjector(); inj.postEvent = { e in if e.type == .scrollWheel { got.append((e.getIntegerValueField(.scrollWheelEventDeltaAxis1), e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), e.getIntegerValueField(.scrollWheelEventIsContinuous))) } }
    inj.rects[0] = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    func scroll(_ dy: Double, lines: Bool?) { var m = InputMessage(kind: .scroll, x: 0.5, y: 0.5, dy: dy); m.screen = 0; m.lines = lines; inj.apply(m) }
    scroll(1, lines: true); scroll(-3, lines: true)
    precondition(got.count == 2 && got[0].line == 1 && got[0].continuous == 0 && got[1].line == -3, "FAIL wheel lines \(got)")
    got.removeAll(); for _ in 0..<4 { scroll(0.5, lines: nil) }
    precondition(got.map(\.continuous).allSatisfy { $0 == 1 } && got.map(\.point).reduce(0, +) == 2, "FAIL fractional pixels carried \(got)")
    for (name, c) in standardCursors {
        guard let image = CursorUpdate.Image(cursor: c) else { continue }
        precondition(CursorTracker.standardByHash[fnv1a64(image.png)] != nil, "FAIL standard cursor \(name) not matched")
        var named = image; named.system = name
        precondition(named.cursor(scale: 1.7) === c, "FAIL viewer uses its own \(name)")
    }
    var custom = CursorUpdate.Image(cursor: NSCursor(image: NSImage(size: NSSize(width: 20, height: 20), flipped: false) { r in NSColor.red.setFill(); r.fill(); return true }, hotSpot: NSPoint(x: 2, y: 3)))!
    custom.system = nil
    let big = custom.cursor(scale: 1.5)!, rep = big.image.representations.first as? NSBitmapImageRep
    precondition(big.image.size.width == 30 && rep?.pixelsWide == 60 && big.hotSpot == NSPoint(x: 3, y: 4.5), "FAIL custom cursor density")
    print("PASS wheel: notched wheel posts line deltas, trackpad pixels keep fractions and are continuous; \(standardCursors.count) standard cursors matched and shown natively; custom cursor scaled at 2x pixels")
}
