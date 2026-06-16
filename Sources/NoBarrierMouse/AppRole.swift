import Foundation

enum SavedRole: String {
    case controller
    case receiver
}

struct SavedRoleStore {
    static let defaultsKey = "SelectedRole"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> SavedRole? {
        guard let rawValue = defaults.string(forKey: Self.defaultsKey) else {
            return nil
        }
        return SavedRole(rawValue: rawValue)
    }

    func save(_ role: SavedRole) {
        defaults.set(role.rawValue, forKey: Self.defaultsKey)
    }
}

enum AppRole: Equatable, CustomStringConvertible {
    case controller
    case receiver

    var description: String {
        switch self {
        case .controller: return "Controller"
        case .receiver: return "Receiver"
        }
    }
}

extension AppRole {
    init(savedRole: SavedRole) {
        switch savedRole {
        case .controller:
            self = .controller
        case .receiver:
            self = .receiver
        }
    }

    var savedRole: SavedRole {
        switch self {
        case .controller:
            return .controller
        case .receiver:
            return .receiver
        }
    }
}
