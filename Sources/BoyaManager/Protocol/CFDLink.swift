import Foundation

/// The receiver's own protocol, "CFD-Link" — a small routed bus that carries
/// every setting on the device. Frames are identical whether they travel on the
/// vendor HID interface (what the Android app does) or inside an iAP2 External
/// Accessory session (what we do); only the envelope differs.
///
/// Wire format, little-endian throughout:
///
///     0      0x55                sync
///     1      0x10 | flags        high nibble = version 1, low nibble = fragment flags
///     2..4   u16 payload length  max 0x480
///     4..6   u16 seq
///     6      src node            host = 2 (anything but 1)
///     7      dst node            device = 1
///     8..10  u16 service         0x001D; the device ignores this field
///     10     chid                ┐
///     11     vid                 ├ node handle — which logical device on the bus
///     12..14 u16 pid             ┘
///     14..16 u16 message id
///     16..   payload
///     last   checksum = sum of every preceding byte & 0xFF
///
/// See `docs/PROTOCOL.md` §4. Everything here is a pure function on bytes.
enum CFDLink {
    static let sync: UInt8 = 0x55
    static let version: UInt8 = 0x10
    /// The host's link address. Frames with `src == 1` are the device's own and
    /// are dropped by the receiver, so never use it.
    static let hostNode: UInt8 = 2
    /// The receiver's link address.
    static let deviceNode: UInt8 = 1
    /// What `cfdl_res_send` stamps into every outgoing frame. The device does not
    /// check it, but replies always carry it.
    static let service: UInt16 = 0x001D
    /// Heartbeats have been observed from the device with either of these.
    static let heartbeatServices: Set<UInt16> = [0x001D, 0x001E]
    static let headerLength = 16
    static let maxPayloadLength = 0x480

    /// Builds a frame, checksum included.
    static func encode(
        message: CFDMessage,
        payload: [UInt8] = [],
        node: CFDNode = .broadcast,
        seq: UInt16,
        src: UInt8 = hostNode,
        dst: UInt8 = deviceNode,
        service: UInt16 = CFDLink.service,
        flags: UInt8 = 0
    ) -> [UInt8] {
        var frame: [UInt8] = [sync, version | flags]
        frame.append(littleEndian: UInt16(payload.count))
        frame.append(littleEndian: seq)
        frame.append(src)
        frame.append(dst)
        frame.append(littleEndian: service)
        frame.append(node.chid)
        frame.append(node.vid)
        frame.append(littleEndian: node.pid)
        frame.append(littleEndian: message.rawValue)
        frame.append(contentsOf: payload)
        frame.append(checksum(frame))
        return frame
    }

    /// Plain 8-bit sum of every byte handed in, sync byte included.
    static func checksum(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(into: UInt8(0)) { $0 = $0 &+ $1 }
    }

    /// The 13-byte heartbeat payload the Android SDK sends. `tick` is the host's
    /// uptime in milliseconds; the device does not appear to read it, but it
    /// changes every beat in every capture, so we send a real one.
    static func heartbeatPayload(tick: UInt32) -> [UInt8] {
        var payload: [UInt8] = [0x00]
        payload.append(littleEndian: UInt32(0x0100_0400))
        payload.append(0x09)
        payload.append(littleEndian: tick)
        payload.append(littleEndian: UInt16(0))
        payload.append(0x24)
        return payload
    }
}

/// `msg_id` at offset 14. The mini 2 uses the BOYA-specific attribute messages
/// (`0x1E`…`0x21`); the SDK's generic attribute layer (`0x05`/`0x09`) is unused
/// by this device.
enum CFDMessage: UInt16, Sendable {
    case heartbeat = 0x00
    /// Ask a node to describe itself — reply carries the capability bitmask.
    case describe = 0x15
    /// `[attrId, len, value…]`
    case setAttribute = 0x1E
    /// `[attrId]`
    case getAttribute = 0x1F
    case setMany = 0x20
    /// `[count, attrId…]`; count 0 means everything.
    case getMany = 0x21
}

