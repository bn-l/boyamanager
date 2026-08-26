import Foundation
import OSLog

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "IAP2")

/// A minimal iAP2 *host* — the Apple-device side of the protocol — over the
/// receiver's "iAP Interface". Just enough to open an External Accessory
/// session and move CFD-Link frames through it, which is exactly what BOYA's
/// iOS app does.
///
/// The one rule that matters: **the accessory initiates**. We echo its detect
/// and answer its SYN with SYN|ACK. Sending our own SYN gets no answer and
/// makes the receiver re-enumerate itself a moment later, so no code path here
/// originates a SYN — `IAP2LinkTests` asserts that over a whole transcript.
///
/// Why a link stopped carrying data. The session reads this rather than
/// guessing from the fact that a stream ended — "the receiver reset us", "it
/// was unplugged" and "we closed it" all look identical from the stream.
enum LinkEnd: Sendable, Equatable {
    /// The accessory sent RST.
    case reset
    /// The device was pulled out — the interface was terminated under us.
    case deviceRemoved
    /// The byte stream ended for some other reason.
    case transportEnded
    /// `close()` — an orderly teardown.
    case closed
}

/// See `docs/PROTOCOL.md` §13.
actor IAP2Link {
    enum LinkError: Error, Sendable, Equatable {
        case noSYN
        case noSessions
        case synAckNotAcknowledged
        case noIdentification
        case noProtocols
        case protocolNotOffered(String)
        case externalAccessoryRefused(UInt8)
        /// The accessory never answered `StartExternalAccessoryProtocolSession`.
        /// Treating that silence as success leaves the session looking open and
        /// the real failure surfaces fifteen seconds later as "unresponsive".
        case noSessionStatus
        case reset
        case notLinked
        case notAcknowledged(UInt8)
    }

    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let transport: any ByteTransport
    private let sleeper: Sleeper
    private var parser = LinkParser()

    /// Our sequence number. Random at start like a real host, injectable so the
    /// tests can assert exact bytes.
    private var seq: UInt8
    /// The last accessory sequence number — what we acknowledge.
    private var rack: UInt8 = 0
    private var theirAck: UInt8?
    private var lastReceivedSeq: UInt8?

    private var syn: LinkPacket?
    private var sessionControl: UInt8?
    private var sessionExternalAccessory: UInt8?
    private var identity = DeviceIdentity()
    private var isIdentified = false
    private var externalAccessoryStatus: UInt8?
    private var externalAccessorySessionID: UInt16 = 1
    private var isLinked = false
    private var wasReset = false
    private var isClosing = false
    private(set) var end: LinkEnd?

    private var pumpTask: Task<Void, Never>?
    private let inboundStream: AsyncStream<[UInt8]>
    private let inboundContinuation: AsyncStream<[UInt8]>.Continuation

    // Waiting: every wait registers a condition plus a timer that always
    // resumes it, so no wait can outlive its timeout even if the accessory
    // goes silent mid-handshake.
    private enum WaitCondition: Sendable, Equatable {
        case syn
        case acknowledged(UInt8)
        case identified
        case externalAccessoryStatus
    }

    private struct Waiter {
        let condition: WaitCondition
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var waiters: [UUID: Waiter] = [:]
    private var isSending = false
    private var sendLockWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter sleeper: every timeout here goes through it, so a test can
    ///   run the link on the same compressed clock as the session above it.
    ///   Two clocks measured against each other is how a "quiet receiver" test
    ///   ends up depending on real-time coincidence.
    init(
        transport: any ByteTransport,
        initialSequence: UInt8? = nil,
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.sleeper = sleeper
        self.seq = initialSequence ?? UInt8.random(in: 1...199)
        (inboundStream, inboundContinuation) = AsyncStream.makeStream(of: [UInt8].self)
    }

    /// CFD frames arriving on the External Accessory session, session-id prefix
    /// already stripped.
    nonisolated var eaInbound: AsyncStream<[UInt8]> { inboundStream }

    // MARK: - public api

    /// Brings the link up, identifies the accessory and opens an EA session on
    /// `protocolName`.
    func open(protocolName: String, sessionID: UInt16, timeout: Duration) async throws -> DeviceIdentity {
        let stream = await transport.inbound()
        pumpTask = Task { [weak self] in
            for await chunk in stream {
                await self?.receive(chunk)
            }
            await self?.transportEnded()
        }

        try await establishLink(timeout: timeout)

        try await send(control: ControlMessage(id: .startIdentification))
        guard await waitFor(.identified, timeout: .seconds(3)) else {
            if wasReset { throw LinkError.reset }
            logger.error("No IdentificationInformation from the accessory")
            throw LinkError.noIdentification
        }
        logger.notice("""
            Identified \(self.identity.model ?? "?", privacy: .public) \
            serial \(self.identity.serial ?? "?", privacy: .public) \
            firmware \(self.identity.firmware ?? "?", privacy: .public)
            """)
        try await send(control: ControlMessage(id: .identificationAccepted))
        // Let PowerSourceUpdate and friends drain before asking for a session.
        try? await sleeper(.milliseconds(300))

        guard !identity.protocols.isEmpty else { throw LinkError.noProtocols }
        guard let offered = identity.protocols.first(where: { $0.name == protocolName }) else {
            logger.error("Accessory does not offer \(protocolName, privacy: .public): \(self.identity.protocols.map(\.name), privacy: .public)")
            throw LinkError.protocolNotOffered(protocolName)
        }

        externalAccessorySessionID = sessionID
        externalAccessoryStatus = nil
        try await send(control: ControlMessage(
            id: .startExternalAccessorySession,
            parameters: [
                ControlParameter(id: 0, data: [offered.id]),
                ControlParameter(id: 1, data: sessionID.bigEndianBytes),
            ]
        ))
        // Silence is not consent: without a status for *this* session id the
        // session is not open, whatever the accessory does next.
        guard await waitFor(.externalAccessoryStatus, timeout: .seconds(1)),
              let status = externalAccessoryStatus
        else {
            if wasReset { throw LinkError.reset }
            logger.error("Accessory never reported a status for EA session \(sessionID, privacy: .public)")
            throw LinkError.noSessionStatus
        }
        guard status == 0 else {
            logger.error("Accessory refused the EA session, status \(status, privacy: .public)")
            throw LinkError.externalAccessoryRefused(status)
        }
        logger.notice("EA session \(sessionID, privacy: .public) open for \(protocolName, privacy: .public)")
        return identity
    }

    /// Writes bytes into the EA session and waits for the link acknowledgement.
    func sendEA(_ bytes: [UInt8]) async throws {
        guard isLinked, let session = sessionExternalAccessory else {
            throw end == .reset ? LinkError.reset : LinkError.notLinked
        }
        try await sendData(session: session, payload: externalAccessorySessionID.bigEndianBytes + bytes)
    }

    /// Same, but does not insist on the acknowledgement.
    ///
    /// The receiver acknowledges lazily — it piggybacks acknowledgements on its
    /// own traffic rather than the 255 ms it advertises — so a beat sent during
    /// a quiet moment ties up the link for a second and starves whatever wants
    /// to poll next. Heartbeats go out every 500 ms and are idempotent, so the
    /// next one covers a lost beat and a retransmission buys nothing.
    func sendHeartbeatEA(_ bytes: [UInt8]) async throws {
        guard isLinked, let session = sessionExternalAccessory else {
            throw end == .reset ? LinkError.reset : LinkError.notLinked
        }
        do {
            try await sendData(
                session: session,
                payload: externalAccessorySessionID.bigEndianBytes + bytes,
                timeout: .milliseconds(400),
                retries: 1
            )
        } catch LinkError.notAcknowledged {
            // Expected while the receiver is quiet; the transport is fine.
        }
    }

    /// Tells the accessory the session is over, then tears everything down.
    ///
    /// Capped so a wedged link cannot delay app quit: the StopEA packet goes
    /// out around the send lock rather than through it, because waiting for
    /// that lock means waiting for up to three acknowledgement timeouts of
    /// whatever is already in flight. That sender is told to give up instead.
    func close() async {
        guard !isClosing else { return }
        isClosing = true
        // Whatever is already waiting for an acknowledgement is waiting on a
        // link that is going away. Unblocking it here rather than leaving it to
        // notice at its own next timeout is what makes the pre-emption real.
        failAllWaiters()
        if isLinked, let session = sessionControl {
            let stop = ControlMessage(
                id: .stopExternalAccessorySession,
                parameters: [ControlParameter(id: 0, data: externalAccessorySessionID.bigEndianBytes)]
            )
            logger.debug("-> \(stop.name, privacy: .public)")
            seq = seq &+ 1
            let packet = LinkPacket(control: .ack, seq: seq, ack: rack, session: session, payload: stop.encode())
            try? await transport.write(packet.encode())
            _ = await waitFor(.acknowledged(seq), timeout: .milliseconds(300))
        }
        isLinked = false
        end = end ?? .closed
        pumpTask?.cancel()
        pumpTask = nil
        failAllWaiters()
        inboundContinuation.finish()
        await transport.close()
        logger.info("Link closed")
    }

    // MARK: - link bring-up

    private func establishLink(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while syn == nil, ContinuousClock.now < deadline {
            // The accessory sends detect on its own; echoing it also prompts a
            // receiver that has been sitting idle since plug-in.
            try await transport.write(LinkPacket.detect)
            if await waitFor(.syn, timeout: .seconds(1)) { break }
        }
        guard let syn else {
            if wasReset { throw LinkError.reset }
            logger.error("Accessory never sent an iAP2 link SYN")
            throw LinkError.noSYN
        }

        let sessions = LinkPacket.sessions(inSYNPayload: syn.payload)
        logger.debug("SYN sessions: \(sessions.map { "\($0.id):type\($0.type)" }.joined(separator: " "), privacy: .public)")
        sessionControl = sessions.first { $0.type == 0 }?.id
        sessionExternalAccessory = sessions.first { $0.type == 2 }?.id
        guard sessionControl != nil, sessionExternalAccessory != nil else {
            logger.error("Accessory offered no control/EA session: \(syn.payload.hexString, privacy: .public)")
            throw LinkError.noSessions
        }

        // Accept the accessory's parameters verbatim. This is the only packet
        // we ever send with the SYN bit set, and only in reply to theirs.
        theirAck = nil
        for attempt in 1...3 {
            try await transport.write(LinkPacket(control: [.syn, .ack], seq: seq, ack: rack, session: 0, payload: syn.payload).encode())
            if await waitFor(.acknowledged(seq), timeout: .milliseconds(1_500)) {
                isLinked = true
                logger.notice("""
                    iAP2 link up (control session \(self.sessionControl ?? 0, privacy: .public), \
                    EA session \(self.sessionExternalAccessory ?? 0, privacy: .public))
                    """)
                return
            }
            if wasReset { throw LinkError.reset }
            logger.info("SYN|ACK not acknowledged, attempt \(attempt, privacy: .public)/3")
        }
        throw LinkError.synAckNotAcknowledged
    }

    // MARK: - receive path

    private func receive(_ chunk: [UInt8]) async {
        for item in parser.feed(chunk) {
            switch item {
            case .detect:
                logger.debug("Accessory detect — echoing")
                try? await transport.write(LinkPacket.detect)
            case .packet(let packet):
                await handle(packet)
            case .junk(let bytes):
                logger.debug("Junk on the link: \(bytes.hexString, privacy: .public)")
            }
        }
    }

    private func handle(_ packet: LinkPacket) async {
        defer { signalWaiters() }

        if packet.control.contains(.ack) { theirAck = packet.ack }
        if packet.control.contains(.syn) {
            syn = packet
            rack = packet.seq
            return
        }
        if packet.control.contains(.rst) {
            logger.error("Accessory reset the iAP2 link")
            isLinked = false
            wasReset = true
            end = .reset
            // Everything waiting is waiting for something that will never come
            // now, and the session above has to learn the link is gone.
            failAllWaiters()
            inboundContinuation.finish()
            return
        }
        guard !packet.payload.isEmpty else { return }  // bare ACK

        let isDuplicate = packet.seq == lastReceivedSeq
        lastReceivedSeq = packet.seq
        rack = packet.seq
        try? await transport.write(LinkPacket(control: .ack, seq: seq, ack: rack, session: 0).encode())
        if isDuplicate {
            logger.debug("Duplicate packet seq \(packet.seq, privacy: .public) — acknowledged, not delivered")
            return
        }

        if packet.session == sessionControl {
            handleControl(packet.payload)
        } else if packet.session == sessionExternalAccessory {
            inboundContinuation.yield(Array(packet.payload.dropFirst(2)))
        } else {
            logger.debug("Data on unknown session \(packet.session, privacy: .public): \(packet.payload.hexString, privacy: .public)")
        }
    }

    private func handleControl(_ payload: [UInt8]) {
        guard let message = ControlMessage(parsing: payload) else { return }
        logger.debug("<- \(message.name, privacy: .public)")
        switch message.id {
        case ControlMessage.ID.identificationInformation.rawValue:
            identity = DeviceIdentity(parsing: message.parameters)
            isIdentified = true
        case ControlMessage.ID.statusExternalAccessorySession.rawValue:
            // Parameter 0 is the session the status is about. A status for a
            // session we did not ask for says nothing about ours.
            let reported = message.parameters.first { $0.id == 0 }?.data
            guard reported == nil || reported == externalAccessorySessionID.bigEndianBytes else {
                logger.info("EA status for session \(reported?.hexString ?? "?", privacy: .public) — not ours")
                return
            }
            externalAccessoryStatus = message.parameters.first { $0.id == 1 }?.data.first
        default:
            break
        }
    }

    /// The stream ending is the first thing that happens on an unplug, and
    /// telling an unplug from a transport fault decides whether the user is
    /// shown a retry countdown for a device that is not there.
    ///
    /// The transport's answer is looked at twice. On this receiver the
    /// IOUSBHost interest handler does not fire for a yank at all — the read
    /// fails, the stream ends, and IOKit's removal lands tens of milliseconds
    /// later — so the first look, taken the instant the read failed, says
    /// "still present". A close of our own has already set `end`, so it pays
    /// nothing for the second look.
    private func transportEnded() async {
        var removed = await transport.wasTerminated
        if !removed, end == nil {
            try? await sleeper(Self.terminationGrace)
            removed = await transport.wasTerminated
        }
        logger.info("Transport stream ended (\(removed ? "device removed" : "no device removal reported", privacy: .public))")
        isLinked = false
        end = end ?? (removed ? .deviceRemoved : .transportEnded)
        failAllWaiters()
        inboundContinuation.finish()
    }

    /// How long to let IOKit catch up with a yank before calling the stream's
    /// ending something other than a removal. Measured gap on the device
    /// between the read failing and the removal notification: 68 ms.
    private static let terminationGrace = Duration.milliseconds(250)

    // MARK: - send path

    private func send(control message: ControlMessage, timeout: Duration = .seconds(1), retries: Int = 3) async throws {
        guard let session = sessionControl else { throw LinkError.notLinked }
        logger.debug("-> \(message.name, privacy: .public)")
        try await sendData(session: session, payload: message.encode(), timeout: timeout, retries: retries)
    }

    /// One link data packet in flight at a time — the accessory acknowledges
    /// cumulatively, so overlapping sends can leave an earlier sequence number
    /// unacknowledged forever.
    private func sendData(session: UInt8, payload: [UInt8], timeout: Duration = .seconds(1), retries: Int = 3) async throws {
        await acquireSendLock()
        defer { releaseSendLock() }
        guard end == nil else { throw end == .reset ? LinkError.reset : LinkError.notLinked }

        seq = seq &+ 1
        let mySeq = seq
        let packet = LinkPacket(control: .ack, seq: mySeq, ack: rack, session: session, payload: payload).encode()
        for attempt in 1...max(1, retries) {
            try await transport.write(packet)
            if await waitFor(.acknowledged(mySeq), timeout: timeout) { return }
            if wasReset { throw LinkError.reset }
            // `close()` unblocks whatever is in flight rather than queueing
            // behind it, so a retransmission here would be shouting at a link
            // that is already being torn down.
            if isClosing || end != nil { throw LinkError.notLinked }
            // Routine: the receiver piggybacks acknowledgements on its own
            // traffic, so an idle moment costs one retransmission.
            logger.debug("""
                Link packet seq \(mySeq, privacy: .public) unacknowledged, \
                attempt \(attempt, privacy: .public)/\(retries, privacy: .public)
                """)
        }
        throw LinkError.notAcknowledged(mySeq)
    }

    private func acquireSendLock() async {
        while isSending {
            await withCheckedContinuation { sendLockWaiters.append($0) }
        }
        isSending = true
    }

    private func releaseSendLock() {
        isSending = false
        if !sendLockWaiters.isEmpty { sendLockWaiters.removeFirst().resume() }
    }

    // MARK: - waiting

    private func isSatisfied(_ condition: WaitCondition) -> Bool {
        switch condition {
        case .syn: syn != nil
        case .acknowledged(let wanted):
            // Acknowledgements are cumulative and the sequence space wraps, so
            // this is "at or beyond", not equality: an ack that jumped past our
            // packet still acknowledges it, and insisting on the exact number
            // is what made an idle receiver look like a dead one.
            theirAck.map { $0 &- wanted < 128 } ?? false
        case .identified: isIdentified
        case .externalAccessoryStatus: externalAccessoryStatus != nil
        }
    }

    /// A dead link satisfies nothing. This is checked before the condition so
    /// that a reply landing in the same breath as an RST cannot "win" and let
    /// the handshake carry on over a link the accessory has torn down.
    private func waitFor(_ condition: WaitCondition, timeout: Duration) async -> Bool {
        if wasReset { return false }
        if isSatisfied(condition) { return true }

        let id = UUID()
        let timer = Task { [weak self, sleeper] in
            try? await sleeper(timeout)
            await self?.expire(id)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            waiters[id] = Waiter(condition: condition, continuation: continuation)
        }
    }

    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }

    private func signalWaiters() {
        for (id, waiter) in waiters {
            let met = !wasReset && isSatisfied(waiter.condition)
            guard met || wasReset else { continue }
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: met)
        }
    }

    private func failAllWaiters() {
        let pending = waiters
        waiters = [:]
        for waiter in pending.values { waiter.continuation.resume(returning: false) }
    }
}

