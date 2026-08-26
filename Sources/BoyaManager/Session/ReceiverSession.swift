import Foundation
import OSLog

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "Session")
private let cfdLogger = Logger(subsystem: BoyaLog.subsystem, category: "CFD")

/// The link the session drives. `IAP2Link` is the real one; `ReceiverSessionTests`
/// substitutes a fake accessory that speaks CFD-Link back.
protocol AccessoryLink: Sendable {
    func open(protocolName: String, sessionID: UInt16, timeout: Duration) async throws -> DeviceIdentity
    func sendEA(_ bytes: [UInt8]) async throws
    /// Best-effort: a heartbeat that goes unacknowledged is not worth holding
    /// the link for, because another one follows in 500 ms.
    func sendHeartbeatEA(_ bytes: [UInt8]) async throws
    var eaInbound: AsyncStream<[UInt8]> { get }
    /// Why the link stopped, once it has. Nil while it is alive.
    var end: LinkEnd? { get async }
    func close() async
}

extension IAP2Link: AccessoryLink {}

enum ConnectionState: Sendable, Equatable {
    case idle
    case connecting(attempt: Int)
    case ready
    case waitingToRetry(reason: FailureKind, attempt: Int, seconds: Int)
    case failed(FailureKind)

    var isReady: Bool { self == .ready }
}

enum SessionError: Error, Sendable, Equatable {
    case notReady
    case timeout
    case unavailable
    case outOfRange(UInt8, ClosedRange<UInt8>)
    case riskyWriteRefused
}

enum SessionEvent: Sendable {
    case state(ConnectionState)
    case identified(DeviceIdentity)
    case snapshot(AttributeSnapshot)
    case writeResult(Attr, Result<UInt8, SessionError>)
}