/// A node handle — which logical device on the CFD bus a frame is addressed to.
/// These ids are BOYA's own and have nothing to do with USB vendor/product ids.
struct CFDNode: Hashable, Sendable {
    var chid: UInt8
    var vid: UInt8
    var pid: UInt16

    static let broadcast = CFDNode(chid: 0, vid: 0, pid: 0)
    /// The only node on a mini 2 that holds settings. It never heartbeats: the
    /// receiver's own beats carry the broadcast handle `(0,0,0)`, so a reply is
    /// told from a beat by the handle it is addressed to, not by src and dst.
    static let settings = CFDNode(chid: 1, vid: 2, pid: 29)
}

struct CFDFrame: Sendable, Equatable {
    var flags: UInt8
    var seq: UInt16
    var src: UInt8
    var dst: UInt8
    var service: UInt16
    var node: CFDNode
    var message: UInt16
    var payload: [UInt8]

    /// Parses one complete frame and verifies its checksum. Returns nil for
    /// anything that isn't a well-formed, intact frame.
    init?(parsing bytes: [UInt8]) {
        guard bytes.count >= CFDLink.headerLength + 1,
              bytes[0] == CFDLink.sync,
              bytes[1] & 0xF0 == CFDLink.version
        else { return nil }
        let length = Int(UInt16(littleEndianAt: bytes, 2))
        guard bytes.count == CFDLink.headerLength + length + 1,
              CFDLink.checksum(Array(bytes.dropLast())) == bytes[bytes.count - 1]
        else { return nil }

        flags = bytes[1] & 0x0F
        seq = UInt16(littleEndianAt: bytes, 4)
        src = bytes[6]
        dst = bytes[7]
        service = UInt16(littleEndianAt: bytes, 8)
        node = CFDNode(chid: bytes[10], vid: bytes[11], pid: UInt16(littleEndianAt: bytes, 12))
        message = UInt16(littleEndianAt: bytes, 14)
        payload = Array(bytes[16..<(16 + length)])
    }

    var isHeartbeat: Bool {
        message == CFDMessage.heartbeat.rawValue && CFDLink.heartbeatServices.contains(service)
    }
}

/// A frame is not a USB packet: endpoints carry 64 bytes and a full attribute
/// dump is ~130, so it simply continues into the next packet. Frames shorter
/// than a packet are zero-padded. Rebuild frames from the byte stream the way
/// `cfdl_io_in()` does — treating one packet as one frame truncates `get_all`
/// at 14 attributes.
struct CFDReassembler: Sendable {
    private var buffer: [UInt8] = []

    init() {}

    /// Feeds one chunk of received bytes and returns whatever complete,
    /// checksum-valid frames that completed.
    mutating func feed(_ chunk: [UInt8]) -> [CFDFrame] {
        buffer.append(contentsOf: chunk)
        var frames: [CFDFrame] = []
        while true {
            // Resync on the 0x55 / 0x1X header; inter-frame padding is zeros.
            var start = 0
            while start + 1 < buffer.count,
                  !(buffer[start] == CFDLink.sync && buffer[start + 1] & 0xF0 == CFDLink.version) {
                start += 1
            }
            if start > 0 { buffer.removeFirst(start) }
            guard buffer.count >= CFDLink.headerLength + 1 else { break }

            let length = Int(UInt16(littleEndianAt: buffer, 2))
            guard length <= CFDLink.maxPayloadLength else {
                buffer.removeFirst()
                continue
            }
            let total = CFDLink.headerLength + length + 1
            guard buffer.count >= total else { break }

            let candidate = Array(buffer[0..<total])
            buffer.removeFirst(total)
            if let frame = CFDFrame(parsing: candidate) {
                frames.append(frame)
            }
        }
        return frames
    }
}

// MARK: - little-endian helpers

extension Array where Element == UInt8 {
    fileprivate mutating func append(littleEndian value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    fileprivate mutating func append(littleEndian value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }
}

extension UInt16 {
    fileprivate init(littleEndianAt bytes: [UInt8], _ offset: Int) {
        self = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
}
