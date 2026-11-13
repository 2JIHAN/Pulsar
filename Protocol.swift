import Foundation
import Network
import Security
import Darwin
import CoreGraphics
import ImageIO
import AppKit

enum WireError: Error { case invalid }
struct ConnectionCode: Codable {
    let host: String
    let port: UInt16
    let token: String
    var secret: Data { Data(stride(from: 0, to: token.count, by: 2).map { i in UInt8(token.dropFirst(i).prefix(2), radix: 16)! }) }
    var text: String { "remotecontrol1:" + (try! JSONEncoder().encode(self)).base64EncodedString() }
    static func parse(_ text: String) throws -> ConnectionCode {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count < 2048, text.hasPrefix("remotecontrol1:"),
              let data = Data(base64Encoded: String(text.dropFirst(15))),
              let c = try? JSONDecoder().decode(Self.self, from: data),
              c.port > 0, !c.host.isEmpty, c.host.count <= 255,
              c.host.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.:-_%").contains($0) }),
              c.token.count == 64, c.token.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw WireError.invalid }
        return c
    }
    static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WireError.invalid }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
struct PacketParser {
    static let limit = 4 * 1024 * 1024
    var buffer = Data()
    mutating func feed(_ bytes: Data) throws -> [Data] {
        guard buffer.count + bytes.count <= Self.limit + 65540 else { throw WireError.invalid }
        buffer.append(bytes)
        var packets = [Data]()
        while buffer.count >= 4 {
            let n = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard n > 0, n <= Self.limit else { throw WireError.invalid }
            guard buffer.count >= n + 4 else { break }
            packets.append(Data(buffer.dropFirst(4).prefix(n)))
            buffer.removeFirst(n + 4)
        }
        return packets
    }
    static func frame(_ data: Data) -> Data {
        precondition(!data.isEmpty && data.count <= limit)
        var n = UInt32(data.count).bigEndian
        return withUnsafeBytes(of: &n) { Data($0) } + data
    }
}
struct InputMessage: Codable {
    enum Kind: String, Codable { case move, down, up, scroll, keyDown, keyUp, flags, release }
    var kind: Kind
    var x: Double = 0
    var y: Double = 0
    var code: UInt16 = 0
    var flags: UInt64 = 0
    var dx: Double = 0
    var dy: Double = 0
    var valid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) && dx.isFinite && dy.isFinite && abs(dx) <= 1000 && abs(dy) <= 1000 && code <= 255 }
}
func normalizedPoint(x: Double, y: Double, rect: CGRect) -> CGPoint? {
    guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y), rect.width > 0, rect.height > 0 else { return nil }
    return CGPoint(x: rect.minX + x * max(0, rect.width - 1), y: rect.minY + y * max(0, rect.height - 1))
}
func tlsParameters(secret: Data) -> NWParameters {
    let tls = NWProtocolTLS.Options()
    let options = tls.securityProtocolOptions
    sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
    sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0xCCAC)!)
    let key = secret.withUnsafeBytes { DispatchData(bytes: $0) }
    let identity = Data("RemoteControl-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
    sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
    sec_protocol_options_set_tls_tickets_enabled(options, false)
    let p = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    p.allowLocalEndpointReuse = true
    return p
}
final class Peer {
    let connection: NWConnection
    var onPacket: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onClose: (() -> Void)?
    var parser = PacketParser()
    var failure: NWError?
    var ready = false
    var closed = false
    var lastReceive = Date()
    var sendingFrame = false
    var latestFrame: Data?
    var pendingControl = 0
    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.closed else { return }
            switch state {
            case .ready: self.ready = true; self.onReady?(); self.receive()
            case .failed(let error): self.failure = error; self.close()
            case .cancelled: self.close()
            case .waiting(let error): if case .tls = error { self.failure = error; self.close() }
            default: break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in if let self = self, !self.ready { self.close() } }
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self = self, !self.closed else { return }
            if let data = data, !data.isEmpty {
                self.lastReceive = Date()
                do { for packet in try self.parser.feed(data) { guard !self.closed else { return }; self.onPacket?(packet) } }
                catch { self.close(); return }
            }
            if complete || error != nil { if let error = error { self.failure = error }; self.close() } else { self.receive() }
        }
    }
    func send(_ data: Data) {
        guard ready, !closed else { return }
        guard pendingControl < 64 else { close(); return }
        pendingControl += 1
        connection.send(content: PacketParser.frame(data), completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }; self.pendingControl -= 1
            if error != nil { self.close() }
        })
    }
    func frame(_ data: Data) {
        guard ready, !closed else { return }
        if sendingFrame { latestFrame = data; return }
        sendingFrame = true
        connection.send(content: PacketParser.frame(data), completion: .contentProcessed { [weak self] error in
            guard let self = self, !self.closed else { return }
            self.sendingFrame = false
            if error != nil { self.close(); return }
            if let next = self.latestFrame { self.latestFrame = nil; self.frame(next) }
        })
    }
    func close() {
        guard !closed else { return }; closed = true; ready = false; latestFrame = nil
        connection.cancel(); onClose?(); onClose = nil
    }
}
func localAddresses() -> [(String, String)] {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return [] }
    defer { freeifaddrs(list) }
    var result = [(String, String)]()
    var node = list
    while let p = node {
        defer { node = p.pointee.ifa_next }
        guard let a = p.pointee.ifa_addr, a.pointee.sa_family == UInt8(AF_INET), (p.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(a, socklen_t(a.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            let first = ip.split(separator: ".").prefix(2).compactMap { Int($0) }
            let tail = first.count == 2 && first[0] == 100 && (64...127).contains(first[1])
            result.append((tail ? "Tailscale \(ip)" : "LAN \(ip)", ip))
        }
    }
    return result
}

func boundedImage(_ data: Data) -> NSImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
          CGImageSourceGetCount(source) == 1,
          CGImageSourceGetType(source) as String? == "public.jpeg",
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int,
          width > 0, width <= 1440, height > 0, height <= 900,
          let image = NSImage(data: data) else { return nil }
    image.size = NSSize(width: width, height: height)
    return image
}
