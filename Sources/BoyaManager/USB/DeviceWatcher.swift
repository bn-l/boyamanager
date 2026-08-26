import Foundation
import IOKit
import IOKit.usb
import OSLog

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "USB")

enum DeviceEvent: Sendable, Equatable {
    case arrived
    case removed
}

/// Watches IOKit for the receiver appearing and disappearing.
///
/// `kIOFirstMatchNotification` also delivers whatever already matches when the
/// iterator is first drained, so a device present at launch shows up as
/// `.arrived` with no special case.
actor DeviceWatcher {
    private let stream: AsyncStream<DeviceEvent>
    private let continuation: AsyncStream<DeviceEvent>.Continuation
    private let queue = DispatchQueue(label: "com.bn-l.boya-manager.watcher")
    private var notifyPort: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private var contexts: [Unmanaged<WatcherContext>] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: DeviceEvent.self)
    }

    nonisolated var events: AsyncStream<DeviceEvent> { stream }

    func start() {
        guard notifyPort == nil else { return }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            logger.error("IONotificationPortCreate failed — device arrival will not be detected")
            return
        }
        notifyPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        add(notificationType: kIOFirstMatchNotification, event: .arrived)
        add(notificationType: kIOTerminatedNotification, event: .removed)
        logger.info("Watching for \(String(format: "%04x:%04x", BoyaDevice.vendorID, BoyaDevice.productID), privacy: .public)")
    }

    func stop() {
        // The port goes first. Releasing a callback's context while the port
        // can still deliver to it hands IOKit a pointer to freed memory.
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
        for iterator in iterators { IOObjectRelease(iterator) }
        iterators = []
        for context in contexts { context.release() }
        contexts = []
        continuation.finish()
    }

    private func add(notificationType: String, event: DeviceEvent) {
        guard let notifyPort else { return }
        guard let matching = IOServiceMatching(kIOUSBHostDeviceClassName) else { return }
        let criteria = matching as NSMutableDictionary
        criteria["idVendor"] = BoyaDevice.vendorID
        criteria["idProduct"] = BoyaDevice.productID

        let context = WatcherContext(event: event, continuation: continuation)
        let retained = Unmanaged.passRetained(context)
        var iterator: io_iterator_t = 0
        let result = IOServiceAddMatchingNotification(
            notifyPort,
            notificationType,
            criteria,
            { pointer, iterator in
                guard let pointer else { return }
                Unmanaged<WatcherContext>.fromOpaque(pointer).takeUnretainedValue().fire(draining: iterator)
            },
            retained.toOpaque(),
            &iterator
        )
        guard result == KERN_SUCCESS else {
            logger.error("IOServiceAddMatchingNotification(\(notificationType, privacy: .public)) failed: 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
            retained.release()
            return
        }
        contexts.append(retained)
        iterators.append(iterator)
        // Arm the notification. This also reports anything already present.
        context.fire(draining: iterator)
    }
}

/// The `void*` refcon handed to IOKit's C callback.
private final class WatcherContext: @unchecked Sendable {
    private let event: DeviceEvent
    private let continuation: AsyncStream<DeviceEvent>.Continuation

    init(event: DeviceEvent, continuation: AsyncStream<DeviceEvent>.Continuation) {
        self.event = event
        self.continuation = continuation
    }

    /// The iterator must be drained to completion or the notification never
    /// fires again.
    func fire(draining iterator: io_iterator_t) {
        var matched = 0
        while case let service = IOIteratorNext(iterator), service != IO_OBJECT_NULL {
            matched += 1
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            logger.notice("Device \(String(describing: self.event), privacy: .public), registry id 0x\(String(entryID, radix: 16), privacy: .public)")
            IOObjectRelease(service)
        }
        guard matched > 0 else { return }
        continuation.yield(event)
    }
}
