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
        /// Answer `StartExternalAccessoryProtocolSession` at all. Off models an
        /// accessory that simply never confirms the session.
        var answersSessionStatus = true
        /// Report the status against a different session than the one asked
        /// for, which says nothing about ours.
        var statusSessionOverride: UInt16?
        /// Answer CFD requests. Off makes every request time out.
        var answersRequests = true
        /// Acknowledge N sequence numbers beyond the packet just received —
        /// acknowledgements are cumulative, so this still acknowledges it.
        var acknowledgesAhead: UInt8 = 0
        /// Hand the host's own frames back with `src` unchanged, the way the
        /// real router does.
        var echoesHostFrames = false
        /// Send a device heartbeat whenever the host sends one.
        var heartbeatsBack = true
        /// `rx_speaker` restarts the receiver: the set is taken and the link
        /// goes away, with no CFD reply and no read-back possible.
        var restartsOnSpeakerWrite = false
        /// `rx_reset` wipes it — same shape.
        var resetsOnFactoryReset = false
    }

    private let options: Options
    private var stream: AsyncStream<[UInt8]>?
    private var continuation: AsyncStream<[UInt8]>.Continuation?
    private var parser = LinkParser()
    private var reassembler = CFDReassembler()

    private var accessorySeq: UInt8 = 0
    private var hostSeq: UInt8 = 0
    /// The host sequence number acknowledged so far. Every accessory packet
    /// carries it, which is how the real receiver piggybacks acknowledgements.
    private var acknowledgedSeq: UInt8 = 0
    private var sentSYN = false
    private var droppedAnAck = false
    private var acknowledgesData = true
    private var isClosed = false
    private var isReset = false
    private var beatsBack: Bool
    private(set) var wasTerminated = false

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
        beatsBack = options.heartbeatsBack
    }

    // MARK: - ByteTransport

    /// A reconnect builds a fresh transport against the same device, so a
    /// closed accessory hands back a new stream and starts the handshake over.
    /// Without that, every retry in a test failed at the claim and a session
    /// that reconnects endlessly looked bounded.
    func inbound() -> AsyncStream<[UInt8]> {
        if let stream, !isClosed || wasTerminated { return stream }
        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.stream = stream
        self.continuation = continuation
        isClosed = false
        isReset = false
        sentSYN = false
        accessorySeq = 0
        hostSeq = 0
        parser = LinkParser()
        reassembler = CFDReassembler()
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
        // A link the accessory has reset answers nothing at all.
        guard !isReset else { return }
        if packet.control.contains(.syn) {
            // The host answered our SYN. Acknowledge it and the link is up.
            hostSeq = packet.seq
            acknowledge(packet.seq)
            return
        }
        guard !packet.payload.isEmpty else { return }  // bare ACK from the host

        if options.dropFirstDataAck, !droppedAnAck {
            droppedAnAck = true
            return
        }
        hostSeq = packet.seq
        acknowledge(packet.seq)

        if packet.session == 1 {
            handleControl(packet.payload)
        } else if packet.session == 2 {
            handleExternalAccessory(Array(packet.payload.dropFirst(2)))
        }
    }

    private func acknowledge(_ seq: UInt8) {
        guard acknowledgesData else { return }
        acknowledgedSeq = seq &+ options.acknowledgesAhead
        emit(LinkPacket(control: .ack, seq: accessorySeq, ack: acknowledgedSeq, session: 0).encode())
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
            if options.resetAfterIdentification { resetLink() }
        case ControlMessage.ID.startExternalAccessorySession.rawValue:
            guard options.answersSessionStatus else { return }
            var status = Fixtures.externalAccessoryStatusOpen
            status[status.count - 1] = options.sessionStatus
            if let other = options.statusSessionOverride {
                // Parameter 0's two-byte data is the session the status is about.
                status[10] = other.bigEndianBytes[0]
                status[11] = other.bigEndianBytes[1]
            }
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
                if beatsBack { sendFrames([Fixtures.nodeHeartbeat]) }
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
                let id = frame.payload[0]
                // Writing these makes the receiver restart or wipe itself: the
                // command is taken and the link goes away before it can answer.
                let takesTheLinkWithIt = (options.restartsOnSpeakerWrite && id == Attr.rxSpeaker.rawValue)
                    || (options.resetsOnFactoryReset && id == Attr.rxReset.rawValue)
                attributes[id] = frame.payload[2]
                if takesTheLinkWithIt {
                    resetLink()
                    continue
                }
                sendFrames([reply(message: .setAttribute, id: id)])
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

    /// Models the receiver acknowledging lazily: it stops answering the host's
    /// packets for a moment but keeps beating, which is what it really does.
    /// Stopping the heartbeats too would be a dead link, not a quiet one — and
    /// the session is entitled to tell them apart.
    func goQuiet() { acknowledgesData = false }
    func resume() { acknowledgesData = true }

    /// A receiver that is still acknowledging but has stopped beating: alive at
    /// the link layer, gone above it.
    func stopHeartbeating() { beatsBack = false }

    /// RST: the accessory tears the link down and stops answering entirely.
    func resetLink() {
        guard !isReset else { return }
        emit(LinkPacket(control: .rst, seq: nextAccessorySeq(), ack: hostSeq, session: 0).encode())
        isReset = true
    }

    /// The device being pulled out: the interface is terminated under the
    /// transport and the byte stream ends, with no orderly close.
    func unplug() {
        wasTerminated = true
        isClosed = true
        continuation?.finish()
    }

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

    /// Carries the acknowledgement the accessory has actually reached, not the
    /// packet it happens to be answering. Stamping the current host sequence
    /// number here makes every reply acknowledge its own request, which is the
    /// one ordering the receiver does *not* always produce.
    private func emitData(session: UInt8, payload: [UInt8], seq: UInt8) {
        emit(LinkPacket(control: .ack, seq: seq, ack: acknowledgedSeq, session: session, payload: payload).encode())
    }

    private func emit(_ bytes: [UInt8]) {
        guard !isClosed else { return }
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

    /// Heartbeat *replies*, as opposed to the host's own broadcast beats.
    ///
    /// `src`/`dst` cannot tell them apart — both go 2 → 1 — so the node handle
    /// is what distinguishes them: a reply carries the handle of whatever beat
    /// at us, and the host's own beats go to `CFDNode.broadcast`.
    var hostHeartbeatRepliesToDevice: [CFDFrame] {
        hostFrames.filter { $0.message == CFDMessage.heartbeat.rawValue && $0.node == Fixtures.heartbeatingNode }
    }

    func rawWriteCount(of bytes: [UInt8]) -> Int {
        hostRawWrites.count { $0 == bytes }
    }
}