/// Owns the whole lifecycle: open the interface, bring the iAP2 link up,
/// identify, open the External Accessory session, then keep three loops running
/// — answer heartbeats, poll every attribute, and serve requests — until the
/// device goes away.
actor ReceiverSession {
    typealias LinkFactory = @Sendable () async throws -> any AccessoryLink
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private let makeLink: LinkFactory
    private let deviceEvents: AsyncStream<DeviceEvent>
    private let policy: ReconnectPolicy
    private let sleeper: Sleeper
    private let timings: Timings
    private var pollInterval: Duration

    /// Every delay the session takes, in one place. All of them go through
    /// `sleeper`, so a test can drive the whole state machine — backoff
    /// included — on a compressed clock without a single real-time wait.
    struct Timings: Sendable {
        /// The device ignores queries issued too soon after the session opens:
        /// at 1 s they go unanswered, at 1.5–2 s they work.
        var warmUp: Duration = .seconds(1)
        var heartbeat: Duration = .milliseconds(500)
        /// Generous on purpose. The receiver acknowledges lazily — it often
        /// piggybacks the acknowledgement on its next heartbeat rather than
        /// answering within its advertised 255 ms — so a link packet can sit
        /// for a second before the retransmission shakes an answer loose, and
        /// that second is spent before this request's frame even goes out.
        /// Measured round trips are 2–5 ms; this covers the stall, not the
        /// device.
        var request: Duration = .seconds(3)
        /// A `removed` immediately followed by an `arrived` is the receiver
        /// re-enumerating itself, not two events.
        var deviceDebounce: Duration = .seconds(1)
        var warmUpTick: Duration = .milliseconds(100)
    }

    private let eventStream: AsyncStream<SessionEvent>
    private let eventContinuation: AsyncStream<SessionEvent>.Continuation

    private var state: ConnectionState = .idle
    private var devicePresent = false
    private var isStopped = false
    private var hasGivenUp = false
    private var attempt = 0
    private var currentLink: (any AccessoryLink)?
    private var seq: UInt16 = 1
    private var snapshot = AttributeSnapshot()
    private var startInstant = ContinuousClock.now
    private var answeredDeviceHeartbeat = false
    private var consecutiveTimeouts = 0
    private var nextRequestID: UInt64 = 0

    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingRequest: PendingRequest?
    private var isRequesting = false
    private var requestLockWaiters: [CheckedContinuation<Void, Never>] = []
    private var debounceTask: Task<Void, Never>?

    /// A request in flight. It is registered *before* the frame goes out,
    /// because the receiver can answer faster than the link acknowledges the
    /// packet that asked — a reply that lands before the caller starts waiting
    /// is parked in `received` rather than dropped.
    private struct PendingRequest {
        /// Its own timer names it, so a timer left over from a request that has
        /// already been answered cannot expire the one after it.
        let id: UInt64
        let message: UInt16
        let attribute: UInt8?
        var continuation: CheckedContinuation<CFDFrame?, Never>?
        var received: CFDFrame?
        var isExpired = false

        func matches(_ frame: CFDFrame) -> Bool {
            guard frame.message == message else { return false }
            guard let attribute else { return true }
            // Attribute replies are [status, id, len, value…]; a status-1 reply
            // still names the attribute it is about.
            return frame.payload.count >= 2 && frame.payload[1] == attribute
        }
    }

    init(
        makeLink: @escaping LinkFactory,
        deviceEvents: AsyncStream<DeviceEvent>,
        policy: ReconnectPolicy = ReconnectPolicy(),
        pollInterval: Duration = .seconds(2),
        timings: Timings = Timings(),
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }
    ) {
        self.makeLink = makeLink
        self.deviceEvents = deviceEvents
        self.policy = policy
        self.pollInterval = pollInterval
        self.timings = timings
        self.sleeper = sleeper
        (eventStream, eventContinuation) = AsyncStream.makeStream(of: SessionEvent.self)
    }

    nonisolated var events: AsyncStream<SessionEvent> { eventStream }

    // MARK: - lifecycle

    /// The session's whole life. Returns when `shutdown()` is called.
    func run() async {
        let watcher = Task { [weak self] in
            guard let self else { return }
            for await event in self.deviceEvents {
                await self.deviceEvent(event)
            }
        }
        defer { watcher.cancel() }

        while !isStopped {
            guard devicePresent, !hasGivenUp else {
                await waitForResume()
                continue
            }

            publish(.state(.connecting(attempt: attempt + 1)))
            logger.notice("Connecting (attempt \(self.attempt + 1, privacy: .public))")

            var failure: FailureKind?
            var link: (any AccessoryLink)?
            do {
                link = try await makeLink()
                currentLink = link
                let identity = try await link!.open(
                    protocolName: BoyaDevice.externalAccessoryProtocol,
                    sessionID: 1,
                    timeout: .seconds(6)
                )
                publish(.identified(identity))
                resetForNewSession()
                publish(.state(.ready))
                logger.notice("Ready — \(identity.model ?? "receiver", privacy: .public) serial \(identity.serial ?? "?", privacy: .public)")
                failure = await runReady(link: link!)
            } catch {
                failure = Self.classify(error)
                logger.error("Connect failed: \(String(describing: error), privacy: .public) → \(String(describing: failure!), privacy: .public)")
            }

            // Cleared before the close, not after: a write that arrives while
            // the link is being torn down must not find one to write to.
            currentLink = nil
            await link?.close()
            failAnyPendingRequest()

            if isStopped { break }
            guard let failure else { continue }
            // A device that was pulled out is not a failure to retry. The
            // watcher's own removal is still a second away behind its debounce,
            // so the transport is what tells us first.
            if failure == .deviceRemoved || !devicePresent {
                logger.info("Device is gone — waiting for it to come back")
                devicePresent = false
                if state != .idle { publish(.state(.idle)) }
                attempt = 0
                continue
            }

            // `attempt` counts consecutive failures. Only a receiver that has
            // actually answered something resets it — see `pollLoop`.
            attempt += 1
            switch policy.decide(attempt: attempt, failure: failure) {
            case .retry(let delay):
                let seconds = Int(delay.components.seconds)
                logger.notice("\(failure.summary, privacy: .public) — retry \(self.attempt, privacy: .public) of \(self.policy.maxAttempts, privacy: .public) in \(seconds, privacy: .public)s")
                publish(.state(.waitingToRetry(reason: failure, attempt: attempt, seconds: seconds)))
                try? await sleeper(delay)
            case .giveUp:
                logger.error("Giving up after \(self.attempt, privacy: .public) connection attempts (\(self.policy.maxAttempts, privacy: .public) retries): \(failure.summary, privacy: .public)")
                hasGivenUp = true
                publish(.state(.failed(failure)))
            }
        }

        logger.notice("Session stopped")
        eventContinuation.finish()
    }

    /// Manual "Retry" from the popover after the policy gave up.
    func retryNow() {
        logger.info("Manual retry requested")
        hasGivenUp = false
        attempt = 0
        signalResume()
    }

    /// Wake-from-sleep check: one cheap read. If it does not come back the
    /// normal failure path takes over.
    func recheck() async {
        guard state.isReady, let link = currentLink else { return }
        logger.info("Rechecking the link after wake")
        let reply = try? await request(.getAttribute, payload: [Attr.noiseCancellation.rawValue], node: .settings, link: link)
        if reply == nil {
            logger.notice("Recheck got no answer — dropping the link so it can be rebuilt")
            await link.close()
        }
    }

    func setPollInterval(_ interval: Duration) {
        pollInterval = interval
        logger.info("Poll interval now \(Int(interval.components.seconds), privacy: .public)s")
    }

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        logger.notice("Shutting down")
        debounceTask?.cancel()
        await currentLink?.close()
        signalResume()
    }

    // MARK: - device events

    /// Settles for `timings.deviceDebounce` before acting, so a removal
    /// immediately followed by an arrival is one event rather than a reconnect
    /// storm.
    private func deviceEvent(_ event: DeviceEvent) {
        logger.info("Device event: \(String(describing: event), privacy: .public)")
        debounceTask?.cancel()
        let settle = timings.deviceDebounce
        let sleeper = sleeper
        debounceTask = Task { [weak self] in
            guard (try? await sleeper(settle)) != nil, !Task.isCancelled else { return }
            await self?.applyDeviceEvent(event)
        }
    }

    private func applyDeviceEvent(_ event: DeviceEvent) async {
        switch event {
        case .arrived:
            guard !devicePresent || !state.isReady else { return }
            devicePresent = true
            hasGivenUp = false
            attempt = 0
            signalResume()
        case .removed:
            devicePresent = false
            if state != .idle { publish(.state(.idle)) }
            await currentLink?.close()
        }
    }

    // MARK: - ready state

    /// The three loops that make up a live session. The first one to fail wins
    /// and its reason becomes the failure; the rest are cancelled with it.
    private func runReady(link: any AccessoryLink) async -> FailureKind? {
        let first = await withTaskGroup(of: FailureKind?.self) { group in
            group.addTask { await self.pump(link: link) }
            group.addTask { await self.heartbeatLoop(link: link) }
            group.addTask { await self.pollLoop(link: link) }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // Whichever loop noticed first, the link's own account of why it ended
        // is the authoritative one. A heartbeat failing with `notLinked` is a
        // symptom of the unplug, not a transport fault of its own, and letting
        // it win put a retry countdown on screen for a device that had been
        // pulled out.
        switch await link.end {
        case .reset: return .reset
        case .deviceRemoved: return .deviceRemoved
        case .transportEnded, .closed, .none: return first
        }
    }

    private func resetForNewSession() {
        startInstant = .now
        answeredDeviceHeartbeat = false
        consecutiveTimeouts = 0
        snapshot = AttributeSnapshot()
    }

    /// Reads the EA stream, rebuilds CFD frames and dispatches them. Ends when
    /// the link's inbound stream finishes, which is how a closed transport,
    /// an unplug and `shutdown()` all arrive here.
    private func pump(link: any AccessoryLink) async -> FailureKind? {
        var reassembler = CFDReassembler()
        for await chunk in link.eaInbound {
            for frame in reassembler.feed(chunk) {
                await dispatch(frame, link: link)
            }
        }
        // Whatever is waiting for a reply will never get one, and the task
        // group cannot unwind until it stops waiting — otherwise a dead pump
        // costs the whole request timeout before the reconnect even starts.
        expirePendingRequest()
        let end = await link.end
        logger.info("EA stream ended (\(String(describing: end), privacy: .public))")
        switch end {
        case .reset: return .reset
        case .deviceRemoved: return .deviceRemoved
        case .transportEnded, .closed, .none: return .transport
        }
    }

    private func dispatch(_ frame: CFDFrame, link: any AccessoryLink) async {
        // The router hands our own frames straight back with src unchanged.
        // Answering those means answering our own heartbeats, forever.
        guard frame.src == CFDLink.deviceNode else { return }

        if frame.isHeartbeat {
            if !answeredDeviceHeartbeat {
                logger.info("First device heartbeat from node (\(frame.node.chid, privacy: .public),\(frame.node.vid, privacy: .public),\(frame.node.pid, privacy: .public))")
            }
            answeredDeviceHeartbeat = true
            let reply = CFDLink.encode(
                message: .heartbeat,
                payload: CFDLink.heartbeatPayload(tick: tick()),
                node: frame.node,
                seq: nextSeq(),
                src: frame.dst,
                dst: frame.src,
                service: frame.service
            )
            try? await link.sendHeartbeatEA(reply)
            return
        }

        cfdLogger.debug("<- msg 0x\(String(frame.message, radix: 16), privacy: .public) \(frame.payload.hexString, privacy: .public)")
        guard var pending = pendingRequest, pending.matches(frame) else { return }
        if let continuation = pending.continuation {
            pendingRequest = nil
            continuation.resume(returning: frame)
        } else {
            pending.received = frame
            pendingRequest = pending
        }
    }

    private func heartbeatLoop(link: any AccessoryLink) async -> FailureKind? {
        while !Task.isCancelled {
            do {
                try await link.sendHeartbeatEA(CFDLink.encode(
                    message: .heartbeat,
                    payload: CFDLink.heartbeatPayload(tick: tick()),
                    seq: nextSeq()
                ))
            } catch {
                logger.error("Heartbeat failed: \(String(describing: error), privacy: .public)")
                return Self.classify(error)
            }
            guard (try? await sleeper(timings.heartbeat)) != nil else { return nil }
        }
        return nil
    }

    /// Polls every attribute. The first query waits for a device heartbeat to
    /// have been answered *and* for the warm-up to have passed — measured in
    /// sleeper ticks rather than wall-clock, so an injected clock controls it.
    private func pollLoop(link: any AccessoryLink) async -> FailureKind? {
        var waited = Duration.zero
        while !answeredDeviceHeartbeat || waited < timings.warmUp {
            guard !Task.isCancelled else { return nil }
            guard (try? await sleeper(timings.warmUpTick)) != nil else { return nil }
            waited += timings.warmUpTick
        }

        var isFirst = true
        while !Task.isCancelled {
            let issued = ContinuousClock.now
            let reply = try? await request(.getMany, payload: [0], node: .settings, link: link)
            if let reply {
                consecutiveTimeouts = 0
                // The reconnect bound is reset here rather than on `ready`. A
                // receiver that completes the handshake every time and then
                // answers nothing used to reset it on every connection and
                // cycle forever, which is the runaway loop the bound exists
                // to stop.
                attempt = 0
                if isFirst {
                    logger.notice("Warm-up: first reply after \((ContinuousClock.now - issued).milliseconds, privacy: .public)ms")
                    isFirst = false
                }
                let decoded = AttributeSnapshot(decoding: reply.payload)
                snapshot = decoded
                publish(.snapshot(decoded))
            } else {
                consecutiveTimeouts += 1
                logger.error("get_all timed out (\(self.consecutiveTimeouts, privacy: .public)/3)")
                if consecutiveTimeouts >= 3 { return .unresponsive }
            }
            guard (try? await sleeper(pollInterval)) != nil else { return nil }
        }
        return nil
    }

    // MARK: - requests

    /// One request in flight at a time, matched back to its reply by message id
    /// and — for single-attribute messages — by attribute id. Throws
    /// `.timeout` if nothing matching comes back in time.
    @discardableResult
    private func request(
        _ message: CFDMessage,
        payload: [UInt8],
        node: CFDNode,
        link: any AccessoryLink
    ) async throws -> CFDFrame {
        await acquireRequestLock()
        defer { releaseRequestLock() }

        let attribute: UInt8? = (message == .getAttribute || message == .setAttribute) ? payload.first : nil
        let frame = CFDLink.encode(message: message, payload: payload, node: node, seq: nextSeq())
        cfdLogger.debug("-> msg 0x\(String(message.rawValue, radix: 16), privacy: .public) \(payload.hexString, privacy: .public)")

        nextRequestID += 1
        let id = nextRequestID
        pendingRequest = PendingRequest(id: id, message: message.rawValue, attribute: attribute)
        let timeout = timings.request
        let sleeper = sleeper
        let timer = Task { [weak self] in
            guard (try? await sleeper(timeout)) != nil else { return }
            await self?.expirePendingRequest(id)
        }
        defer { timer.cancel() }

        do {
            try await link.sendEA(frame)
        } catch {
            pendingRequest = nil
            throw error
        }

        let reply = await withCheckedContinuation { (continuation: CheckedContinuation<CFDFrame?, Never>) in
            guard var pending = pendingRequest else {
                continuation.resume(returning: nil)
                return
            }
            if let received = pending.received {
                pendingRequest = nil
                continuation.resume(returning: received)
            } else if pending.isExpired {
                pendingRequest = nil
                continuation.resume(returning: nil)
            } else {
                pending.continuation = continuation
                pendingRequest = pending
            }
        }
        guard let reply else { throw SessionError.timeout }
        return reply
    }

    /// - Parameter id: which request to expire, or nil for whatever is pending.
    ///   A timer names its own request so that one left over from a request
    ///   that has already been answered cannot expire the next one.
    private func expirePendingRequest(_ id: UInt64? = nil) {
        guard var pending = pendingRequest, id == nil || pending.id == id else { return }
        if let continuation = pending.continuation {
            pendingRequest = nil
            continuation.resume(returning: nil)
        } else {
            // The send has not returned yet; mark it so the wait resolves
            // immediately instead of parking on a continuation nobody will
            // resume.
            pending.isExpired = true
            pendingRequest = pending
        }
    }

    private func failAnyPendingRequest() {
        expirePendingRequest()
    }

    private func acquireRequestLock() async {
        while isRequesting {
            await withCheckedContinuation { requestLockWaiters.append($0) }
        }
        isRequesting = true
    }

    private func releaseRequestLock() {
        isRequesting = false
        if !requestLockWaiters.isEmpty { requestLockWaiters.removeFirst().resume() }
    }

    // MARK: - writes

    /// Writes an ordinary setting, then reads it back. The read-back is what
    /// gets published — the UI never shows an optimistic value.
    func set(_ attr: Attr, to value: UInt8) async {
        guard !attr.isRisky else {
            logger.error("Refusing to write risky attribute \(attr.name, privacy: .public) through set()")
            publish(.writeResult(attr, .failure(.riskyWriteRefused)))
            return
        }
        await write(attr, value)
    }

    /// The Settings › Advanced path, behind a confirmation dialog. The popover
    /// never calls this.
    func setRisky(_ attr: Attr, to value: UInt8) async {
        logger.notice("Risky write: \(attr.name, privacy: .public) = \(value, privacy: .public)")
        guard attr.isRisky else {
            await write(attr, value)
            return
        }
        await perform(attr, value)
    }

    /// Risky attributes are *actions*, not settings. `rx_speaker` restarts the
    /// receiver and `rx_reset` wipes it, so the link usually dies between the
    /// command and any read-back — putting them through the ordinary
    /// set-then-read-back transaction reports a successful action as a timeout.
    ///
    /// The set reply's own status byte is the answer. Losing the link straight
    /// after is the action taking effect, not a failure, and the ordinary
    /// reconnect brings the receiver back.
    private func perform(_ attr: Attr, _ value: UInt8) async {
        if let range = attr.range, !range.contains(value) {
            logger.error("\(attr.name, privacy: .public) takes \(range.lowerBound, privacy: .public)…\(range.upperBound, privacy: .public), refused \(value, privacy: .public)")
            publish(.writeResult(attr, .failure(.outOfRange(value, range))))
            return
        }
        guard state.isReady, let link = currentLink else {
            publish(.writeResult(attr, .failure(.notReady)))
            return
        }

        guard let reply = try? await request(.setAttribute, payload: [attr.rawValue, 1, value], node: .settings, link: link) else {
            guard await link.end != nil else {
                logger.error("\(attr.name, privacy: .public) was not answered and the link is still up")
                publish(.writeResult(attr, .failure(.timeout)))
                return
            }
            logger.notice("\(attr.name, privacy: .public) took the link with it — that is the action working")
            publish(.writeResult(attr, .success(value)))
            return
        }

        // Unlike a setting, the reply's status is all there is: nothing can be
        // read back from a receiver that is restarting.
        let decoded = AttributeSnapshot(decoding: reply.payload)
        guard decoded.isAvailable else {
            logger.error("\(attr.name, privacy: .public) was refused (status \(decoded.status, privacy: .public))")
            publish(.writeResult(attr, .failure(.unavailable)))
            return
        }
        logger.notice("\(attr.name, privacy: .public) accepted")
        publish(.writeResult(attr, .success(value)))
    }

    private func write(_ attr: Attr, _ value: UInt8) async {
        if let range = attr.range, !range.contains(value) {
            logger.error("\(attr.name, privacy: .public) takes \(range.lowerBound, privacy: .public)…\(range.upperBound, privacy: .public), refused \(value, privacy: .public)")
            publish(.writeResult(attr, .failure(.outOfRange(value, range))))
            return
        }
        guard state.isReady, let link = currentLink else {
            publish(.writeResult(attr, .failure(.notReady)))
            return
        }

        logger.notice("Set \(attr.name, privacy: .public) = \(value, privacy: .public)")
        _ = try? await request(.setAttribute, payload: [attr.rawValue, 1, value], node: .settings, link: link)
        guard let readBack = try? await request(.getAttribute, payload: [attr.rawValue], node: .settings, link: link) else {
            logger.error("No read-back for \(attr.name, privacy: .public)")
            publish(.writeResult(attr, .failure(.timeout)))
            return
        }

        let decoded = AttributeSnapshot(decoding: readBack.payload)
        guard decoded.isAvailable, let confirmed = decoded.byte(attr) else {
            logger.error("\(attr.name, privacy: .public) is not available right now (status \(decoded.status, privacy: .public))")
            publish(.writeResult(attr, .failure(.unavailable)))
            return
        }
        snapshot = snapshot.merging(decoded)
        logger.notice("\(attr.name, privacy: .public) confirmed \(confirmed, privacy: .public)")
        publish(.writeResult(attr, .success(confirmed)))
        publish(.snapshot(snapshot))
    }

    /// Reads one attribute directly. Unlike a poll this carries the status
    /// byte, which is the only way to tell "not available right now" from
    /// "this model does not have it".
    func read(_ attr: Attr) async -> AttributeSnapshot? {
        await readRaw(attr.rawValue)
    }

    /// Reads by raw id, including ids `Attr` does not name — the only way to
    /// ask about an attribute this model is not supposed to have.
    func readRaw(_ id: UInt8) async -> AttributeSnapshot? {
        guard state.isReady, let link = currentLink else { return nil }
        guard let reply = try? await request(.getAttribute, payload: [id], node: .settings, link: link) else { return nil }
        return AttributeSnapshot(decoding: reply.payload)
    }

    /// Reads every attribute once, outside the poll loop. Used by `--probe`.
    func readAll() async -> AttributeSnapshot? {
        guard state.isReady, let link = currentLink else { return nil }
        guard let reply = try? await request(.getMany, payload: [0], node: .settings, link: link) else { return nil }
        return AttributeSnapshot(decoding: reply.payload)
    }

    // MARK: - plumbing

    /// The only way `state` changes. Publishing and recording used to be two
    /// steps, and they drifted: `state` was never set to `.connecting` at all,
    /// and stayed `.ready` right through the link being torn down.
    private func publish(_ event: SessionEvent) {
        if case .state(let new) = event { state = new }
        eventContinuation.yield(event)
    }

    private func nextSeq() -> UInt16 {
        seq = seq &+ 1
        return seq
    }

    /// Host uptime in milliseconds. `components.seconds * 1000` quantises this
    /// to a second, so consecutive beats 500 ms apart carried the same value —
    /// the exact mistake `Duration.milliseconds` exists to prevent.
    private func tick() -> UInt32 {
        UInt32(truncatingIfNeeded: (ContinuousClock.now - startInstant).milliseconds)
    }

    private func waitForResume() async {
        await withCheckedContinuation { resumeWaiters.append($0) }
    }

    private func signalResume() {
        let waiting = resumeWaiters
        resumeWaiters = []
        for waiter in waiting { waiter.resume() }
    }

    /// Which diagnosis the user and the log get. Internal so the mapping can be
    /// tested — it used to call a failed bulk write an exclusive-access
    /// problem, which sends anyone reading the log after the wrong thing.
    static func classify(_ error: any Error) -> FailureKind {
        switch error {
        case let link as IAP2Link.LinkError:
            switch link {
            case .noSYN: .noSYN
            case .noIdentification, .noProtocols, .protocolNotOffered: .noIdentification
            case .externalAccessoryRefused, .noSessions, .noSessionStatus, .synAckNotAcknowledged: .sessionRefused
            case .reset: .reset
            case .notLinked, .notAcknowledged: .transport
            }
        case let transport as USBTransport.TransportError:
            switch transport {
            // Nothing to open, or it would not open for us.
            case .deviceNotFound, .matchingFailed, .claimFailed: .claimFailed
            // Mid-session: the interface was ours and stopped working.
            case .writeFailed, .closed: .transport
            }
        default:
            .transport
        }
    }
}

extension Duration {
    /// Whole milliseconds. `components` splits a duration into seconds *and*
    /// attoseconds, so reading the attosecond part alone silently drops
    /// everything past a second — which logged a 1068 ms round trip as 68 ms.
    var milliseconds: Int {
        Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