// MARK: - link packets

struct LinkControl: OptionSet, Sendable, Equatable {
    let rawValue: UInt8
    static let syn = Self(rawValue: 0x80)
    static let ack = Self(rawValue: 0x40)
    static let eak = Self(rawValue: 0x20)
    static let rst = Self(rawValue: 0x10)
    static let slp = Self(rawValue: 0x08)
}

/// `FF 5A | u16 BE length | ctrl | seq | ack | session | header checksum |
/// payload | payload checksum`. Both checksums are the two's complement of the
/// bytes they cover, so each block sums to zero mod 256.
struct LinkPacket: Sendable, Equatable {
    var control: LinkControl
    var seq: UInt8
    var ack: UInt8
    var session: UInt8
    var payload: [UInt8] = []

    static let detect: [UInt8] = [0xFF, 0x55, 0x02, 0x00, 0xEE, 0x10]
    static let headerLength = 9

    func encode() -> [UInt8] {
        let length = Self.headerLength + (payload.isEmpty ? 0 : payload.count + 1)
        var header: [UInt8] = [0xFF, 0x5A]
        header.append(contentsOf: UInt16(length).bigEndianBytes)
        header.append(contentsOf: [control.rawValue, seq, ack, session])
        header.append(twosComplement(header))
        guard !payload.isEmpty else { return header }
        return header + payload + [twosComplement(payload)]
    }

