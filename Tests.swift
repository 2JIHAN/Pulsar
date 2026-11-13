import Foundation
import Network
import Darwin
import Security
import CoreGraphics
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
        precondition(boundedImage(Data([1,2,3])) == nil)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1442, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let oversized = bitmap.representation(using: .jpeg, properties: [:])!
        precondition(boundedImage(oversized) == nil)
        let validBitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        precondition(boundedImage(validBitmap.representation(using: .jpeg, properties: [:])!) != nil)
        print("PASS JPEG metadata bounds before decoding")
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
                peer.send(Data([43]))
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
                p.onPacket = { data in
                    guard data == Data([43]) else { print("FAIL echo"); exit(1) }
                    print("PASS TLS1.2 ECDHE-PSK authenticated loopback payload")
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
