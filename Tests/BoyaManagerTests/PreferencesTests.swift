import Foundation
import Testing
@testable import BoyaManager

@Suite("Preferences")
@MainActor
struct PreferencesTests {
    /// A throwaway defaults domain per test, so nothing touches the real one.
    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "boya-manager-tests-\(UUID().uuidString)")!
    }

    @Test("Defaults are the ones the app ships with")
    func defaults() {
        let preferences = Preferences(defaults: scratchDefaults())

        #expect(preferences.pollSeconds == 2)
        #expect(preferences.lowBatteryThreshold == 1)
        #expect(preferences.iconSource == .lowestOnline)
        #expect(preferences.notificationsEnabled)
        #expect(preferences.notifyLowBattery)
        #expect(preferences.notifyTransmitterPresence)
        #expect(preferences.notifyReceiverDisconnected)
    }

    @Test("Every setting survives a restart")
    func roundTrip() {
        let defaults = scratchDefaults()
        let first = Preferences(defaults: defaults)

        first.pollSeconds = 5
        first.lowBatteryThreshold = 2
        first.iconSource = .transmitter2
        first.notificationsEnabled = false
        first.notifyLowBattery = false
        first.notifyTransmitterPresence = false
        first.notifyReceiverDisconnected = false

        let second = Preferences(defaults: defaults)
        #expect(second.pollSeconds == 5)
        #expect(second.lowBatteryThreshold == 2)
        #expect(second.iconSource == .transmitter2)
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

    @Test("A nonsense stored icon source falls back rather than crashing")
    func unknownStoredValue() {
        let defaults = scratchDefaults()
        defaults.set("somethingElse", forKey: "iconSource")

        #expect(Preferences(defaults: defaults).iconSource == .lowestOnline)
    }

    @Test("The poll interval is the poll setting, as a Duration")
    func pollInterval() {
        let preferences = Preferences(defaults: scratchDefaults())

        preferences.pollSeconds = 5

        #expect(preferences.pollInterval == .seconds(5))
    }

    @Test("Two preference objects on different domains do not see each other")
    func domainsAreIsolated() {
        let first = Preferences(defaults: scratchDefaults())
        let second = Preferences(defaults: scratchDefaults())

        first.pollSeconds = 5

        #expect(second.pollSeconds == 2)
    }

    @Test("The offered choices are the ones the pickers show")
    func choices() {
        #expect(Preferences.pollChoices == [1, 2, 5])
        #expect(Preferences.thresholdChoices == [1, 2])
        #expect(Preferences.IconSource.allCases.count == 3)
        for source in Preferences.IconSource.allCases {
            #expect(!source.title.isEmpty)
        }
    }
}
