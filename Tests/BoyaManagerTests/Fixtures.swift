@testable import BoyaManager
import Foundation

/// Bytes captured from a real BOYA mini 2 receiver, not bytes a test author
/// invented. Every codec test checks against these, so a "fix" that changes the
/// wire format fails loudly instead of quietly agreeing with itself.
///
/// The iAP2 packets came off the app's own `USB` debug log during a `--probe`
/// run; the `get nc` exchange is the one printed in `docs/PROTOCOL.md` §9.1.
enum Fixtures {
    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex, let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) {
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    // MARK: - iAP2 link

    static let detect = bytes("ff550200ee10")

    /// The receiver's SYN: link version 1, max 5 outstanding, 1024-byte packets,
    /// 5000 ms retransmit, sessions 1 (control, type 0) and 2 (EA, type 2).
    static let receiverSYN = bytes("ff5a001a80011000fc01050400138800ff1e0301000102020134")
    static let receiverSYNPayload = bytes("01050400138800ff1e03010001020201")

    /// Our SYN|ACK, seq 0x40, echoing the accessory's parameters verbatim.
    static let hostSYNAck = bytes("ff5a001ac04001008c01050400138800ff1e0301000102020134")

    /// The accessory's bare ACK of that SYN|ACK.
    static let receiverAck = bytes("ff5a0009400140001d")

    /// `StartIdentification` on the wire, seq 0x41, ack 0x01.
    static let startIdentification = bytes("ff5a00104041010114404000061d005d")

    /// `IdentificationInformation` — 240 bytes of control message. Decodes to
    /// name `Microphone`, model `BOYA mini 2`, serial `CFD7387E79`, firmware
    /// `1.1.0`, EA protocol 177 `BOYA.DeviceLink.com`.
    static let identificationInformation = bytes(
        "404000f01d01000f00004d6963726f70686f6e650000100001424f5941206d696e69203200002800025368656e7a6865" +
        "6e206a6961797a2070686f746f20696e647573747269616c206c746400000f0003434644373338374537390000150022" +
        "3235393634623264333865393465656500000a0004312e312e3000000a0005312e312e3000000a0006ae00ae02ae0300" +
        "0a0007ae01ea00ea0100050008020006000900640026000a00050000b100180001424f59412e4465766963654c696e6b" +
        "2e636f6d0000050002000007000c656e000007000d656e0000180010000600000001000a000169415032480000040002"
    )

    /// `StartExternalAccessoryProtocolSession` for protocol 177, session 1.
    static let startExternalAccessorySession = bytes("ff5a001b404304010440400011ea0000050000b1000600010001c7")

    /// `StatusExternalAccessoryProtocolSession`: session 1, status 0 (open).
    static let externalAccessoryStatusOpen = bytes("40400011ea030006000000010005000100")

    // MARK: - CFD-Link

    /// A device heartbeat, broadcast node, `src = 1`.
    static let deviceHeartbeat = bytes("55120d00285101021d0000000000000000a80000010ada0943010000240b")

    /// A node handle the host never sends to of its own accord, so a frame
    /// carrying it can only have come back from a reply. The real receiver
    /// beats from no fixed handle — `(0,0,0)` and `(2,1,29)` on consecutive
    /// connections — and the broadcast one is indistinguishable from the host's
    /// own beats, so neither is usable here.
    static let heartbeatingNode = CFDNode(chid: 2, vid: 2, pid: 30)

    /// The captured heartbeat, re-addressed from `heartbeatingNode`. A reply to
    /// it carries that handle back, which is the only thing that tells a reply
    /// from the host's own broadcast beat — `src`/`dst` are 2 → 1 for both.
    static let nodeHeartbeat = CFDLink.encode(
        message: .heartbeat,
        seq: 0x5128,
        payload: Array(deviceHeartbeat[CFDLink.headerLength..<(deviceHeartbeat.count - 1)]),
        node: heartbeatingNode,
        src: CFDLink.deviceNode,
        dst: CFDLink.hostNode
    )

    /// Our own heartbeat handed straight back by the router — same `src = 2`,
    /// payload lightly rewritten. Answering these is the ping-pong loop.
    static let echoedHostHeartbeat = bytes("55120d00000002021e0000000000000004a80000010ada09430100002498")

    /// `get nc` (attribute 47) to node (1,2,29), seq 13 — docs §9.1.
    static let getNoiseCancellationRequest = bytes("551001000d0002011d0001021d001f002f01")
    /// Its reply: status 0, attribute 47, one byte, value 2.
    static let getNoiseCancellationReply = bytes("551104000d0001021d0002011d001f00002f010208")

    /// A real `get_all` reply: 127 bytes, 24 attributes, from node (2,1,29).
    static let getAllReply = bytes(
        "55116e00170001021d0002011d002100000101000201000401000701001501031601001801041b01012901002a060000" +
        "000000002c01012d01012f01023001003d01043e01023f01004001014101044301014401004501014701004a21000000" +
        "000000000000000000000000000000000000000000000000000000000000b1"
    )

    /// The request that produced it: `get_many` with count 0, seq 23.
    static let getAllRequest = bytes("55100100170002011d0001021d00210000de")

    /// What `getAllReply` decodes to — the dump in `docs/PROTOCOL.md` §9.8.
    /// All 24 attributes a mini 2 answers for.
    static let getAllExpected: [UInt8: [UInt8]] = [
        1: [0], 2: [0], 4: [0], 7: [0],
        21: [3], 22: [0], 24: [4], 27: [1],
        41: [0], 42: [0, 0, 0, 0, 0, 0], 44: [1], 45: [1], 47: [2], 48: [0],
        61: [4], 62: [2], 63: [0], 64: [1], 65: [4], 67: [1], 68: [0], 69: [1], 71: [0],
        74: [UInt8](repeating: 0, count: 33),
    ]
}
