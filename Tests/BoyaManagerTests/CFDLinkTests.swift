import Testing
@testable import BoyaManager

@Suite("CFD-Link codec")
struct CFDLinkTests {
    @Test("Encoding `get nc` reproduces the captured request byte for byte")
    func encodeMatchesCapture() {
        let frame = CFDLink.encode(
            message: .getAttribute,
            payload: [Attr.noiseCancellation.rawValue],
            node: .settings,
            seq: 13
        )

        #expect(frame == Fixtures.getNoiseCancellationRequest)
    }

    @Test("Encoding `get_all` reproduces the captured request byte for byte")
    func encodeGetAllMatchesCapture() {
        let frame = CFDLink.encode(message: .getMany, payload: [0], node: .settings, seq: 23)

        #expect(frame == Fixtures.getAllRequest)
    }

    @Test("A captured reply parses into its documented fields")
    func parseReply() throws {
        let frame = try #require(CFDFrame(parsing: Fixtures.getNoiseCancellationReply))

        #expect(frame.src == CFDLink.deviceNode)
        #expect(frame.dst == CFDLink.hostNode)
        #expect(frame.service == 0x001D)
        #expect(frame.message == CFDMessage.getAttribute.rawValue)
        #expect(frame.payload == [0, 47, 1, 2])
    }

    @Test("Build/parse round-trips an arbitrary payload")
    func roundTrip() throws {
        let payload: [UInt8] = [0x2F, 0x01, 0x02, 0xFF, 0x00]
        let node = CFDNode(chid: 3, vid: 4, pid: 0x1234)

        let encoded = CFDLink.encode(message: .setAttribute, payload: payload, node: node, seq: 0xBEEF)
        let frame = try #require(CFDFrame(parsing: encoded))

        #expect(frame.payload == payload)
        #expect(frame.node == node)
        #expect(frame.seq == 0xBEEF)
        #expect(frame.message == CFDMessage.setAttribute.rawValue)
    }

    @Test("A corrupted checksum is rejected rather than parsed")
    func rejectsBadChecksum() {
        var corrupted = Fixtures.getNoiseCancellationReply
        corrupted[corrupted.count - 1] &+= 1

        #expect(CFDFrame(parsing: corrupted) == nil)
    }

    @Test("A corrupted payload byte is rejected — the checksum covers it")
    func rejectsCorruptedPayload() {
        var corrupted = Fixtures.getNoiseCancellationReply
        corrupted[19] &+= 1

        #expect(CFDFrame(parsing: corrupted) == nil)
    }

    @Test("A truncated frame is rejected")
    func rejectsTruncatedFrame() {
        #expect(CFDFrame(parsing: Array(Fixtures.getAllReply.dropLast(10))) == nil)
    }

    @Test("A 127-byte frame split across 64-byte packets is reassembled into one")
    func reassemblesAcrossPackets() {
        let frame = Fixtures.getAllReply
        var reassembler = CFDReassembler()

        let first = reassembler.feed(Array(frame[0..<64]))
        let second = reassembler.feed(Array(frame[64..<126]))
        let third = reassembler.feed(Array(frame[126...]))

        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(third.count == 1)
        #expect(third.first?.message == CFDMessage.getMany.rawValue)
        #expect(third.first?.payload.count == 110)
    }

    @Test("Zero padding between frames is skipped, not parsed")
    func skipsZeroPadding() {
        var reassembler = CFDReassembler()
        let padding = [UInt8](repeating: 0, count: 34)

        let frames = reassembler.feed(padding + Fixtures.deviceHeartbeat + padding + Fixtures.getNoiseCancellationReply)

        #expect(frames.count == 2)
        #expect(frames.first?.isHeartbeat == true)
        #expect(frames.last?.message == CFDMessage.getAttribute.rawValue)
    }

    @Test("Three frames arriving in one packet all come out")
    func multipleFramesInOneChunk() {
        var reassembler = CFDReassembler()

        let frames = reassembler.feed(Fixtures.deviceHeartbeat + Fixtures.echoedHostHeartbeat + Fixtures.getAllReply)

        #expect(frames.count == 3)
        #expect(frames.map(\.src) == [1, 2, 1])
    }

    @Test("A frame arriving one byte at a time is still reassembled")
    func reassemblesByteByByte() {
        var reassembler = CFDReassembler()
        var frames: [CFDFrame] = []

        for byte in Fixtures.getAllReply {
            frames += reassembler.feed([byte])
        }

        #expect(frames.count == 1)
    }

    @Test("The device heartbeat is recognised and the router's echo of ours is not from the device")
    func heartbeatAndEcho() throws {
        let fromDevice = try #require(CFDFrame(parsing: Fixtures.deviceHeartbeat))
        let echoed = try #require(CFDFrame(parsing: Fixtures.echoedHostHeartbeat))

        #expect(fromDevice.isHeartbeat)
        #expect(fromDevice.src == CFDLink.deviceNode)
        // Same message, but src is still ours — answering it is the ping-pong loop.
        #expect(echoed.isHeartbeat)
        #expect(echoed.src == CFDLink.hostNode)
    }

    @Test("The heartbeat payload matches the constant the Android SDK sends")
    func heartbeatPayload() {
        let payload = CFDLink.heartbeatPayload(tick: 0x0102_0304)

        #expect(payload == [0x00, 0x00, 0x04, 0x00, 0x01, 0x09, 0x04, 0x03, 0x02, 0x01, 0x00, 0x00, 0x24])
        #expect(payload.count == 13)
    }

