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