    /// The session list at the tail of a SYN payload: 3 bytes each — id, type,
    /// version. Type 0 is the control session, type 2 the External Accessory one.
    static func sessions(inSYNPayload payload: [UInt8]) -> [(id: UInt8, type: UInt8)] {
        guard payload.count > 12 else { return [] }
        return stride(from: 10, to: payload.count - 2, by: 3).map { (id: payload[$0], type: payload[$0 + 1]) }
    }
}

private func twosComplement(_ bytes: [UInt8]) -> UInt8 {
    0 &- bytes.reduce(into: UInt8(0)) { $0 = $0 &+ $1 }
}

enum LinkItem: Sendable, Equatable {
    case detect([UInt8])
    case packet(LinkPacket)
    case junk([UInt8])
}

/// Byte stream → link packets. Packets longer than one bulk packet simply
/// continue into the next, and a packet can arrive split anywhere, so this
/// keeps a buffer and resyncs on `FF 5A`.
struct LinkParser: Sendable {
    private var buffer: [UInt8] = []

    init() {}

    mutating func feed(_ data: [UInt8]) -> [LinkItem] {
        buffer.append(contentsOf: data)
        var items: [LinkItem] = []
        while true {
            guard let start = buffer.firstIndexOfLinkSync() else {
                if buffer.count >= 6, buffer[0] == 0xFF, buffer[1] == 0x55 {
                    items.append(.detect(Array(buffer[0..<6])))
                    buffer.removeFirst(6)
                    continue
                }
                // A trailing 0xFF may be the first half of the next sync word.
                if !(buffer.count == 1 && buffer[0] == 0xFF) {
                    if !buffer.isEmpty { items.append(.junk(buffer)) }
                    buffer.removeAll()
                }
                break
            }
            if start > 0 {
                let prefix = Array(buffer[0..<start])
                buffer.removeFirst(start)
                items.append(prefix.starts(with: [0xFF, 0x55]) ? .detect(prefix) : .junk(prefix))
            }
            guard buffer.count >= LinkPacket.headerLength else { break }
            guard buffer[0..<LinkPacket.headerLength].reduce(into: UInt8(0), { $0 = $0 &+ $1 }) == 0 else {
                buffer.removeFirst(2)
                continue
            }
            let length = Int(UInt16(bigEndianAt: buffer, 2))
            guard length >= LinkPacket.headerLength else {
                buffer.removeFirst(2)
                continue
            }
            guard buffer.count >= length else { break }

            let raw = Array(buffer[0..<length])
            buffer.removeFirst(length)
            let payload = length > LinkPacket.headerLength ? Array(raw[LinkPacket.headerLength..<(length - 1)]) : []
            if length > LinkPacket.headerLength,
               raw[LinkPacket.headerLength...].reduce(into: UInt8(0), { $0 = $0 &+ $1 }) != 0 {
                items.append(.junk(raw))
                continue
            }
            items.append(.packet(LinkPacket(
                control: LinkControl(rawValue: raw[4]),
                seq: raw[5],
                ack: raw[6],
                session: raw[7],
                payload: payload
            )))
        }
        return items
    }
}

