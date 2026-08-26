import Foundation
import IOKit
import IOUSBHost
import OSLog
import Synchronization

private let logger = Logger(subsystem: BoyaLog.subsystem, category: "USB")

/// `kIOMessageServiceIsTerminated` — the macro is `iokit_common_msg(0x010)`,
/// which Swift cannot import, so the value is spelled out.
private let serviceIsTerminated = UInt32(0xE000_0010)

/// Opens the receiver's iAP interface and turns its two bulk endpoints into a
/// byte pipe.
///
/// `IOUSBHost` is used rather than `libusb` because it takes the interface
/// without capturing the device: nothing re-enumerates, the receiver's USB
/// audio keeps working, and no root is needed. `accessoryd` opens the same
/// interface briefly at plug-in to run MFi authentication and then lets go, so
/// a claim within the first second or so can come back as
/// `kIOReturnExclusiveAccess` — that is what the reconnect backoff is for.
actor USBTransport: ByteTransport {
    enum TransportError: Error, Sendable {
        case deviceNotFound
        case matchingFailed(kern_return_t)
        /// The interface is published but would not open. `accessoryd` holds it
        /// for about a second after plug-in to run MFi authentication, so this
        /// is expected once per plug-in.
        case claimFailed(IOReturn)
        case writeFailed(IOReturn)
        case closed
    }

    private let interface: IOUSBHostInterface
    private let inPipe: IOUSBHostPipe
    private let outPipe: IOUSBHostPipe
    /// Kernel-backed and mapped into this process: `ioData(withCapacity:)`
    /// buffers are handed to the controller directly, where a plain
    /// `NSMutableData` has to be bounced for DMA.
    private let readBuffer: NSMutableData
    private let queue: DispatchQueue
    private let stream: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let terminated: TerminationFlag
    private var reader: BulkReader?
    private var isClosed = false

    /// Whether the device has gone, rather than the stream having been closed
    /// from this side.
    ///
    /// The interest handler is the documented signal and the cheap one, but on
    /// this receiver it never fires for a yank: the bulk read simply fails and
    /// the stream ends, with IOKit's own removal notification arriving tens of
    /// milliseconds later. So the registry is asked as well — an interface that
    /// is no longer published belongs to a device that is no longer there. It
    /// can still lag the yank by a moment, which is why `IAP2Link` looks twice.
    var wasTerminated: Bool {
        terminated.isSet || !USBTransport.interfaceIsPublished
    }

    /// Whether the iAP interface is still in the IORegistry. Quiet about a
    /// miss: on the teardown path a miss is the answer, not a failure.
    private static var interfaceIsPublished: Bool {
        guard let service = try? findInterfaceService(loggingMisses: false) else { return false }
        IOObjectRelease(service)
        return true
    }

    /// The IORegistry entry id of the interface we opened — logged either side
    /// of a session so an unexpected re-enumeration is obvious.
    nonisolated let registryID: UInt64

    init() throws {
        let service = try USBTransport.findInterfaceService()
        defer { IOObjectRelease(service) }

        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &entryID)
        registryID = entryID

        let queue = DispatchQueue(label: "com.bn-l.boya-manager.usb")
        self.queue = queue

        let (stream, continuation) = AsyncStream.makeStream(of: [UInt8].self)
        self.stream = stream
        self.continuation = continuation

        let terminated = TerminationFlag()
        self.terminated = terminated

        logger.info("Opening iAP interface, registry id 0x\(String(entryID, radix: 16), privacy: .public)")
        // Everything IOUSBHost throws while setting the interface up means the
        // same thing to the layer above — we did not get the interface — so it
        // is reported as such rather than as a generic transport error.
        do {
            let interface = try IOUSBHostInterface(
                __ioService: service,
                options: [],
                queue: queue
            ) { _, messageType, _ in
                logger.info("Interest message 0x\(String(messageType, radix: 16), privacy: .public)")
                if messageType == serviceIsTerminated {
                    logger.notice("Interface terminated — ending the inbound stream")
                    terminated.set()
                    continuation.finish()
                }
            }
            self.interface = interface
            inPipe = try interface.copyPipe(withAddress: BoyaDevice.bulkInEndpoint)
            outPipe = try interface.copyPipe(withAddress: BoyaDevice.bulkOutEndpoint)
            readBuffer = try interface.ioData(withCapacity: BoyaDevice.packetSize)
        } catch {
            logger.error("Could not open the iAP interface: \(error.localizedDescription, privacy: .public)")
            throw TransportError.claimFailed(IOReturn((error as NSError).code))
        }
        logger.notice("""
            iAP interface open (pipes 0x\(String(BoyaDevice.bulkOutEndpoint, radix: 16), privacy: .public)/\
            0x\(String(BoyaDevice.bulkInEndpoint, radix: 16), privacy: .public))
            """)
    }

    func inbound() -> AsyncStream<[UInt8]> {
        if reader == nil {
            let reader = BulkReader(pipe: inPipe, buffer: readBuffer, queue: queue, continuation: continuation)
            self.reader = reader
            reader.start()
        }
        return stream
    }

    /// One buffer per write, deliberately. `ioData(withCapacity:)` hands back
    /// kernel memory whose length *is* the transfer length and which the SDK
    /// documents as immutable — changing it throws — so a single reusable OUT
    /// buffer would either pad every packet with trailing junk or need a pool
    /// with in-flight bookkeeping. At roughly two writes a second the
    /// allocation is not worth either.
    func write(_ bytes: [UInt8]) async throws {
        guard !isClosed else { throw TransportError.closed }
        logger.debug("-> \(bytes.hexString, privacy: .public)")
        let data = try interface.ioData(withCapacity: bytes.count)
        bytes.withUnsafeBytes { source in
            guard let base = source.baseAddress else { return }
            data.replaceBytes(in: NSRange(location: 0, length: bytes.count), withBytes: base)
        }
        let buffer = DataBox(data)
        let pipe = outPipe
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            do {
                try pipe.enqueueIORequest(with: buffer.data, completionTimeout: 0.5) { status, _ in
                    // Keeps the buffer alive until the controller is done with it.
                    _ = buffer
                    if status == kIOReturnSuccess {
                        continuation.resume()
                    } else {
                        logger.error("Bulk write failed: 0x\(String(UInt32(bitPattern: status), radix: 16), privacy: .public)")
                        continuation.resume(throwing: TransportError.writeFailed(status))
                    }
                }
            } catch {
                logger.error("Bulk write could not be enqueued: \(error.localizedDescription, privacy: .public)")
                continuation.resume(throwing: error)
            }
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        // Order matters. The reader stops on the interface's own queue, so once
        // `stop()` returns no completion is running and none can enqueue
        // another request. Aborting then flushes whatever the controller still
        // holds, and the final barrier lets those abort completions run. Only
        // then is it safe to tear the interface down — destroying it with
        // callbacks still in flight corrupts the heap.
        //
        // The two `queue.sync` calls here block a cooperative thread, which is
        // normally a thing to avoid inside an actor. IOUSBHost gives no async
        // way to know its completions have drained, and this runs once per
        // session on the teardown path — never in a hot one.
        reader?.stop()
        reader = nil
        try? inPipe.__abort(with: .synchronous)
        try? outPipe.__abort(with: .synchronous)
        queue.sync {}
        continuation.finish()
        interface.destroy()
        logger.notice("iAP interface closed, registry id 0x\(String(self.registryID, radix: 16), privacy: .public)")
    }

    /// The `IOUSBHostInterface` service for our vendor/product on interface 1.
    ///
    /// The vendor/product/interface keys have to be nested under
    /// `IOPropertyMatch`. At the top level they are driver-personality keys, and
    /// `IOUSBHostInterface` does not answer them from an already-published nub —
    /// neither hand-rolled top-level keys nor `IOUSBHostInterface`'s own
    /// `createMatchingDictionary` match anything here, they just return an empty
    /// iterator. (`IOUSBHostDevice` *does* answer them, which is why
    /// `DeviceWatcher` gets away with the plain form.)
    private static func findInterfaceService(loggingMisses: Bool = true) throws -> io_service_t {
        guard let matching = IOServiceMatching("IOUSBHostInterface") else {
            throw TransportError.deviceNotFound
        }
        let criteria = matching as NSMutableDictionary
        criteria[kIOPropertyMatchKey] = [
            "idVendor": BoyaDevice.vendorID,
            "idProduct": BoyaDevice.productID,
            "bInterfaceNumber": BoyaDevice.interfaceNumber,
        ] as NSDictionary

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, criteria, &iterator)
        guard result == KERN_SUCCESS else {
            logger.error("IOServiceGetMatchingServices failed: 0x\(String(UInt32(bitPattern: result), radix: 16), privacy: .public)")
            throw TransportError.matchingFailed(result)
        }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != IO_OBJECT_NULL else {
            if loggingMisses {
                logger.error("No iAP interface found for \(String(format: "%04x:%04x", BoyaDevice.vendorID, BoyaDevice.productID), privacy: .public)")
            }
            throw TransportError.deviceNotFound
        }
        return service
    }
}

