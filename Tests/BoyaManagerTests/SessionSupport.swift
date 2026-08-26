import Foundation
@testable import BoyaManager

/// Records everything a session publishes and lets a test wait for a condition
/// over the whole history. One recorder per session — `events` is a single
/// consumer stream, so two readers would steal each other's events.
actor SessionRecorder {
    private(set) var events: [SessionEvent] = []
    private var consumer: Task<Void, Never>?
    private var waiters: [UUID: (check: @Sendable ([SessionEvent]) -> Bool, continuation: CheckedContinuation<Bool, Never>)] = [:]

    func consume(_ session: ReceiverSession) {
        consumer = Task { [weak self] in
            for await event in session.events {
                await self?.append(event)
            }
        }
    }

    func stop() {
        consumer?.cancel()
        consumer = nil
    }

    private func append(_ event: SessionEvent) {
        events.append(event)
        for (id, waiter) in waiters where waiter.check(events) {
            waiters.removeValue(forKey: id)
            waiter.continuation.resume(returning: true)
        }
    }

    /// Resolves as soon as the recorded history satisfies `check`, or false when
    /// `timeout` elapses first.
    @discardableResult
    func wait(timeout: Duration = .seconds(10), until check: @escaping @Sendable ([SessionEvent]) -> Bool) async -> Bool {
        if check(events) { return true }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expire(id)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            waiters[id] = (check, continuation)
        }
    }

    private func expire(_ id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(returning: false)
    }

    var states: [ConnectionState] {
        events.compactMap { if case .state(let state) = $0 { return state } else { return nil } }
    }

    var snapshots: [AttributeSnapshot] {
        events.compactMap { if case .snapshot(let snapshot) = $0 { return snapshot } else { return nil } }
    }

    var identities: [DeviceIdentity] {
        events.compactMap { if case .identified(let identity) = $0 { return identity } else { return nil } }
    }

    var writeResults: [(attr: Attr, result: Result<UInt8, SessionError>)] {
        events.compactMap { if case .writeResult(let attr, let result) = $0 { return (attr, result) } else { return nil } }
    }

    /// Waits for the `number`-th (1-based) write result for `attr` and returns
    /// it. Reading `writeResults` straight after a `set` races the recorder's
    /// own consumer task.
    func writeResult(for attr: Attr, number: Int = 1, timeout: Duration = .seconds(15)) async -> Result<UInt8, SessionError>? {
        let arrived = await wait(timeout: timeout) { events in
            events.count { if case .writeResult(let written, _) = $0 { written == attr } else { false } } >= number
        }
        guard arrived else { return nil }
        let all = writeResults.filter { $0.attr == attr }
        return all.count >= number ? all[number - 1].result : nil
    }

    func waitForSnapshot(timeout: Duration = .seconds(15)) async -> AttributeSnapshot? {
        let arrived = await wait(timeout: timeout) { events in
            events.contains { if case .snapshot = $0 { true } else { false } }
        }
        return arrived ? snapshots.last : nil
    }

    var connectAttempts: [Int] {
        states.compactMap { if case .connecting(let attempt) = $0 { return attempt } else { return nil } }
    }

    var reachedReady: Bool { states.contains(.ready) }
}

/// Records every delay the session asks for, then takes a hundredth of it.
/// The recorded values are the real ones, so a test can assert the backoff is
/// 1/2/4/8/16 seconds without waiting 31 of them.
actor Clock {
    private(set) var requested: [Duration] = []
    /// Delays shorter than this are not recorded — heartbeat and warm-up ticks
    /// would otherwise bury the interesting ones.
    private let noiseFloor: Duration

    init(ignoringBelow noiseFloor: Duration = .milliseconds(600)) {
        self.noiseFloor = noiseFloor
    }

    private func record(_ duration: Duration) {
        guard duration >= noiseFloor else { return }
        requested.append(duration)
    }

    nonisolated func sleeper() -> ReceiverSession.Sleeper {
        { [self] duration in
            await record(duration)
            // A tenth of real time: long enough for the fake accessory to
            // answer, short enough that a five-step backoff is three seconds.
            let nanoseconds = duration.components.seconds * 100_000_000
                + duration.components.attoseconds / 10_000_000_000
            try await Task.sleep(for: .nanoseconds(max(1, nanoseconds)))
        }
    }
}

/// A session wired to a scripted accessory, with the device already "present".
@MainActor
struct SessionHarness {
    let session: ReceiverSession
    let recorder: SessionRecorder
    let clock: Clock
    private let deviceContinuation: AsyncStream<DeviceEvent>.Continuation
    private let runTask: Task<Void, Never>

    init(
        makeLink: @escaping ReceiverSession.LinkFactory,
        policy: ReconnectPolicy = ReconnectPolicy(),
        timings: ReceiverSession.Timings = ReceiverSession.Timings(),
        pollInterval: Duration = .seconds(1),
        clock: Clock = Clock()
    ) async {
        let (events, continuation) = AsyncStream.makeStream(of: DeviceEvent.self)
        deviceContinuation = continuation
        self.clock = clock
        session = ReceiverSession(
            makeLink: makeLink,
            deviceEvents: events,
            policy: policy,
            pollInterval: pollInterval,
            timings: timings,
            sleeper: clock.sleeper()
        )
        recorder = SessionRecorder()
        await recorder.consume(session)
        runTask = Task { [session] in await session.run() }
    }

    func send(_ event: DeviceEvent) {
        deviceContinuation.yield(event)
    }

    func finish() async {
        await session.shutdown()
        await recorder.stop()
        deviceContinuation.finish()
        runTask.cancel()
    }
}