// MARK: - control session

struct ControlParameter: Sendable, Equatable {
    var id: UInt16
    var data: [UInt8]

    func encode() -> [UInt8] {
        UInt16(4 + data.count).bigEndianBytes + id.bigEndianBytes + data
    }

    static func parse(_ bytes: [UInt8]) -> [Self] {
        var parameters: [Self] = []
        var index = 0
        while index + 4 <= bytes.count {
            let length = Int(UInt16(bigEndianAt: bytes, index))
            let id = UInt16(bigEndianAt: bytes, index + 2)
            guard length >= 4, index + length <= bytes.count else { break }
            parameters.append(Self(id: id, data: Array(bytes[(index + 4)..<(index + length)])))
            index += length
        }
        return parameters
    }
}

/// `40 40 | u16 BE total length | u16 BE message id | parameters*`
struct ControlMessage: Sendable, Equatable {
    enum ID: UInt16, Sendable {
        case startIdentification = 0x1D00
        case identificationInformation = 0x1D01
        case identificationAccepted = 0x1D02
        case identificationRejected = 0x1D03
        case startExternalAccessorySession = 0xEA00
        case stopExternalAccessorySession = 0xEA01
        case statusExternalAccessorySession = 0xEA03
    }

    var id: UInt16
    var parameters: [ControlParameter] = []

