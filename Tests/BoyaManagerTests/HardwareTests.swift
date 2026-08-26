import Foundation
import IOKit
import Testing
@testable import BoyaManager

/// The real thing. Opt in with `BOYA_HARDWARE=1 swift test --filter HardwareTests`
/// and a receiver plugged in. Enabled without a device, these hard-fail rather
/// than skip — a green run has to mean the device answered.
@Suite(
    "Against a real receiver",
    .enabled(if: ProcessInfo.processInfo.environment["BOYA_HARDWARE"] != nil),
    .serialized
)
struct HardwareTests {
    /// The serial printed by `IdentificationInformation` on the unit this was
    /// developed against. Override for a different receiver.
    private var expectedSerial: String {
        ProcessInfo.processInfo.environment["BOYA_SERIAL"] ?? "CFD7387E79"
    }

    private func registryID() throws -> UInt64 {
        let matching = try #require(IOServiceMatching("IOUSBHostDevice"))
        let criteria = matching as NSMutableDictionary
        criteria["idVendor"] = BoyaDevice.vendorID
        criteria["idProduct"] = BoyaDevice.productID

        var iterator: io_iterator_t = 0
        #expect(IOServiceGetMatchingServices(kIOMainPortDefault, criteria, &iterator) == KERN_SUCCESS)
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        try #require(service != IO_OBJECT_NULL, "no BOYA mini 2 on USB — plug the receiver in")
        defer { IOObjectRelease(service) }

        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        return entryID
    }

    /// Opens the interface, runs `body` against a ready session, then closes
    /// cleanly. The session is the real one, so this exercises exactly what the
    /// app does.
    private func withReadySession(_ body: @Sendable (ReceiverSession, SessionRecorder) async throws -> Void) async throws {
        let watcher = DeviceWatcher()
        await watcher.start()
        let recorder = SessionRecorder()
        let session = ReceiverSession(
            makeLink: { IAP2Link(transport: try USBTransport()) },
            deviceEvents: watcher.events
        )
        await recorder.consume(session)
        let running = Task { await session.run() }

        let ready = await recorder.wait(timeout: .seconds(25)) { events in
            events.contains { if case .state(.ready) = $0 { true } else { false } }
        }
        guard ready else {
            await session.shutdown()
            await watcher.stop()
            running.cancel()
            Issue.record("the receiver never reached ready — check it is plugged in and awake")
            return
        }

        do {
            try await body(session, recorder)
        } catch {
            await session.shutdown()
            await watcher.stop()
            running.cancel()
            throw error
        }
        await session.shutdown()
        await watcher.stop()
        running.cancel()
    }

    @Test("The iAP interface opens as a normal user without capturing the device")
    func opensInterface() async throws {
        let before = try registryID()

        let transport = try USBTransport()
        #expect(transport.registryID != 0)
        await transport.close()

        try await Task.sleep(for: .milliseconds(500))
        #expect(try registryID() == before, "the receiver re-enumerated — the session was not closed cleanly")
    }

    @Test("The handshake identifies this receiver")
    func identity() async throws {
        try await withReadySession { _, recorder in
            let identity = try #require(await recorder.identities.first)

            #expect(identity.model == "BOYA mini 2")
            #expect(identity.serial == expectedSerial)
            #expect(identity.protocols.contains { $0.name == BoyaDevice.externalAccessoryProtocol })
        }
    }

    @Test("A poll returns the attributes this model implements")
    func readsAttributes() async throws {
        try await withReadySession { _, recorder in
            let snapshot = try #require(await recorder.waitForSnapshot(), "no attribute dump arrived")

            #expect(snapshot.values.count >= 20)
            #expect(snapshot.byte(.noiseCancellation) != nil)
            #expect(snapshot.byte(.rxGain) != nil)
            #expect(snapshot.byte(.rxBattery) != nil)
            for id in snapshot.values.keys {
                #expect(Attr(rawValue: id) != nil, "unknown attribute id \(id) — the table needs updating")
            }
        }
    }

    /// Writes `attr` to a different value, checks the read-back, then puts it
    /// back — the device must be left exactly as it was found.
    private func roundTrip(_ attr: Attr, other: @escaping @Sendable (UInt8) -> UInt8) async throws {
        try await withReadySession { session, recorder in
            let snapshot = try #require(await recorder.waitForSnapshot())
            let original = try #require(snapshot.byte(attr), "\(attr.name) was not reported")
            let changed = other(original)

            await session.set(attr, to: changed)
            let written = try #require(await recorder.writeResult(for: attr, number: 1))
            #expect(try written.get() == changed)

            await session.set(attr, to: original)
            let restored = try #require(await recorder.writeResult(for: attr, number: 2))
            #expect(try restored.get() == original, "the device was left on the wrong setting")
        }
    }

    @Test("Noise cancellation can be written and reads back, then is restored")
    func writesNoiseCancellation() async throws {
        try await roundTrip(.noiseCancellation) { $0 == 0 ? 1 : 0 }
    }

    @Test("Output gain can be written and reads back, then is restored")
    func writesGain() async throws {
        try await roundTrip(.rxGain) { $0 == 6 ? 5 : $0 + 1 }
    }

    @Test("Scene mode can be written and reads back, then is restored")
    func writesSceneMode() async throws {
        try await roundTrip(.sceneMode) { $0 == 0 ? 1 : 0 }
    }

    @Test("Recording mode can be written and reads back, then is restored")
    func writesRecordingMode() async throws {
        try await roundTrip(.recordingMode) { $0 == 0 ? 1 : 0 }
    }

    @Test("Transmitter auto power-off can be written and reads back, then is restored")
    func writesTransmitterAutoPowerOff() async throws {
        try await roundTrip(.txAutoPowerOff) { $0 == 0 ? 1 : 0 }
    }

    /// `agc` (46) is in BOYA's per-model metadata for the mini 2 but the
    /// receiver never answers for it — `get_all` omits it and a direct `0x1F`
    /// read returns status 1 even with a transmitter online and healthy. It is
    /// not in `Attr` for that reason; this pins the behaviour so a firmware
    /// update that starts answering shows up here rather than silently.
    @Test("Attribute 46 still answers status 1 — it is not on this model")
    func attributeFortySixIsNotImplemented() async throws {
        try await withReadySession { session, _ in
            let direct = try #require(await session.readRaw(46), "no answer to a direct read of 46")

            #expect(direct.status == 1)
            #expect(direct.values[46] == nil)
        }
    }

    @Test("A whole session leaves the device exactly where it found it")
    func sessionDoesNotReEnumerate() async throws {
        let before = try registryID()

        try await withReadySession { _, recorder in
            _ = await recorder.wait(timeout: .seconds(15)) { events in
                events.contains { if case .snapshot = $0 { true } else { false } }
            }
        }

        try await Task.sleep(for: .seconds(1))
        #expect(try registryID() == before, "the receiver re-enumerated during or after the session")
    }
}
