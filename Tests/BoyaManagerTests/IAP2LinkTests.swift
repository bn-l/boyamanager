import Foundation
import Testing
@testable import BoyaManager

@Suite("iAP2 link packets")
struct LinkPacketTests {
    @Test("Encoding our SYN|ACK reproduces the captured bytes")
    func synAckMatchesCapture() {
        let packet = LinkPacket(
            control: [.syn, .ack], seq: 0x40, ack: 0x01, session: 0,
            payload: Fixtures.receiverSYNPayload
        )

        #expect(packet.encode() == Fixtures.hostSYNAck)
    }

    @Test("Encoding a bare ACK reproduces the captured bytes")
    func bareAckMatchesCapture() {
        let packet = LinkPacket(control: .ack, seq: 0x01, ack: 0x40, session: 0)

        #expect(packet.encode() == Fixtures.receiverAck)
    }

    @Test("Both checksums make their block sum to zero")
    func checksums() {
        let bytes = LinkPacket(control: .ack, seq: 9, ack: 3, session: 2, payload: [1, 2, 3, 4]).encode()

        let header = bytes[0..<9].reduce(into: UInt8(0)) { $0 = $0 &+ $1 }
        let payload = bytes[9...].reduce(into: UInt8(0)) { $0 = $0 &+ $1 }
        #expect(header == 0)
        #expect(payload == 0)
    }

    @Test("The captured SYN parses, and its session list is control 1 / EA 2")
    func parseSYN() throws {
        var parser = LinkParser()

        let items = parser.feed(Fixtures.receiverSYN)

        guard case .packet(let packet) = try #require(items.first) else {
            Issue.record("expected a packet, got \(items)")
            return
        }
        #expect(packet.control.contains(.syn))
        #expect(packet.seq == 0x01)
        #expect(packet.payload == Fixtures.receiverSYNPayload)

        let sessions = LinkPacket.sessions(inSYNPayload: packet.payload)
        #expect(sessions.count == 2)
        #expect(sessions.first(where: { $0.type == 0 })?.id == 1)
        #expect(sessions.first(where: { $0.type == 2 })?.id == 2)
    }

    @Test("A SYN split mid-packet is buffered until the rest arrives")
    func splitPacket() {
        var parser = LinkParser()

        let first = parser.feed(Array(Fixtures.receiverSYN.prefix(6)))
        let second = parser.feed(Array(Fixtures.receiverSYN.dropFirst(6)))

        #expect(first.isEmpty)
        #expect(second.count == 1)
    }

    @Test("The captured split-SYN behaviour — a 6-byte teaser then the whole packet — still yields the SYN")
    func teaserThenWholePacket() {
        var parser = LinkParser()

        let items = parser.feed(Array(Fixtures.receiverSYN.prefix(6)) + Fixtures.receiverSYN)

        let packets = items.compactMap { item -> LinkPacket? in
            if case .packet(let packet) = item { return packet }
            return nil
        }
        #expect(packets.count == 1)
        #expect(packets.first?.control.contains(.syn) == true)
    }

    @Test("A detect is recognised, not treated as a packet")
    func detect() {
        var parser = LinkParser()

        let items = parser.feed(Fixtures.detect)

        #expect(items == [.detect(Fixtures.detect)])
    }

    @Test("A bad header checksum is resynced past, not accepted")
    func badHeaderChecksum() {
        var corrupted = Fixtures.receiverSYN
        corrupted[8] &+= 1
        var parser = LinkParser()

        let items = parser.feed(corrupted + Fixtures.receiverAck)

        let packets = items.compactMap { item -> LinkPacket? in
            if case .packet(let packet) = item { return packet }
            return nil
        }
        #expect(packets.count == 1)
        #expect(packets.first?.control == .ack)
    }

    @Test("A bad payload checksum is reported as junk, not as a packet")
    func badPayloadChecksum() {
        var corrupted = Fixtures.receiverSYN
        corrupted[corrupted.count - 1] &+= 1
        var parser = LinkParser()

        let items = parser.feed(corrupted)

        #expect(items.count == 1)
        if case .packet = items[0] { Issue.record("a corrupted payload must not parse as a packet") }
    }
}

