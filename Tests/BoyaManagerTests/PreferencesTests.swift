@testable import BoyaManager
import Foundation
import Testing

@Suite("Preferences")
@MainActor
struct PreferencesTests {
    /// A throwaway defaults domain per test, so nothing touches the real one.
    private func scratchDefaults() -> UserDefaults {
        scratchUserDefaults()
    }

    @Test("Defaults are the ones the app ships with")
    func defaults() {
        let preferences = Preferences(defaults: scratchDefaults())

        #expect(preferences.notificationsEnabled)
        #expect(preferences.notifyLowBattery)
        #expect(preferences.notifyTransmitterPresence)
        #expect(preferences.notifyReceiverDisconnected)
    }

    @Test("Every setting survives a restart")
    func roundTrip() {
        let defaults = scratchDefaults()
        let first = Preferences(defaults: defaults)

        first.notificationsEnabled = false
        first.notifyLowBattery = false
        first.notifyTransmitterPresence = false
        first.notifyReceiverDisconnected = false

        let second = Preferences(defaults: defaults)
        #expect(!second.notificationsEnabled)
        #expect(!second.notifyLowBattery)
        #expect(!second.notifyTransmitterPresence)
        #expect(!second.notifyReceiverDisconnected)
    }

    @Test("`false` persists as itself rather than falling back to the default")
    func falseIsNotTreatedAsMissing() {
        let defaults = scratchDefaults()
        Preferences(defaults: defaults).notificationsEnabled = false

        #expect(!Preferences(defaults: defaults).notificationsEnabled)
    }

    @Test("A nonsense stored value falls back rather than crashing")
    func unknownStoredValue() {
        let defaults = scratchDefaults()
        defaults.set("somethingElse", forKey: "notifyLowBattery")

        #expect(Preferences(defaults: defaults).notifyLowBattery)
    }

    @Test("Two preference objects on different domains do not see each other")
    func domainsAreIsolated() {
        let first = Preferences(defaults: scratchDefaults())
        let second = Preferences(defaults: scratchDefaults())

        first.notifyLowBattery = false

        #expect(second.notifyLowBattery)
    }

    /// `SMAppServiceStatusRequiresApproval` means registration worked but the
    /// user has to confirm it in System Settings. Collapsing it to "off" made
    /// the toggle read off after a successful register, and every attempt to
    /// switch it on again threw `kSMErrorAlreadyRegistered` and snapped back.
    @Test("Registration that lands in needs-approval is not reported as off")
    func registrationAwaitingApproval() {
        let items = FakeLoginItems()
        items.registerResult = .needsApproval
        let preferences = Preferences(defaults: scratchDefaults(), loginItems: items)

        preferences.launchAtLogin = true

        #expect(preferences.loginItem == .needsApproval)
        #expect(preferences.launchAtLogin, "the user asked for it and it registered — that is not off")
    }

    @Test("A needs-approval login item is still needs-approval on the next launch")
    func approvalStateSurvivesRestart() {
        let items = FakeLoginItems()
        items.state = .needsApproval

        let preferences = Preferences(defaults: scratchDefaults(), loginItems: items)

        #expect(preferences.loginItem == .needsApproval)
        #expect(preferences.launchAtLogin)
    }

    @Test("Toggling on something already registered does not snap the toggle back")
    func alreadyRegisteredDoesNotSnapBack() {
        struct AlreadyRegistered: Error {}
        let items = FakeLoginItems()
        items.state = .needsApproval
        items.registerError = AlreadyRegistered()
        let preferences = Preferences(defaults: scratchDefaults(), loginItems: items)

        preferences.launchAtLogin = true

        #expect(items.registerCount == 1)
        #expect(preferences.loginItem == .needsApproval, "the registry still says it is registered")
    }

    @Test("Switching it off unregisters and reports off")
    func unregister() {
        let items = FakeLoginItems()
        items.state = .on
        let preferences = Preferences(defaults: scratchDefaults(), loginItems: items)

        preferences.launchAtLogin = false

        #expect(items.unregisterCount == 1)
        #expect(preferences.loginItem == .off)
        #expect(!preferences.launchAtLogin)
    }

    @Test("Consent revoked in System Settings is picked up on the next look")
    func revokedConsentIsNoticed() {
        let items = FakeLoginItems()
        items.state = .on
        let preferences = Preferences(defaults: scratchDefaults(), loginItems: items)
        #expect(preferences.launchAtLogin)

        items.state = .needsApproval
        preferences.refreshLoginItem()

        #expect(preferences.loginItem == .needsApproval)
    }
}

/// The login-item registry, without the system daemon behind it.
@MainActor
final class FakeLoginItems: LoginItemStore {
    var state: LoginItemState = .off
    /// What a successful `register()` leaves behind. macOS returns
    /// `requiresApproval` when the user has yet to confirm it.
    var registerResult: LoginItemState = .on
    var registerError: (any Error)?
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    private(set) var openedSettings = 0

    func register() throws {
        registerCount += 1
        if let registerError { throw registerError }
        state = registerResult
    }

    func unregister() {
        unregisterCount += 1
        state = .off
    }

    func openSettings() { openedSettings += 1 }
}