/// Keeps exactly one 64-byte read outstanding on the IN pipe and yields each
/// completion into the stream.
///
/// Never reads more than `wMaxPacketSize` per request: with a larger buffer a
/// short packet ends the transfer and any tail already in the controller's
/// queue is lost, which would tear frames in half. Completions arrive on the
/// interface's serial dispatch queue, so yielding straight into the stream
/// continuation preserves packet order — hopping onto an actor here would not.
private final class BulkReader: @unchecked Sendable {
    private let pipe: IOUSBHostPipe
    private let buffer: NSMutableData
    private let queue: DispatchQueue
    private let continuation: AsyncStream<[UInt8]>.Continuation
    /// Only ever touched on `queue`, which is also where completions arrive —
    /// so there is no window where a stopped reader can still enqueue.
    private var isRunning = false

    init(pipe: IOUSBHostPipe, buffer: NSMutableData, queue: DispatchQueue, continuation: AsyncStream<[UInt8]>.Continuation) {
        self.pipe = pipe
        self.buffer = buffer
        self.queue = queue
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            isRunning = true
            enqueue()
        }
    }

    /// Returns once the reader is quiet: it runs on the interface's queue, so
    /// any completion already in flight has finished by the time this returns.
    func stop() {
        queue.sync { isRunning = false }
    }

    private func enqueue() {
        guard isRunning else { return }
        do {
            try pipe.enqueueIORequest(with: buffer, completionTimeout: 0) { [weak self] status, transferred in
                guard let self else { return }
                guard status == kIOReturnSuccess else {
                    // Aborted is the normal shutdown path; anything else is the
                    // device going away underneath us. This already runs on the
                    // reader's queue, so it clears the flag directly — calling
                    // `stop()` here would deadlock on its own queue.
                    if status != kIOReturnAborted {
                        logger.error("Bulk read failed: 0x\(String(UInt32(bitPattern: status), radix: 16), privacy: .public)")
                    }
                    isRunning = false
                    continuation.finish()
                    return
                }
                let count = min(transferred, buffer.length)
                if count > 0 {
                    let bytes = [UInt8](Data(bytes: buffer.bytes, count: count))
                    logger.debug("<- \(bytes.hexString, privacy: .public)")
                    continuation.yield(bytes)
                }
                enqueue()
            }
        } catch {
            logger.error("Bulk read could not be enqueued: \(error.localizedDescription, privacy: .public)")
            isRunning = false
            continuation.finish()
        }
    }
}

/// Set from the interface's interest handler, which runs on the interface's
/// dispatch queue, and read from the actor — so a lock rather than actor state.
/// `Mutex` is non-copyable, hence the class around it; in exchange the whole
/// thing is `Sendable` on its own terms rather than by assertion.
private final class TerminationFlag: Sendable {
    private let value = Mutex(false)

    var isSet: Bool { value.withLock { $0 } }

    func set() { value.withLock { $0 = true } }
}

/// Carries an `NSMutableData` across the concurrency boundary into an
/// `IOUSBHost` completion block. The buffer is handed to the controller and not
/// touched again until the completion fires, so the unchecked conformance is
/// exactly as safe as the USB API itself.
private final class DataBox: @unchecked Sendable {
    let data: NSMutableData

    init(_ data: NSMutableData) { self.data = data }
}