    init(id: UInt16, parameters: [ControlParameter] = []) {
        self.id = id
        self.parameters = parameters
    }

    init(id: ID, parameters: [ControlParameter] = []) {
        self.init(id: id.rawValue, parameters: parameters)
    }

    init?(parsing bytes: [UInt8]) {
        guard bytes.count >= 6, bytes[0] == 0x40, bytes[1] == 0x40 else { return nil }
        let length = Int(UInt16(bigEndianAt: bytes, 2))
        guard length >= 6, length <= bytes.count else { return nil }
        id = UInt16(bigEndianAt: bytes, 4)
        parameters = ControlParameter.parse(Array(bytes[6..<length]))
    }

    func encode() -> [UInt8] {
        let body = parameters.flatMap { $0.encode() }
        return [0x40, 0x40] + UInt16(6 + body.count).bigEndianBytes + id.bigEndianBytes + body
    }

    var name: String {
        switch id {
        case 0x1D00: "StartIdentification"
        case 0x1D01: "IdentificationInformation"
        case 0x1D02: "IdentificationAccepted"
        case 0x1D03: "IdentificationRejected"
        case 0x1D06: "IdentificationInformationUpdate"
        case 0xAE00: "PowerSourceUpdate"
        case 0xAE02: "PowerUpdate"
        case 0xAE03: "StopPowerUpdates"
        case 0xEA00: "StartExternalAccessoryProtocolSession"
        case 0xEA01: "StopExternalAccessoryProtocolSession"
        case 0xEA03: "StatusExternalAccessoryProtocolSession"
        default: String(format: "0x%04X", id)
        }
    }
}

