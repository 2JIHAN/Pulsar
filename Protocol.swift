import Foundation
import Network
import Security
import Darwin
import CoreGraphics
import CoreMedia
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
    static let limit = 8 * 1024 * 1024
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
    enum Kind: String, Codable { case move, down, up, scroll, keyDown, keyUp, flags, release, gesture }
    var kind: Kind
    var x: Double = 0
    var y: Double = 0
    var code: UInt16 = 0
    var flags: UInt64 = 0
    var dx: Double = 0
    var dy: Double = 0
    // Gesture only: the viewer's serialized CGEvent and the OS build that produced it.
    var data: Data? = nil
    var build: String? = nil
    static let gestureDataLimit = 64 * 1024
    var valid: Bool {
        guard x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) && dx.isFinite && dy.isFinite && abs(dx) <= 1000 && abs(dy) <= 1000 && code <= 255 else { return false }
        guard kind == .gesture else { return data == nil && build == nil }
        guard let data, let build else { return false }
        return !data.isEmpty && data.count <= Self.gestureDataLimit && !build.isEmpty && build.count <= 32
    }
}
let osBuild: String? = {
    var size = 0
    guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return nil }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return nil }
    return String(cString: bytes)
}()
// Ported from ThunderControl NativeGesture.swift. Classifies only; the original event bytes are replayed.
struct NativeGestureDescriptor: Equatable {
    enum Kind { case pinch, rotate, swipe, smartMagnify }
    enum Phase { case none, mayBegin, began, changed, ended, cancelled }
    let kind: Kind
    let phase: Phase
    var valid: Bool { kind == .smartMagnify ? phase == .none : (phase != .none || kind == .swipe) }
    static func decode(_ event: CGEvent) -> NativeGestureDescriptor? {
        guard event.type.rawValue == 29 || event.type.rawValue == 30, let native = NSEvent(cgEvent: event) else { return nil }
        let kind: Kind
        switch event.getIntegerValueField(CGEventField(rawValue: 110)!) {
        case 8:
            guard native.type == .magnify, native.magnification.isFinite, abs(native.magnification) <= 4 else { return nil }
            kind = .pinch
        case 5:
            guard native.type == .rotate, native.rotation.isFinite, abs(native.rotation) <= 360 else { return nil }
            kind = .rotate
        case 16:
            let direction = event.getIntegerValueField(CGEventField(rawValue: 115)!)
            guard native.type == .swipe, [Int64(1), 2, 4, 8].contains(direction), native.deltaX.isFinite, native.deltaY.isFinite,
                  abs(native.deltaX) <= 1, abs(native.deltaY) <= 1, native.deltaX != 0 || native.deltaY != 0 else { return nil }
            kind = .swipe
        case 22:
            guard native.type == .smartMagnify else { return nil }
            kind = .smartMagnify
        default: return nil
        }
        // Public NSEvent phase semantics, not IOHID numeric phases.
        let phase: Phase
        switch native.phase {
        case []: phase = .none
        case .mayBegin: phase = .mayBegin
        case .began: phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        default: return nil
        }
        let result = Self(kind: kind, phase: phase)
        return result.valid ? result : nil
    }
}
// CGEvent's serialized layout is private and can change between OS builds, so the bytes are
// only recreated when both Macs run the identical build.
func gestureEvent(_ m: InputMessage, hostBuild: String?, rect: CGRect) -> CGEvent? {
    guard m.kind == .gesture, m.valid, let data = m.data, m.build == hostBuild,
          let point = normalizedPoint(x: m.x, y: m.y, rect: rect),
          let event = CGEvent(withDataAllocator: nil, data: data as CFData),
          NativeGestureDescriptor.decode(event) != nil else { return nil }
    event.location = point
    return event
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
// Same-account Macs connect over Tailscale without TLS: WireGuard already encrypts and
// authenticates each node, and the host checks the source IP's owner with `tailscale whois`.
let tailnetPort: UInt16 = 47700
// The plain listener must only be reachable on the Tailscale interface, never on the LAN.
func tailnetBindAddress(_ ips: [String]) -> String? {
    ips.first { ip in
        let p = ip.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 100 && (64...127).contains(p[1])
    }
}
func plainListener(address: String, port: UInt16) throws -> NWListener {
    let p = NWParameters.tcp
    p.allowLocalEndpointReuse = true
    p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port) ?? .any)
    return try NWListener(using: p)
}
func whoisLogin(_ data: Data) -> String? {
    struct Profile: Decodable { var LoginName: String? }
    struct Whois: Decodable { var UserProfile: Profile? }
    guard let login = (try? JSONDecoder().decode(Whois.self, from: data))?.UserProfile?.LoginName, !login.isEmpty else { return nil }
    return login
}
// Fails closed: no whois answer, unparseable output or an unknown own login all reject.
func tailnetAllows(whois: Data?, selfLogin: String?) -> Bool {
    guard let whois, let selfLogin, !selfLogin.isEmpty, let login = whoisLogin(whois) else { return false }
    return login == selfLogin
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
    var pendingControl = 0
    // Plain TCP is "ready" as soon as a SYN completes, which a port probe also does, so both
    // ends exchange a hello first and only then count as ready.
    static let hello = Data("PULSAR1".utf8)
    let greet: Bool
    private(set) var connected = false
    init(_ connection: NWConnection, greet: Bool = false) { self.connection = connection; self.greet = greet }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.closed else { return }
            switch state {
            case .ready where self.greet:
                self.connected = true
                self.connection.send(content: PacketParser.frame(Self.hello), completion: .contentProcessed { [weak self] e in if e != nil { self?.close() } })
                self.receive()
            case .ready: self.connected = true; self.ready = true; self.onReady?(); self.receive()
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
                do {
                    for packet in try self.parser.feed(data) {
                        guard !self.closed else { return }
                        if !self.ready {
                            guard packet == Self.hello else { self.close(); return }
                            self.ready = true; self.onReady?(); continue
                        }
                        self.onPacket?(packet)
                    }
                }
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
    // Every encoded frame must arrive or the H.264 reference chain breaks, so frames are never
    // coalesced here. The host limits how many frames are in flight before encoding instead.
    func frame(_ data: Data, sent: @escaping () -> Void) {
        guard ready, !closed else { return }
        connection.send(content: PacketParser.frame(data), completion: .contentProcessed { [weak self] error in
            sent()
            if error != nil { self?.close() }
        })
    }
    func close() {
        guard !closed else { return }; closed = true; ready = false
        connection.cancel(); onClose?(); onClose = nil
    }
}
// Keeps one authenticated peer. A newly authenticated peer replaces the active one because a
// viewer reconnecting after a network stall arrives before the host notices the old socket died.
final class HostPeers {
    private(set) var peers = [Peer]()
    private(set) var active: Peer?
    var onActive: ((Peer) -> Void)?
    var onInactive: (() -> Void)?
    var onPacket: ((Peer, Data) -> Void)?
    private var authorizing = 0
    func accept(_ c: NWConnection, greet: Bool = false) {
        guard peers.filter({ $0 !== active }).count < 3 else { c.cancel(); return }
        let p = Peer(c, greet: greet); peers.append(p)
        p.onReady = { [weak self, weak p] in
            guard let self, let p else { return }
            self.active?.close()
            self.active = p
            self.onActive?(p)
        }
        p.onPacket = { [weak self, weak p] data in guard let self, let p, self.active === p else { return }; self.onPacket?(p, data) }
        p.onClose = { [weak self, weak p] in
            guard let self, let p else { return }
            self.peers.removeAll { $0 === p }
            if self.active === p { self.active = nil; self.onInactive?() }
        }
        p.start()
    }
    // `authorize` answers on the main queue whether the source IP belongs to this Mac's account.
    // Nothing is read from the connection until then.
    func acceptTailnet(_ c: NWConnection, authorize: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        guard authorizing < 3, case .hostPort(let host, _) = c.endpoint else { c.cancel(); return }
        authorizing += 1
        let ip = "\(host)".split(separator: "%").first.map(String.init) ?? ""
        authorize(ip) { [weak self] ok in
            guard let self else { c.cancel(); return }
            self.authorizing -= 1
            if ok { self.accept(c, greet: true) } else { c.cancel() }
        }
    }
    func closeAll() { for p in peers { p.close() }; peers.removeAll(); active = nil }
}
// A connection code dials with its TLS key; a same-account Tailscale Mac dials plain TCP (secret nil).
struct DialTarget: Equatable {
    let host: String
    let port: UInt16
    let secret: Data?
    init(_ c: ConnectionCode) { host = c.host; port = c.port; secret = c.secret }
    init(tailnet host: String) { self.host = host; port = tailnetPort; secret = nil }
}
// Holds the target while the user wants a connection, so any close the user did not ask for redials.
struct ViewerSession {
    enum Decision: Equatable { case idle, wrongCode, refused, retry(attempt: Int), giveUp }
    static let retryDelay: TimeInterval = 2, retryWindow: TimeInterval = 120, silenceLimit: TimeInterval = 6, refusalLimit = 3
    private(set) var target: DialTarget?
    private(set) var generation = 0
    private(set) var attempts = 0
    private var refusals = 0
    private var live = false
    private var since: Date?
    mutating func start(_ t: DialTarget) { stop(); target = t }
    mutating func stop() { target = nil; generation += 1; attempts = 0; refusals = 0; live = false; since = nil }
    mutating func connected() { live = true; attempts = 0; refusals = 0; since = nil }
    // `refused`: TCP connected but the host closed before its hello, which is what a whois rejection looks like.
    mutating func closed(failure: NWError?, refused: Bool = false, now: Date = Date()) -> Decision {
        guard target != nil else { return .idle }
        let wasLive = live; live = false
        // Only an attempt that never finished the handshake can be a PSK mismatch.
        if !wasLive, case .tls = failure { stop(); return .wrongCode }
        if !wasLive && refused {
            refusals += 1
            if refusals >= Self.refusalLimit { stop(); return .refused }
        } else { refusals = 0 }
        let start = since ?? now; since = start
        guard now.timeIntervalSince(start) < Self.retryWindow else { stop(); return .giveUp }
        attempts += 1
        return .retry(attempt: attempts)
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

enum CodecPreference: String, Codable, CaseIterable {
    case auto, h264, hevc
}
enum ResolvedCodec: String, Codable, CaseIterable {
    case h264, hevc
    var label: String { self == .hevc ? "HEVC" : "H.264" }
}
enum ChromaOption: String, Codable, CaseIterable {
    case yuv420 = "420"
    case yuv444 = "444"
}
enum BitrateOption: Int, Codable, CaseIterable {
    case auto = 0
    case mbps5 = 5
    case mbps10 = 10
    case mbps20 = 20
    case mbps35 = 35
    case mbps50 = 50
    var mbps: Int { self == .auto ? 8 : rawValue }
    static let allowedMbps = Set([5, 8, 10, 20, 35, 50])
}
enum MaxResolutionOption: String, Codable, CaseIterable {
    case p1080 = "1080p"
    case p1440 = "1440p"
    case native = "native"
    var label: String {
        switch self {
        case .p1080: return "1080p"
        case .p1440: return "1440p"
        case .native: return "원본"
        }
    }
    var maxBounds: (width: Double, height: Double) {
        switch self {
        case .p1080: return (1920, 1080)
        case .p1440: return (2560, 1440)
        case .native: return (3840, 2400)
        }
    }
    func scaledSize(displayWidth: Double, displayHeight: Double) -> (width: Int, height: Int) {
        Self.scaledSize(displayWidth: displayWidth, displayHeight: displayHeight, bounds: maxBounds)
    }
    static func scaledSize(displayWidth: Double, displayHeight: Double, bounds: (width: Double, height: Double)) -> (width: Int, height: Int) {
        let w = max(2, displayWidth), h = max(2, displayHeight)
        let scale = min(1, min(bounds.width / w, bounds.height / h))
        return (max(2, Int(w * scale) / 2 * 2), max(2, Int(h * scale) / 2 * 2))
    }
}
enum FPSOption: Int, Codable, CaseIterable {
    case fps30 = 30
    case fps60 = 60
}

struct StreamQualityPreferences: Equatable {
    var codec: CodecPreference = .auto
    var chroma: ChromaOption = .yuv420
    var bitrate: BitrateOption = .auto
    var maxResolution: MaxResolutionOption = .p1080
    var fps: FPSOption = .fps30

    private static let codecKey = "quality.codec"
    private static let chromaKey = "quality.chroma"
    private static let bitrateKey = "quality.bitrate"
    private static let resolutionKey = "quality.maxResolution"
    private static let fpsKey = "quality.fps"

    static func load(_ d: UserDefaults = .standard) -> StreamQualityPreferences {
        var p = StreamQualityPreferences()
        if let raw = d.string(forKey: codecKey), let v = CodecPreference(rawValue: raw) { p.codec = v }
        if let raw = d.string(forKey: chromaKey), let v = ChromaOption(rawValue: raw) { p.chroma = v }
        if d.object(forKey: bitrateKey) != nil, let v = BitrateOption(rawValue: d.integer(forKey: bitrateKey)) { p.bitrate = v }
        if let raw = d.string(forKey: resolutionKey), let v = MaxResolutionOption(rawValue: raw) { p.maxResolution = v }
        if d.object(forKey: fpsKey) != nil, let v = FPSOption(rawValue: d.integer(forKey: fpsKey)) { p.fps = v }
        return p
    }
    func save(_ d: UserDefaults = .standard) {
        d.set(codec.rawValue, forKey: Self.codecKey)
        d.set(chroma.rawValue, forKey: Self.chromaKey)
        d.set(bitrate.rawValue, forKey: Self.bitrateKey)
        d.set(maxResolution.rawValue, forKey: Self.resolutionKey)
        d.set(fps.rawValue, forKey: Self.fpsKey)
    }
    func request(hevcDecode: Bool) -> QualityRequest {
        QualityRequest(codec: codec, chroma: codec == .h264 ? .yuv420 : chroma, bitrate: bitrate, maxResolution: maxResolution, fps: fps, hevcDecode: hevcDecode)
    }
}

struct QualityRequest: Codable, Equatable {
    static let messageType: UInt8 = 5
    static let maxWireBytes = 512
    var codec: CodecPreference
    var chroma: ChromaOption
    var bitrate: BitrateOption
    var maxResolution: MaxResolutionOption
    var fps: FPSOption
    var hevcDecode: Bool

    func wireMessage() -> Data {
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        return Data([Self.messageType]) + json
    }
    static func decodeWire(_ data: Data) -> QualityRequest? {
        guard data.first == messageType, data.count > 1, data.count <= maxWireBytes else { return nil }
        return try? JSONDecoder().decode(QualityRequest.self, from: data.dropFirst())
    }
}

struct EffectiveQuality: Codable, Equatable {
    static let messageType: UInt8 = 6
    static let maxWireBytes = 512
    var codec: ResolvedCodec
    var chroma: ChromaOption
    var bitrateMbps: Int
    var maxResolution: MaxResolutionOption
    var fps: FPSOption

    static let legacyDefaults = EffectiveQuality(codec: .h264, chroma: .yuv420, bitrateMbps: 8, maxResolution: .p1080, fps: .fps30)

    var summary: String {
        let codecPart = chroma == .yuv444 ? "\(codec.label) 4:4:4" : codec.label
        return "\(codecPart) · \(maxResolution.label) · \(fps.rawValue)fps · \(bitrateMbps)Mbps"
    }

    static func resolve(_ req: QualityRequest, hostHEVCEncode: Bool, hostHEVC444Encode: Bool = true) -> EffectiveQuality {
        let canHEVC = hostHEVCEncode && req.hevcDecode
        let resolvedCodec: ResolvedCodec = (req.codec != .h264 && canHEVC) ? .hevc : .h264
        let resolvedChroma: ChromaOption = (resolvedCodec == .hevc && req.chroma == .yuv444 && hostHEVC444Encode) ? .yuv444 : .yuv420
        let mbps = BitrateOption.allowedMbps.contains(req.bitrate.mbps) ? req.bitrate.mbps : 8
        return EffectiveQuality(codec: resolvedCodec, chroma: resolvedChroma, bitrateMbps: mbps, maxResolution: req.maxResolution, fps: req.fps)
    }

    func wireMessage() -> Data {
        let json = (try? JSONEncoder().encode(self)) ?? Data()
        return Data([Self.messageType]) + json
    }
    static func decodeWire(_ data: Data) -> EffectiveQuality? {
        guard data.first == messageType, data.count > 1, data.count <= maxWireBytes,
              let q = try? JSONDecoder().decode(EffectiveQuality.self, from: data.dropFirst()),
              BitrateOption.allowedMbps.contains(q.bitrateMbps),
              !(q.codec == .h264 && q.chroma == .yuv444) else { return nil }
        return q
    }
}

// Message type 4: [4][flags: bit 0 = keyframe, bit 1 = HEVC][keyframe only: UInt16 BE length + parameter sets (H.264: SPS,PPS; HEVC: VPS,SPS,PPS)]
// [one access unit as AVCC/HVCC NAL units, each prefixed by a UInt32 BE length].
struct VideoFrame: Equatable {
    var codec: ResolvedCodec = .h264
    var keyframe: Bool
    var parameterSets: [Data]
    var avcc: Data
    var message: Data {
        let flags: UInt8 = (keyframe ? 1 : 0) | (codec == .hevc ? 2 : 0)
        var data = Data([4, flags])
        for p in parameterSets { data += [UInt8(p.count >> 8), UInt8(p.count & 0xff)] + p }
        return data + avcc
    }
    static func parse(_ data: Data) throws -> VideoFrame {
        let b = [UInt8](data)
        guard b.count >= 7, b.count <= PacketParser.limit, b[0] == 4, b[1] <= 3 else { throw WireError.invalid }
        let keyframe = (b[1] & 1) != 0
        let codec: ResolvedCodec = (b[1] & 2) != 0 ? .hevc : .h264
        var i = 2
        var parameterSets = [Data]()
        if keyframe {
            let expectedTypes: [UInt8] = codec == .hevc ? [32, 33, 34] : [7, 8]
            for type in expectedTypes {
                guard i + 2 <= b.count else { throw WireError.invalid }
                let n = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
                let minLen = codec == .hevc ? 2 : 1
                guard n >= minLen, n <= 1024, n <= b.count - i else { throw WireError.invalid }
                let nalType = codec == .hevc ? (b[i] >> 1) & 0x3f : b[i] & 0x1f
                guard nalType == type else { throw WireError.invalid }
                parameterSets.append(Data(b[i..<i + n])); i += n
            }
        }
        let start = i
        var units = 0
        guard i < b.count else { throw WireError.invalid }
        while i < b.count {
            guard i + 4 <= b.count else { throw WireError.invalid }
            let n = b[i..<i + 4].reduce(0) { ($0 << 8) | Int($1) }; i += 4
            units += 1
            guard n > 0, n <= b.count - i, units <= 256 else { throw WireError.invalid }
            i += n
        }
        return VideoFrame(codec: codec, keyframe: keyframe, parameterSets: parameterSets, avcc: Data(b[start...]))
    }
}
// Encoder output -> wire message. Returns nil for anything the viewer parser would reject.
func videoMessage(_ sample: CMSampleBuffer, codec: ResolvedCodec = .h264) -> Data? {
    guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
    let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
    var count = 0
    var headerLength: Int32 = 0
    let expectedCount = codec == .hevc ? 3 : 2
    let metaStatus: OSStatus = codec == .hevc
        ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
        : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
    guard metaStatus == noErr, headerLength == 4 else { return nil }
    var parameterSets = [Data]()
    if keyframe {
        guard count == expectedCount else { return nil }
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let s: OSStatus = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard s == noErr, let pointer else { return nil }
            parameterSets.append(Data(bytes: pointer, count: size))
        }
    }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0, length <= PacketParser.limit else { return nil }
    var avcc = Data(count: length)
    guard avcc.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }) == noErr else { return nil }
    let message = VideoFrame(codec: codec, keyframe: keyframe, parameterSets: parameterSets, avcc: avcc).message
    return (try? VideoFrame.parse(message)) == nil ? nil : message
}
// Validates dimensions from the SPS before anything is decoded.
func videoFormat(_ frame: VideoFrame) -> CMVideoFormatDescription? {
    var format: CMFormatDescription?
    let status: OSStatus
    switch frame.codec {
    case .h264:
        guard frame.parameterSets.count == 2 else { return nil }
        let sps = frame.parameterSets[0], pps = frame.parameterSets[1]
        status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!], parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
        } }
    case .hevc:
        guard frame.parameterSets.count == 3 else { return nil }
        let vps = frame.parameterSets[0], sps = frame.parameterSets[1], pps = frame.parameterSets[2]
        status = vps.withUnsafeBytes { v in sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3, parameterSetPointers: [v.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!], parameterSetSizes: [vps.count, sps.count, pps.count], nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &format)
        } } }
    }
    guard status == noErr, let format else { return nil }
    let size = CMVideoFormatDescriptionGetDimensions(format)
    guard size.width >= 2, size.width <= 3840, size.height >= 2, size.height <= 2400 else { return nil }
    return format
}
func videoSample(_ frame: VideoFrame, format: CMVideoFormatDescription) -> CMSampleBuffer? {
    var size = frame.avcc.count
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block,
          frame.avcc.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) }) == noErr else { return nil }
    var sample: CMSampleBuffer?
    guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample,
          let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) else { return nil }
    let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
    CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    if !frame.keyframe { CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()) }
    return sample
}