@Suite("iAP2 control messages")
struct ControlMessageTests {
    @Test("StartIdentification encodes to the captured control message")
    func startIdentification() {
        let message = ControlMessage(id: .startIdentification)

        // The captured packet is header + this message + payload checksum.
        let captured = Array(Fixtures.startIdentification.dropFirst(9).dropLast())
        #expect(message.encode() == captured)
    }

    @Test("Parameters round-trip through encode and parse")
    func parameterRoundTrip() {
        let parameters = [
            ControlParameter(id: 0, data: [0xB1]),
            ControlParameter(id: 1, data: UInt16(1).bigEndianBytes),
        ]

        let encoded = parameters.flatMap { $0.encode() }

        #expect(ControlParameter.parse(encoded) == parameters)
    }

    @Test("StartExternalAccessoryProtocolSession encodes to the captured bytes")
    func startSessionMatchesCapture() {
        let message = ControlMessage(
            id: .startExternalAccessorySession,
            parameters: [
                ControlParameter(id: 0, data: [177]),
                ControlParameter(id: 1, data: UInt16(1).bigEndianBytes),
            ]
        )

        let captured = Array(Fixtures.startExternalAccessorySession.dropFirst(9).dropLast())
        #expect(message.encode() == captured)
    }

    @Test("The captured IdentificationInformation decodes to the receiver's real identity")
    func identity() throws {
        let message = try #require(ControlMessage(parsing: Fixtures.identificationInformation))

        let identity = DeviceIdentity(parsing: message.parameters)

        #expect(message.id == ControlMessage.ID.identificationInformation.rawValue)
        #expect(identity.name == "Microphone")
        #expect(identity.model == "BOYA mini 2")
        #expect(identity.manufacturer == "Shenzhen jiayz photo industrial ltd")
        #expect(identity.serial == "CFD7387E79")
        #expect(identity.firmware == "1.1.0")
        #expect(identity.hardware == "1.1.0")
        #expect(identity.protocols == [EAProtocol(id: 177, name: "BOYA.DeviceLink.com")])
    }

    @Test("The EA status message reports session 1 open")
    func sessionStatus() throws {
        let message = try #require(ControlMessage(parsing: Fixtures.externalAccessoryStatusOpen))

        #expect(message.id == ControlMessage.ID.statusExternalAccessorySession.rawValue)
        #expect(message.parameters.first { $0.id == 1 }?.data == [0])
    }

    @Test("A message that is not a control message is rejected")
    func rejectsNonControl() {
        #expect(ControlMessage(parsing: [0x55, 0x10, 0x00, 0x06, 0x1D, 0x00]) == nil)
        #expect(ControlMessage(parsing: [0x40, 0x40]) == nil)
    }
}

@Suite("iAP2 link, end to end against a scripted accessory")
struct IAP2LinkTests {
    private func open(_ options: FakeAccessory.Options = .init()) async throws -> (IAP2Link, FakeAccessory, DeviceIdentity) {
        let accessory = FakeAccessory(options: options)
        let link = IAP2Link(transport: accessory, initialSequence: 0x40)
        let identity = try await link.open(protocolName: BoyaDevice.externalAccessoryProtocol, sessionID: 1, timeout: .seconds(3))
        return (link, accessory, identity)
    }

    @Test("The full handshake reaches an open session and identifies the receiver")
    func handshake() async throws {
        let (link, accessory, identity) = try await open()

        #expect(identity.serial == "CFD7387E79")
        #expect(identity.protocols.first?.id == 177)
        let messages = await accessory.controlMessagesReceived
        #expect(messages == [0x1D00, 0x1D02, 0xEA00])
        await link.close()
    }

    @Test("Our SYN|ACK goes out byte-identical to the captured one")
    func synAckOnTheWire() async throws {
        let (link, accessory, _) = try await open()

        let count = await accessory.rawWriteCount(of: Fixtures.hostSYNAck)
        #expect(count == 1)
        await link.close()
    }

