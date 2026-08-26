import Foundation
@testable import BoyaManager

/// A scripted BOYA mini 2: the accessory half of iAP2, plus the little CFD-Link
/// router that lives behind its External Accessory session. It replays the
/// captured bytes and reacts the way the real receiver does, so everything
/// above `ByteTransport` — link layer, session state machine, attribute codec —
/// is exercised end to end without hardware.
actor FakeAccessory: ByteTransport {
    struct Options: Sendable {
        /// Never send a SYN, so the link times out.
        var silent = false
        /// Deliver the SYN as `ff5a001a8001` followed by the whole packet, the
        /// way a split bulk transfer arrives.
        var splitFirstSYN = false
        /// Swallow the acknowledgement of the host's first data packet, forcing
        /// a retransmission.
        var dropFirstDataAck = false
        /// Deliver `IdentificationInformation` twice with the same sequence
        /// number, the way a retransmission arrives.
        var duplicateIdentification = false
        /// Reset the link once identification is done.
        var resetAfterIdentification = false
        /// Status reported for `StartExternalAccessoryProtocolSession`.
        var sessionStatus: UInt8 = 0
        /// Answer CFD requests. Off makes every request time out.
        var answersRequests = true
        /// Hand the host's own frames back with `src` unchanged, the way the
        /// real router does.
        var echoesHostFrames = false
        /// Send a device heartbeat whenever the host sends one.
        var heartbeatsBack = true
    }

    private let options: Options
    private var stream: AsyncStream<[UInt8]>?
    private var continuation: AsyncStream<[UInt8]>.Continuation?
    private var parser = LinkParser()
    private var reassembler = CFDReassembler()

    private var accessorySeq: UInt8 = 0
    private var hostSeq: UInt8 = 0
    private var sentSYN = false
    private var droppedAnAck = false
    private var acknowledgesData = true
    private var isClosed = false

    /// Everything the host wrote, as parsed link packets — the transcript the
    /// no-SYN invariant is asserted over.
    private(set) var hostPackets: [LinkPacket] = []
    private(set) var hostRawWrites: [[UInt8]] = []
    private(set) var hostFrames: [CFDFrame] = []
    private(set) var controlMessagesReceived: [UInt16] = []
    private(set) var stopSessionCount = 0
    private(set) var attributes: [UInt8: UInt8] = [
        Attr.noiseCancellation.rawValue: 2,
        Attr.rxGain.rawValue: 4,
        Attr.sceneMode.rawValue: 0,
        Attr.recordingMode.rawValue: 0,
        Attr.mute.rawValue: 0,
    ]

    init(options: Options = Options()) {
        self.options = options
    }

    // MARK: - ByteTransport

    func inbound() -> AsyncStream<[UInt8]> {
        if let stream { return stream }
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.stream = stream
        self.continuation = continuation
        return stream
    }

    func write(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw Failure.closed }
        hostRawWrites.append(bytes)
        for item in parser.feed(bytes) {
            switch item {
            case .detect:
                sendSYN()
            case .packet(let packet):
                hostPackets.append(packet)
                handle(packet)
            case .junk:
                break
            }
        }
    }

    func close() {
        isClosed = true
        continuation?.finish()
    }

    enum Failure: Error { case closed }

    // MARK: - accessory behaviour

    private func sendSYN() {
        guard !sentSYN, !options.silent else { return }
        sentSYN = true
        accessorySeq = 0x01
        if options.splitFirstSYN {
            emit(Array(Fixtures.receiverSYN.prefix(6)))
        }
        emit(Fixtures.receiverSYN)
    }

    private func handle(_ packet: LinkPacket) {
        if packet.control.contains(.syn) {
            // The host answered our SYN. Acknowledge it and the link is up.
            hostSeq = packet.seq
            emit(LinkPacket(control: .ack, seq: accessorySeq, ack: packet.seq, session: 0).encode())
            return
        }
        guard !packet.payload.isEmpty else { return }  // bare ACK from the host

        if options.dropFirstDataAck, !droppedAnAck {
            droppedAnAck = true
            return
        }
        hostSeq = packet.seq
        emit(LinkPacket(control: .ack, seq: accessorySeq, ack: packet.seq, session: 0).encode())

        if packet.session == 1 {
            handleControl(packet.payload)
        } else if packet.session == 2 {
            handleExternalAccessory(Array(packet.payload.dropFirst(2)))
        }
    }

    private func handleControl(_ payload: [UInt8]) {
        guard let message = ControlMessage(parsing: payload) else { return }
        controlMessagesReceived.append(message.id)
        switch message.id {
        case ControlMessage.ID.startIdentification.rawValue:
            let sequence = nextAccessorySeq()
            emitData(session: 1, payload: Fixtures.identificationInformation, seq: sequence)
            if options.duplicateIdentification {
                emitData(session: 1, payload: Fixtures.identificationInformation, seq: sequence)
            }
            if options.resetAfterIdentification {
                emit(LinkPacket(control: .rst, seq: nextAccessorySeq(), ack: hostSeq, session: 0).encode())
            }
        case ControlMessage.ID.startExternalAccessorySession.rawValue:
            var status = Fixtures.externalAccessoryStatusOpen
            status[status.count - 1] = options.sessionStatus
            emitData(session: 1, payload: status, seq: nextAccessorySeq())
        case ControlMessage.ID.stopExternalAccessorySession.rawValue:
            stopSessionCount += 1
        default:
            break
        }
    }

    /// The CFD router. Requests are answered from `attributes`; heartbeats get
    /// a heartbeat back, and optionally the host's own frame handed straight
    /// back with `src` unchanged, which is what makes the ping-pong bug bite.
    private func handleExternalAccessory(_ bytes: [UInt8]) {
        for frame in reassembler.feed(bytes) {
            hostFrames.append(frame)

            if options.echoesHostFrames {
                sendFrames([Fixtures.echoedHostHeartbeat])
            }
            if frame.message == CFDMessage.heartbeat.rawValue {
                if options.heartbeatsBack { sendFrames([Fixtures.deviceHeartbeat]) }
                continue
            }
            guard options.answersRequests else { continue }

            switch frame.message {
            case CFDMessage.getMany.rawValue:
                sendFrames([Fixtures.getAllReply])
            case CFDMessage.getAttribute.rawValue:
                guard let id = frame.payload.first else { continue }
                sendFrames([reply(message: .getAttribute, id: id)])
            case CFDMessage.setAttribute.rawValue:
                guard frame.payload.count >= 3 else { continue }
                attributes[frame.payload[0]] = frame.payload[2]
                sendFrames([reply(message: .setAttribute, id: frame.payload[0])])
            default:
                continue
            }
        }
    }

    private func reply(message: CFDMessage, id: UInt8) -> [UInt8] {
        let payload: [UInt8] = attributes[id].map { [0, id, 1, $0] } ?? [1, id]
        return CFDLink.encode(
            message: message,
            payload: payload,
            node: CFDNode(chid: 2, vid: 1, pid: 29),
            seq: 1,
            src: CFDLink.deviceNode,
            dst: CFDLink.hostNode
        )
    }

    /// Pushes CFD bytes back through the EA session, which is where the
    /// receiver's frames come from.
    func sendFrames(_ frames: [[UInt8]]) {
        let payload = UInt16(1).bigEndianBytes + frames.flatMap { $0 }
        emitData(session: 2, payload: payload, seq: nextAccessorySeq())
    }

    /// Models the receiver going quiet — it stops acknowledging and stops
    /// sending, which is what it really does for a second or so at a time when
    /// it has nothing to say. Host frames are still received and recorded.
    func goQuiet() { acknowledgesData = false }
    func resume() { acknowledgesData = true }

    /// Sends the same EA data packet twice with the same sequence number — a
    /// retransmission, which the host must acknowledge twice but deliver once.
    func sendDuplicatedFrames(_ frames: [[UInt8]]) {
        let payload = UInt16(1).bigEndianBytes + frames.flatMap { $0 }
        let sequence = nextAccessorySeq()
        emitData(session: 2, payload: payload, seq: sequence)
        emitData(session: 2, payload: payload, seq: sequence)
    }

    private func nextAccessorySeq() -> UInt8 {
        accessorySeq = accessorySeq &+ 1
        return accessorySeq
    }

    private func emitData(session: UInt8, payload: [UInt8], seq: UInt8) {
        emit(LinkPacket(control: .ack, seq: seq, ack: hostSeq, session: session, payload: payload).encode())
    }

    private func emit(_ bytes: [UInt8]) {
        guard !isClosed, acknowledgesData else { return }
        continuation?.yield(bytes)
    }

    // MARK: - assertions support

    /// The host must never originate a SYN — only ever answer one with SYN|ACK.
    var hostSentUnsolicitedSYN: Bool {
        hostPackets.contains { $0.control.contains(.syn) && !$0.control.contains(.ack) }
    }

    var hostSYNAckCount: Int {
        hostPackets.count { $0.control.contains(.syn) && $0.control.contains(.ack) }
    }

    /// Heartbeat replies the host addressed back to a specific node, with src
    /// and dst swapped relative to the frame that prompted them.
    var hostHeartbeatRepliesToDevice: [CFDFrame] {
        hostFrames.filter { $0.message == CFDMessage.heartbeat.rawValue && $0.dst == CFDLink.deviceNode }
    }

    func rawWriteCount(of bytes: [UInt8]) -> Int {
        hostRawWrites.count { $0 == bytes }
    }
}
