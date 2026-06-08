import CoreGraphics
import Foundation

enum WireMessage: Codable, Equatable {
    case hello(id: String, role: PeerRole)
    case mouseDelta(dx: Double, dy: Double, button: Int?)
    case mouseDown(button: Int)
    case mouseUp(button: Int)
    case scroll(dx: Double, dy: Double)
    case key(code: UInt16, down: Bool, flags: UInt64)
    case flags(code: UInt16, flags: UInt64)
    case activate
    case enter
    case release
    case returnControl

    enum PeerRole: String, Codable {
        case controller
        case receiver
    }

    private enum CodingKeys: String, CodingKey {
        case type, id, role, dx, dy, button, code, down, flags
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)

        switch type {
        case "hello":
            self = .hello(
                id: try values.decode(String.self, forKey: .id),
                role: try values.decodeIfPresent(PeerRole.self, forKey: .role) ?? .controller
            )
        case "mouseDelta":
            self = .mouseDelta(
                dx: try values.decode(Double.self, forKey: .dx),
                dy: try values.decode(Double.self, forKey: .dy),
                button: try values.decodeIfPresent(Int.self, forKey: .button)
            )
        case "mouseDown":
            self = .mouseDown(button: try values.decode(Int.self, forKey: .button))
        case "mouseUp":
            self = .mouseUp(button: try values.decode(Int.self, forKey: .button))
        case "scroll":
            self = .scroll(
                dx: try values.decode(Double.self, forKey: .dx),
                dy: try values.decode(Double.self, forKey: .dy)
            )
        case "key":
            self = .key(
                code: try values.decode(UInt16.self, forKey: .code),
                down: try values.decode(Bool.self, forKey: .down),
                flags: try values.decode(UInt64.self, forKey: .flags)
            )
        case "flags":
            self = .flags(
                code: try values.decode(UInt16.self, forKey: .code),
                flags: try values.decode(UInt64.self, forKey: .flags)
            )
        case "activate":
            self = .activate
        case "enter":
            self = .enter
        case "release":
            self = .release
        case "returnControl":
            self = .returnControl
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: values, debugDescription: "Unknown message type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .hello(let id, let role):
            try values.encode("hello", forKey: .type)
            try values.encode(id, forKey: .id)
            try values.encode(role, forKey: .role)
        case .mouseDelta(let dx, let dy, let button):
            try values.encode("mouseDelta", forKey: .type)
            try values.encode(dx, forKey: .dx)
            try values.encode(dy, forKey: .dy)
            try values.encodeIfPresent(button, forKey: .button)
        case .mouseDown(let button):
            try values.encode("mouseDown", forKey: .type)
            try values.encode(button, forKey: .button)
        case .mouseUp(let button):
            try values.encode("mouseUp", forKey: .type)
            try values.encode(button, forKey: .button)
        case .scroll(let dx, let dy):
            try values.encode("scroll", forKey: .type)
            try values.encode(dx, forKey: .dx)
            try values.encode(dy, forKey: .dy)
        case .key(let code, let down, let flags):
            try values.encode("key", forKey: .type)
            try values.encode(code, forKey: .code)
            try values.encode(down, forKey: .down)
            try values.encode(flags, forKey: .flags)
        case .flags(let code, let flags):
            try values.encode("flags", forKey: .type)
            try values.encode(code, forKey: .code)
            try values.encode(flags, forKey: .flags)
        case .activate:
            try values.encode("activate", forKey: .type)
        case .enter:
            try values.encode("enter", forKey: .type)
        case .release:
            try values.encode("release", forKey: .type)
        case .returnControl:
            try values.encode("returnControl", forKey: .type)
        }
    }
}

final class LineCodec {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func encode(_ message: WireMessage) -> Data? {
        guard var data = try? encoder.encode(message) else { return nil }
        data.append(0x0A)
        return data
    }

    func decodeLines(from data: Data, buffer: inout Data) -> [WireMessage] {
        buffer.append(data)
        var messages: [WireMessage] = []

        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if let message = try? decoder.decode(WireMessage.self, from: Data(line)) {
                messages.append(message)
            }
        }

        return messages
    }
}

extension CGEventFlags {
    var wireValue: UInt64 { rawValue }
}

extension CGEventFlags {
    init(wireValue: UInt64) {
        self.init(rawValue: wireValue)
    }
}