    @Test("An over-long declared length is resynced past instead of stalling the stream")
    func recoversFromBogusLength() {
        var reassembler = CFDReassembler()
        // 0x55 0x10 with a length beyond the protocol maximum.
        let bogus: [UInt8] = [0x55, 0x10, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

        let frames = reassembler.feed(bogus + Fixtures.deviceHeartbeat)

        #expect(frames.count == 1)
        #expect(frames.first?.isHeartbeat == true)
    }
}

@Suite("Attribute decoding")
struct AttributeTests {
    @Test("The captured get_all decodes to the 24 attributes the device reported")
    func decodesRealDump() throws {
        let frame = try #require(CFDFrame(parsing: Fixtures.getAllReply))

        let snapshot = AttributeSnapshot(decoding: frame.payload)

        #expect(snapshot.status == 0)
        #expect(snapshot.values.count == 24)
        #expect(snapshot.values == Fixtures.getAllExpected)
    }

    @Test("An attribute the device does not report reads as absent, not as zero")
    func absentAttributeMeansUnavailable() throws {
        let frame = try #require(CFDFrame(parsing: Fixtures.getAllReply))

        let snapshot = AttributeSnapshot(decoding: frame.payload)

        // Per-transmitter gain belongs to other members of the family, not to
        // a mini 2, so the receiver never sends it.
        #expect(snapshot[.tx1Gain] == nil)
        #expect(snapshot.byte(.tx1Gain) == nil)
    }

    @Test("Attribute 46 is not in the table — this receiver never answers for it")
    func agcIsNotAnAttribute() throws {
        let frame = try #require(CFDFrame(parsing: Fixtures.getAllReply))

        let snapshot = AttributeSnapshot(decoding: frame.payload)

        // BOYA's per-model metadata claims `agc` for the mini 2, but `get_all`
        // omits it and a direct read answers status 1 even with a transmitter
        // online. Keeping it out of `Attr` means `HardwareTests.readsAttributes`
        // fails loudly if firmware ever starts sending it.
        #expect(Attr(rawValue: 46) == nil)
        #expect(snapshot.values[46] == nil)
    }

    @Test("tx*_online reads 1 as online — BOYA's own label is inverted")
    func onlinePolarity() throws {
        let frame = try #require(CFDFrame(parsing: Fixtures.getAllReply))

        let snapshot = AttributeSnapshot(decoding: frame.payload)

        #expect(snapshot.byte(.tx1Online) == 0)
        #expect(snapshot.byte(.tx2Online) == 1)
        #expect(snapshot.tx1.isOnline == false)
        #expect(snapshot.tx2.isOnline == true)
        #expect(Attr.tx1Online.labels?[1] == "Online")
        #expect(Attr.tx1Online.labels?[0] == "Offline")
    }

    @Test("The transmitter views carry what the dump said")
    func transmitterViews() throws {
        let frame = try #require(CFDFrame(parsing: Fixtures.getAllReply))

        let snapshot = AttributeSnapshot(decoding: frame.payload)

        #expect(snapshot.tx2.battery == 3)
        #expect(snapshot.tx2.signal == 4)
        #expect(snapshot.tx2.channel == 1)
        #expect(snapshot.receiver.battery == 4)
        #expect(snapshot.receiver.charging == 2)
    }

    @Test("An offline transmitter reports no live battery even though the device kept the stale value")
    func staleValuesAreNotLive() throws {
        let frame = try #require(CFDFrame(parsing: Fixtures.getAllReply))

        let snapshot = AttributeSnapshot(decoding: frame.payload)

        // tx1 is offline; the device still reports a battery byte for it.
        #expect(snapshot[.tx1Battery] != nil)
        #expect(snapshot.tx1.liveBattery == nil)
    }

    @Test("A status-1 reply is flagged unavailable")
    func statusOne() {
        let snapshot = AttributeSnapshot(decoding: [1, Attr.tx1Gain.rawValue, 1, 0])

        #expect(!snapshot.isAvailable)
        #expect(snapshot.status == 1)
    }

    @Test("A truncated value is dropped rather than read past the end")
    func truncatedValue() {
        let snapshot = AttributeSnapshot(decoding: [0, 47, 1, 2, 65, 4, 1])

        #expect(snapshot.values == [47: [2]])
    }

    @Test("Merging a read-back keeps everything else the poll knew")
    func merging() throws {
        let frame = try #require(CFDFrame(parsing: Fixtures.getAllReply))
        let full = AttributeSnapshot(decoding: frame.payload)

        let merged = full.merging(AttributeSnapshot(decoding: [0, 47, 1, 0]))

        #expect(merged.byte(.noiseCancellation) == 0)
        #expect(merged.byte(.rxGain) == 4)
        #expect(merged.values.count == 24)
    }

    @Test("Ranges match what the device enforces")
    func ranges() {
        #expect(Attr.rxGain.range == 1...6)
        #expect(Attr.noiseCancellation.range == 0...2)
        #expect(Attr.sceneMode.range == 0...4)
        #expect(Attr.recordingMode.range == 0...2)
    }

    @Test("The attributes with side effects are the ones marked risky")
    func riskySet() {
        let risky = Set(Attr.allCases.filter(\.isRisky))

        #expect(risky == [.rxSpeaker, .rxReset, .rxPairEnable])
    }

    @Test("Every attribute id maps to a unique name")
    func namesAreUnique() {
        let names = Attr.allCases.map(\.name)

        #expect(Set(names).count == names.count)
    }

    @Test("The mini 2 set is the 24 attributes the model answers for")
    func miniTwoSet() {
        #expect(Attr.miniTwo.count == 24)
        // Every attribute in the captured dump belongs to it.
        for id in Fixtures.getAllExpected.keys {
            let attr = Attr(rawValue: id)
            #expect(attr != nil, "unknown attribute id \(id)")
            #expect(Attr.miniTwo.contains(attr!), "\(attr!.name) missing from Attr.miniTwo")
        }
    }
}
