import Foundation
import IOKit
import OSLog

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "Session")

/// `BoyaManager --probe` — the whole stack from a terminal, no UI: watch for
/// the device, open the interface, bring up iAP2, open the EA session, print
/// every attribute the receiver reports, then close cleanly.
///
/// The registry entry id is printed either side so an unexpected
/// re-enumeration (which is what a botched iAP2 handshake causes) is obvious
/// without reaching for `ioreg`.
enum Probe {
    static func run(reading attribute: UInt8? = nil) {
        let finished = DispatchSemaphore(value: 0)
        Task {
            await execute(reading: attribute)
            finished.signal()
        }
        finished.wait()
    }

    /// Resolves the name `boyactl.py` uses, or a raw id. Raw ids are accepted
    /// even when `Attr` does not name them, which is how an attribute this
    /// model is not supposed to have can still be asked about.
    static func attribute(named token: String) -> UInt8? {
        if let match = Attr.allCases.first(where: { $0.name == token }) { return match.rawValue }
        return UInt8(token)
    }

    private static func execute(reading attribute: UInt8? = nil) async {
        print("BOYA mini 2 probe — \(BoyaDevice.externalAccessoryProtocol)")
        print("device registry id before: \(registryID() ?? "not present")")

        let watcher = DeviceWatcher()
        await watcher.start()

        let session = ReceiverSession(
            makeLink: { IAP2Link(transport: try USBTransport()) },
            deviceEvents: watcher.events
        )
        let running = Task { await session.run() }
        let watchdog = Task {
            // `try?` alone would swallow the cancellation error and fall
            // through to the timeout message on a *successful* run.
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            print("timed out waiting for a snapshot")
            await session.shutdown()
        }

        for await event in session.events {
            switch event {
            case .state(let state):
                print("state: \(state)")
            case .identified(let identity):
                print("""
                    identity: \(identity.model ?? "?") \
                    serial \(identity.serial ?? "?") \
                    firmware \(identity.firmware ?? "?") \
                    protocols \(identity.protocols.map { "\($0.id):\($0.name)" }.joined(separator: ", "))
                    """)
            case .snapshot(let snapshot):
                report(snapshot)
                // A direct read shows the status byte, which `get_all` hides:
                // an attribute missing from the dump could be unavailable or
                // simply not implemented, and only `0x1F` tells them apart.
                if let attribute, let reply = await session.readRaw(attribute) {
                    let name = Attr(rawValue: attribute)
                    let value = reply.values[attribute]
                    let shown = value.map { name?.describe($0) ?? $0.hexString } ?? "—"
                    print("get \(name?.name ?? String(attribute)): status \(reply.status), value \(shown)\n")
                }
                watchdog.cancel()
                await session.shutdown()
            case .writeResult:
                break
            }
        }

        watchdog.cancel()
        running.cancel()
        await watcher.stop()
        // Give the interface a moment to settle before checking for a
        // re-enumeration.
        try? await Task.sleep(for: .milliseconds(500))
        print("device registry id after:  \(registryID() ?? "not present")")
    }

    private static func report(_ snapshot: AttributeSnapshot) {
        print("\nstatus \(snapshot.status) — \(snapshot.values.count) attributes")
        for entry in snapshot.sortedEntries {
            let name = (entry.attr?.name ?? "?").padding(toLength: 22, withPad: " ", startingAt: 0)
            let value = entry.attr?.describe(entry.value) ?? entry.value.hexString
            print(String(format: "%3d  0x%02X  ", Int(entry.id), Int(entry.id)) + name + " " + value)
        }
        print("")
    }

    /// The receiver's `IOUSBHostDevice` registry entry id, as hex.
    private static func registryID() -> String? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        let criteria = matching as NSMutableDictionary
        criteria["idVendor"] = BoyaDevice.vendorID
        criteria["idProduct"] = BoyaDevice.productID

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, criteria, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        return "0x" + String(entryID, radix: 16)
    }
}
