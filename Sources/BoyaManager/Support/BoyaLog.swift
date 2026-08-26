import Foundation

/// One subsystem for the whole app, so `just log` (or
/// `log stream --predicate 'subsystem=="com.bn-l.boya-manager"'`) shows every
/// layer at once. Categories: `USB`, `IAP2`, `CFD`, `Session`, `UI`, `Icon`.
enum BoyaLog {
    static let subsystem = "com.bn-l.boya-manager"

    static var streamCommand: String {
        "log stream --predicate 'subsystem==\"\(subsystem)\"' --level debug"
    }
}

/// The receiver, as USB sees it.
enum BoyaDevice {
    static let vendorID = 0x2F05
    static let productID = 0x003B
    /// "iAP Interface", class 0xFF / subclass 0xF0. No macOS driver binds it,
    /// so it opens as a normal user and the receiver's USB audio stays put.
    static let interfaceNumber = 1
    static let bulkOutEndpoint = 0x01
    static let bulkInEndpoint = 0x81
    static let packetSize = 64
    static let externalAccessoryProtocol = "BOYA.DeviceLink.com"
}