    @Test("The link never originates a SYN — only ever answers one")
    func neverOriginatesSYN() async throws {
        let (link, accessory, _) = try await open()
        try await link.sendEA(Fixtures.getAllRequest)

        let unsolicited = await accessory.hostSentUnsolicitedSYN
        let synAcks = await accessory.hostSYNAckCount
        #expect(!unsolicited, "sending our own SYN makes the receiver re-enumerate")
        #expect(synAcks == 1)
        await link.close()
    }

    @Test("A SYN arriving split across two reads is still answered")
    func splitSYN() async throws {
        let (link, _, identity) = try await open(.init(splitFirstSYN: true))

        #expect(identity.model == "BOYA mini 2")
        await link.close()
    }

    @Test("An unacknowledged packet is retransmitted exactly once, then succeeds")
    func retransmitsOnce() async throws {
        let (link, accessory, identity) = try await open(.init(dropFirstDataAck: true))

        #expect(identity.serial == "CFD7387E79")
        let dataPackets = await accessory.hostPackets.filter { !$0.payload.isEmpty && $0.session == 1 }
        let sequences = dataPackets.map(\.seq)
        let repeated = sequences.filter { sequence in sequences.filter { $0 == sequence }.count > 1 }
        #expect(Set(repeated).count == 1, "exactly one packet should have been retransmitted")
        #expect(repeated.count == 2, "and retransmitted exactly once, not twice")
        await link.close()
    }

    @Test("A duplicated data packet is acknowledged twice but delivered once")
    func duplicateDeliveredOnce() async throws {
        let (link, accessory, _) = try await open()
        let received = Task {
            var chunks: [[UInt8]] = []
            for await chunk in link.eaInbound {
                chunks.append(chunk)
                if chunks.count == 2 { break }
            }
            return chunks
        }

        await accessory.sendDuplicatedFrames([Fixtures.deviceHeartbeat])
        // Something distinguishable behind the duplicate, so the test can tell
        // "only one delivered" from "nothing delivered yet".
        try? await Task.sleep(for: .milliseconds(120))
        await accessory.sendFrames([Fixtures.getAllReply])
        let chunks = await received.value

        #expect(chunks.count == 2)
        #expect(chunks[0] == Fixtures.deviceHeartbeat)
        #expect(chunks[1] == Fixtures.getAllReply)
        await link.close()
    }

    @Test("EA writes carry the session id ahead of the raw CFD frame")
    func eaWriteFraming() async throws {
        let (link, accessory, _) = try await open()

        try await link.sendEA(Fixtures.getAllRequest)

        let eaPackets = await accessory.hostPackets.filter { $0.session == 2 }
        #expect(eaPackets.count == 1)
        #expect(eaPackets.first?.payload == UInt16(1).bigEndianBytes + Fixtures.getAllRequest)
        await link.close()
    }