struct EAProtocol: Sendable, Equatable {
    var id: UInt8
    var name: String
}

/// What `IdentificationInformation` tells us about the receiver.
struct DeviceIdentity: Sendable, Equatable {
    var name: String?
    var model: String?
    var manufacturer: String?
    var serial: String?
    var firmware: String?
    var hardware: String?
    var protocols: [EAProtocol] = []

    init() {}

    init(parsing parameters: [ControlParameter]) {
        for parameter in parameters {
            switch parameter.id {
            case 0: name = parameter.data.cString
            case 1: model = parameter.data.cString
            case 2: manufacturer = parameter.data.cString
            case 3: serial = parameter.data.cString
            case 4: firmware = parameter.data.cString
            case 5: hardware = parameter.data.cString
            case 10:
                let sub = ControlParameter.parse(parameter.data)
                guard let id = sub.first(where: { $0.id == 0 })?.data.first else { continue }
                protocols.append(EAProtocol(id: id, name: sub.first { $0.id == 1 }?.data.cString ?? ""))
            default:
                break
            }
        }
    }
}

// MARK: - byte helpers

extension UInt16 {
    var bigEndianBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }

    init(bigEndianAt bytes: [UInt8], _ offset: Int) {
        self = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }

    /// NUL-terminated UTF-8, as iAP2 string parameters are encoded.
    var cString: String {
        String(decoding: prefix { $0 != 0 }, as: UTF8.self)
    }

    fileprivate func firstIndexOfLinkSync() -> Int? {
        guard count >= 2 else { return nil }
        for index in 0...(count - 2) where self[index] == 0xFF && self[index + 1] == 0x5A {
            return index
        }
        return nil
    }
}
