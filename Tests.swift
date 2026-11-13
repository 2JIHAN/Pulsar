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
        for bad in [Data([0,0,0,0]), Data([255,255,255,255]), Data([0,64,0,1])] { var p = PacketParser(); precondition((try? p.feed(bad)) == nil) }
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
                    bad.onClose = { guard bad.failure != nil else { print("FAIL wrong key closed without TLS rejection state=\(bad.connection.state)"); exit(1) }; print("PASS wrong TLS key rejected before application data"); print("SELF-TEST PASS"); exit(0) }
                    bad.start()
                }
                p.start()
            }
        }
        listener.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { print("FAIL TLS test timeout (no insecure fallback)"); exit(1) }
    }
}
func testPixelBuffer(width: Int, height: Int, shade: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
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
func encodeTestFrames(width: Int, height: Int, keyframes: Set<Int>, count: Int) throws -> [Data] {
    var messages = [Data?]()
    let lock = NSLock(), done = DispatchSemaphore(value: 0)
    let encoder = try VideoEncoder(width: width, height: height) { m in lock.lock(); messages.append(m); lock.unlock(); done.signal() }
    for i in 0..<count {
        precondition(encoder.encode(testPixelBuffer(width: width, height: height, shade: i), time: CMTime(value: Int64(i), timescale: 30), keyframe: keyframes.contains(i)))
        precondition(done.wait(timeout: .now() + 5) == .success)
    }
    lock.lock(); defer { lock.unlock() }
    precondition(messages.count == count && messages.allSatisfy { $0 != nil })
    return messages.map { $0! }
}
func videoTests() throws {
    let messages = try encodeTestFrames(width: 1280, height: 720, keyframes: [0, 4], count: 6)
    let frames = try messages.map(VideoFrame.parse)
    precondition(frames.map(\.keyframe) == [true, false, false, false, true, false])
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
    let oversized = try VideoFrame.parse(encodeTestFrames(width: 1922, height: 1080, keyframes: [0], count: 1)[0])
    precondition(oversized.keyframe && videoFormat(oversized) == nil)
    let key = frames[0], unit: [UInt8] = [0, 0, 0, 1, 0x41]
    let bad: [Data] = [
        Data([4]), Data([4, 0]), Data([1] + messages[1].dropFirst()), Data([4, 2] + messages[1].dropFirst(2)),
        Data(messages[0].dropLast()), Data(messages[1] + [0]), Data([4, 0, 0, 0, 0, 0, 0x41]), Data([4, 0, 0xff, 0xff, 0xff, 0xff, 0x41]),
        Data([4, 1, 0, 0] + messages[0].dropFirst(4)), Data([4, 1]) + key.avcc,
        VideoFrame(keyframe: true, parameterSets: key.parameterSets.reversed(), avcc: key.avcc).message,
        Data([4, 0] + Array(repeating: unit, count: 257).joined()),
    ]
    for (i, message) in bad.enumerated() where (try? VideoFrame.parse(message)) != nil { print("FAIL malformed video message \(i) accepted"); exit(1) }
    precondition((try? VideoFrame.parse(Data([4, 0] + Array(repeating: unit, count: 256).joined()))) != nil)
    print("PASS oversized H.264 dimensions and \(bad.count) malformed video messages rejected")
}