    /// The receiver acknowledges lazily — it piggybacks acknowledgements on its
    /// own traffic rather than the 255 ms it advertises, so it can leave a
    /// packet unacknowledged for seconds at a time. A request has to insist; a
    /// heartbeat must not, or a quiet moment reads as a dead transport and the
    /// session is torn down.
    @Test("A quiet receiver fails a request but not a heartbeat")
    func heartbeatsToleranceOfLazyAcknowledgement() async throws {
        let (link, accessory, _) = try await open()
        await accessory.goQuiet()

        await #expect(throws: (any Error).self, "a request must not silently give up") {
            try await link.sendEA(Fixtures.getAllRequest)
        }
        await #expect(throws: Never.self, "a heartbeat that goes unacknowledged is normal") {
            try await link.sendHeartbeatEA(Fixtures.deviceHeartbeat)
        }

        // Both frames still went out — best-effort means unacknowledged, not unsent.
        let sent = await accessory.hostPackets.filter { $0.session == 2 }
        #expect(sent.count >= 2)
        await link.close()
    }

    @Test("A silent accessory fails as noSYN rather than hanging")
    func silentAccessory() async {
        let accessory = FakeAccessory(options: .init(silent: true))
        let link = IAP2Link(transport: accessory, initialSequence: 0x40)

        await #expect(throws: IAP2Link.LinkError.noSYN) {
            try await link.open(protocolName: BoyaDevice.externalAccessoryProtocol, sessionID: 1, timeout: .milliseconds(600))
        }
        await link.close()
    }

    @Test("A refused External Accessory session is reported, not ignored")
    func refusedSession() async {
        let accessory = FakeAccessory(options: .init(sessionStatus: 1))
        let link = IAP2Link(transport: accessory, initialSequence: 0x40)

        await #expect(throws: IAP2Link.LinkError.externalAccessoryRefused(1)) {
            try await link.open(protocolName: BoyaDevice.externalAccessoryProtocol, sessionID: 1, timeout: .seconds(3))
        }
        await link.close()
    }

    @Test("A protocol the accessory does not advertise is refused")
    func unknownProtocol() async {
        let accessory = FakeAccessory()
        let link = IAP2Link(transport: accessory, initialSequence: 0x40)

        await #expect(throws: IAP2Link.LinkError.protocolNotOffered("NOPE.example.com")) {
            try await link.open(protocolName: "NOPE.example.com", sessionID: 1, timeout: .seconds(3))
        }
        await link.close()
    }

    @Test("Closing tells the accessory to stop the session, exactly once")
    func closeStopsSession() async throws {
        let (link, accessory, _) = try await open()

        await link.close()
        await link.close()

        let stops = await accessory.stopSessionCount
        #expect(stops == 1)
    }

    /// Identification lands a moment before the RST, and `waitFor` used to
    /// check the condition before the reset flag — so identification "won",
    /// `open` carried on, and the failure surfaced later as something else.
    /// The old test asserted nothing on the throwing path, so it passed either
    /// way.
    @Test("An RST during identification surfaces as a reset, not as a half-open link")
    func reset() async {
        let accessory = FakeAccessory(options: .init(resetAfterIdentification: true))
        let link = IAP2Link(transport: accessory, initialSequence: 0x40)

        await #expect(throws: IAP2Link.LinkError.reset) {
            try await link.open(protocolName: BoyaDevice.externalAccessoryProtocol, sessionID: 1, timeout: .seconds(3))
        }

        #expect(await link.end == .reset)
        await #expect(throws: IAP2Link.LinkError.reset) {
            try await link.sendEA(Fixtures.getAllRequest)
        }
        await link.close()
    }

    /// A faithful port of `scripts/iap2.py`, which discarded the wait result
    /// and only threw on an explicit non-zero status. A timeout left the status
    /// nil, the link logged "EA session open", and the real failure turned up
    /// fifteen seconds later as "the receiver stopped answering".
    @Test("A session the accessory never confirms fails instead of looking open")
    func missingSessionStatus() async {
        let accessory = FakeAccessory(options: .init(answersSessionStatus: false))
        let link = IAP2Link(transport: accessory, initialSequence: 0x40)

        await #expect(throws: IAP2Link.LinkError.noSessionStatus) {
            try await link.open(protocolName: BoyaDevice.externalAccessoryProtocol, sessionID: 1, timeout: .seconds(3))
        }

        let eaPackets = await accessory.hostPackets.filter { $0.session == 2 }
        #expect(eaPackets.isEmpty, "nothing may be written into a session that was never confirmed")
        await link.close()
    }

    @Test("A status about somebody else's session says nothing about ours")
    func statusForAnotherSession() async {
        let accessory = FakeAccessory(options: .init(statusSessionOverride: 7))
        let link = IAP2Link(transport: accessory, initialSequence: 0x40)

        await #expect(throws: IAP2Link.LinkError.noSessionStatus) {
            try await link.open(protocolName: BoyaDevice.externalAccessoryProtocol, sessionID: 1, timeout: .seconds(3))
        }
        await link.close()
    }

    /// Acknowledgements are cumulative and the sequence space wraps, so an ack
    /// that jumped past our packet still acknowledges it. Matching on equality
    /// left such a packet looking unacknowledged forever.
    @Test("An acknowledgement that jumped past our packet still acknowledges it")
    func cumulativeAcknowledgement() async throws {
        let accessory = FakeAccessory(options: .init(acknowledgesAhead: 3))
        let link = IAP2Link(transport: accessory, initialSequence: 0x40)

        let identity = try await link.open(protocolName: BoyaDevice.externalAccessoryProtocol, sessionID: 1, timeout: .seconds(3))

        #expect(identity.serial == "CFD7387E79")
        await link.close()
    }
}
