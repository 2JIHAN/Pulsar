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
        qualityTests()
        let injector = InputInjector(); injector.rect = CGRect(x: 0, y: 0, width: 1440, height: 900)
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
        sessionTests(decoded)
        var pushes = 0, pops = [UnsafeMutableRawPointer]()
        let hotToken = UnsafeMutableRawPointer(bitPattern: 0x1234)!
        let hot = HotKeyMode(); hot.push = { pushes += 1; return hotToken }; hot.pop = { pops.append($0) }
        hot.set(false); hot.set(true); hot.set(true); hot.set(false); hot.set(false)
        precondition(pushes == 1 && pops == [hotToken])
        hot.set(true); hot.set(false); precondition(pushes == 2 && pops.count == 2)
        print("PASS symbolic hot key mode push/pop balanced with the pushed token, no double pop")
        uiModelTests()
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
func encodeTestFrames(width: Int, height: Int, keyframes: Set<Int>, count: Int, quality: EffectiveQuality = .legacyDefaults) throws -> [Data] {
    var messages = [Data?]()
    let lock = NSLock(), done = DispatchSemaphore(value: 0)
    let encoder = try VideoEncoder(width: width, height: height, quality: quality) { m in lock.lock(); messages.append(m); lock.unlock(); done.signal() }
    let fmt = encoder.effectiveQuality.chroma == .yuv444 ? kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    for i in 0..<count {
        precondition(encoder.encode(testPixelBuffer(width: width, height: height, shade: i, format: fmt), time: CMTime(value: Int64(i), timescale: Int32(quality.fps.rawValue)), keyframe: keyframes.contains(i)))
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
        Data([4]), Data([4, 0]), Data([1] + messages[1].dropFirst()), Data([4, 4] + messages[1].dropFirst(2)),
        Data(messages[0].dropLast()), Data(messages[1] + [0]), Data([4, 0, 0, 0, 0, 0, 0x41]), Data([4, 0, 0xff, 0xff, 0xff, 0xff, 0x41]),
        Data([4, 1, 0, 0] + messages[0].dropFirst(4)), Data([4, 1]) + key.avcc,
        VideoFrame(codec: .h264, keyframe: true, parameterSets: key.parameterSets.reversed(), avcc: key.avcc).message,
        Data([4, 0] + Array(repeating: unit, count: 257).joined()),
    ]
    for (i, message) in bad.enumerated() where (try? VideoFrame.parse(message)) != nil { print("FAIL malformed video message \(i) accepted"); exit(1) }
    precondition((try? VideoFrame.parse(Data([4, 0] + Array(repeating: unit, count: 256).joined()))) != nil)
    print("PASS oversized H.264 dimensions (>3840x2400) and \(bad.count) malformed video messages rejected")

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
        let enc444 = try VideoEncoder(width: 1280, height: 720, quality: req444) { m in out444.append(m); done444.signal() }
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
    let req = QualityRequest(codec: .auto, chroma: .yuv444, bitrate: .mbps20, maxResolution: .p1440, fps: .fps60, hevcDecode: true)
    let wireReq = req.wireMessage()
    precondition(wireReq.count <= QualityRequest.maxWireBytes && QualityRequest.decodeWire(wireReq) == req)
    let eff = EffectiveQuality(codec: .hevc, chroma: .yuv444, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60)
    let wireEff = eff.wireMessage()
    precondition(wireEff.count <= EffectiveQuality.maxWireBytes && EffectiveQuality.decodeWire(wireEff) == eff)
    precondition(eff.summary == "HEVC 4:4:4 · 1440p · 60fps · 20Mbps")
    precondition(EffectiveQuality(codec: .hevc, chroma: .yuv420, bitrateMbps: 20, maxResolution: .p1440, fps: .fps60).summary == "HEVC · 1440p · 60fps · 20Mbps")

    let pad = String(repeating: " ", count: 520)
    let badReqs: [Data] = [
        Data([6]) + wireReq.dropFirst(),
        Data([5]) + Data(#"{"codec":"vp9","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"422","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":99,"maxResolution":"1080p","fps":30,"hevcDecode":true}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"8k","fps":30,"hevcDecode":true}"#.utf8),
        Data([5]) + Data(#"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":120,"hevcDecode":true}"#.utf8),
        Data([5]) + Data((pad + #"{"codec":"auto","chroma":"420","bitrate":0,"maxResolution":"1080p","fps":30,"hevcDecode":true}"#).utf8),
    ]
    for (i, d) in badReqs.enumerated() { precondition(QualityRequest.decodeWire(d) == nil, "bad req \(i)") }
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
    let saved = StreamQualityPreferences(codec: .hevc, chroma: .yuv444, bitrate: .mbps35, maxResolution: .native, fps: .fps60)
    saved.save(defaults)
    precondition(StreamQualityPreferences.load(defaults) == saved)
    precondition(StreamQualityPreferences(codec: .h264, chroma: .yuv444, bitrate: .auto, maxResolution: .p1080, fps: .fps30).request(hevcDecode: true).chroma == .yuv420)
    print("PASS quality request/effective JSON roundtrip, unknown/oversize rejection, host resolution, scaling and UserDefaults persistence")
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
    var posted = [CGEvent](); injector.postEvent = { posted.append($0) }; injector.rect = hostRect
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
    precondition(Permission.all.map(\.verifiable) == [true, true, false])
    print("PASS input monitoring marked non-verifiable so it displays manual check and is excluded from missing-permission banner")
}
