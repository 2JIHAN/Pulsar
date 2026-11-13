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
    func accept(_ c: NWConnection) {
        guard peers.filter({ $0 !== active }).count < 3 else { c.cancel(); return }
        let p = Peer(c); peers.append(p)
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
    func closeAll() { for p in peers { p.close() }; peers.removeAll(); active = nil }
}
// Holds the code while the user wants a connection, so any close the user did not ask for redials.
struct ViewerSession {
    enum Decision: Equatable { case idle, wrongCode, retry(attempt: Int), giveUp }
    static let retryDelay: TimeInterval = 2, retryWindow: TimeInterval = 120, silenceLimit: TimeInterval = 6
    private(set) var code: ConnectionCode?
    private(set) var generation = 0
    private(set) var attempts = 0
    private var live = false
    private var since: Date?
    mutating func start(_ c: ConnectionCode) { stop(); code = c }
    mutating func stop() { code = nil; generation += 1; attempts = 0; live = false; since = nil }
    mutating func connected() { live = true; attempts = 0; since = nil }
    mutating func closed(failure: NWError?, now: Date = Date()) -> Decision {
        guard code != nil else { return .idle }
        let wasLive = live; live = false
        // Only an attempt that never finished the handshake can be a PSK mismatch.
        if !wasLive, case .tls = failure { stop(); return .wrongCode }
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

// Message type 4: [4][flags: 1 = keyframe][keyframe only: UInt16 BE length + SPS, UInt16 BE length + PPS]
// [one access unit as AVCC NAL units, each prefixed by a UInt32 BE length].
struct VideoFrame: Equatable {
    var keyframe: Bool
    var parameterSets: [Data]
    var avcc: Data
    var message: Data {
        var data = Data([4, keyframe ? 1 : 0])
        for p in parameterSets { data += [UInt8(p.count >> 8), UInt8(p.count & 0xff)] + p }
        return data + avcc
    }
    static func parse(_ data: Data) throws -> VideoFrame {
        let b = [UInt8](data)
        guard b.count >= 7, b.count <= PacketParser.limit, b[0] == 4, b[1] <= 1 else { throw WireError.invalid }
        var i = 2
        var parameterSets = [Data]()
        if b[1] == 1 {
            for type: UInt8 in [7, 8] {
                guard i + 2 <= b.count else { throw WireError.invalid }
                let n = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
                guard n > 0, n <= 1024, n <= b.count - i, b[i] & 0x1f == type else { throw WireError.invalid }
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
        return VideoFrame(keyframe: b[1] == 1, parameterSets: parameterSets, avcc: Data(b[start...]))
    }
}
// Encoder output -> wire message. Returns nil for anything the viewer parser would reject.
func videoMessage(_ sample: CMSampleBuffer) -> Data? {
    guard let block = CMSampleBufferGetDataBuffer(sample), let format = CMSampleBufferGetFormatDescription(sample) else { return nil }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
    let keyframe = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
    var count = 0
    var headerLength: Int32 = 0
    guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength) == noErr, headerLength == 4 else { return nil }
    var parameterSets = [Data]()
    if keyframe {
        guard count == 2 else { return nil }
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let pointer else { return nil }
            parameterSets.append(Data(bytes: pointer, count: size))
        }
    }
    let length = CMBlockBufferGetDataLength(block)
    guard length > 0, length <= PacketParser.limit else { return nil }
    var avcc = Data(count: length)
    guard avcc.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }) == noErr else { return nil }
    let message = VideoFrame(keyframe: keyframe, parameterSets: parameterSets, avcc: avcc).message
    return (try? VideoFrame.parse(message)) == nil ? nil : message
}
// Validates dimensions from the SPS before anything is decoded.
func videoFormat(_ frame: VideoFrame) -> CMVideoFormatDescription? {
    guard frame.parameterSets.count == 2 else { return nil }
    let sps = frame.parameterSets[0], pps = frame.parameterSets[1]
    var format: CMFormatDescription?
    let status = sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
        CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!], parameterSetSizes: [sps.count, pps.count], nalUnitHeaderLength: 4, formatDescriptionOut: &format)
    } }
    guard status == noErr, let format else { return nil }
    let size = CMVideoFormatDescriptionGetDimensions(format)
    guard size.width >= 2, size.width <= 1920, size.height >= 2, size.height <= 1200 else { return nil }
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
