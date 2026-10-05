import Foundation
import IOKit.pwr_mgt

struct SleepPreventionPreference {
    static let defaultsKey = "PreventIdleSleep"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.defaultsKey) != nil else { return true }
            return defaults.bool(forKey: Self.defaultsKey)
        }
        nonmutating set {
            defaults.set(newValue, forKey: Self.defaultsKey)
        }
    }
}

final class IdleSleepPreventer {
    private var displayAssertionID: IOPMAssertionID = 0
    private var systemAssertionID: IOPMAssertionID = 0
    private var isPreventing = false

    var isActive: Bool { isPreventing }

    func start() {
        guard !isPreventing else { return }
        isPreventing = true
        createAssertion(
            type: kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            name: "NoBarrierMouse keeps the display awake",
            id: &displayAssertionID
        )
        createAssertion(
            type: kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            name: "NoBarrierMouse keeps the system awake",
            id: &systemAssertionID
        )
    }

    func stop() {
        guard isPreventing else { return }
        isPreventing = false
        releaseAssertion(&displayAssertionID)
        releaseAssertion(&systemAssertionID)
    }

    private func createAssertion(type: CFString, name: String, id: inout IOPMAssertionID) {
        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess {
            id = assertionID
        }
    }

    private func releaseAssertion(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }

    deinit {
        stop()
    }
}
