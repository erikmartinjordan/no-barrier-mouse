import CoreGraphics
import Foundation

enum WireMessage: Equatable {
    case hello(id: String, role: PeerRole)
    case mouseDelta(dx: Double, dy: Double, button: Int?)
    case mouseDown(button: Int)
    case mouseUp(button: Int)
    case scroll(dx: Double, dy: Double)
    case key(code: UInt16, down: Bool, flags: UInt64)
    case flags(code: UInt16, flags: UInt64)
    case activate
    case enter(y: Double)
    case release
    case returnControl

    enum PeerRole: String {
        case controller
        case receiver
    }
}

final class WireCodec {
    func encode(_ message: WireMessage) -> Data {
        var data = Data()
        switch message {
        case .hello(let id, let role):
            data.appendByte(0)
            data.appendString(id)
            data.appendString(role.rawValue)
        case .mouseDelta(let dx, let dy, let button):
            data.appendByte(1)
            data.appendFloat32LE(Float32(dx))
            data.appendFloat32LE(Float32(dy))
            data.appendOptionalByte(button.map(UInt8.init))
        case .mouseDown(let button):
            data.appendByte(2)
            data.appendByte(UInt8(button))
        case .mouseUp(let button):
            data.appendByte(3)
            data.appendByte(UInt8(button))
        case .scroll(let dx, let dy):
            data.appendByte(4)
            data.appendFloat32LE(Float32(dx))
            data.appendFloat32LE(Float32(dy))
        case .key(let code, let down, let flags):
            data.appendByte(5)
            data.appendUInt16LE(code)
            data.appendByte(down ? 1 : 0)
            data.appendUInt64LE(flags)
        case .flags(let code, let flags):
            data.appendByte(6)
            data.appendUInt16LE(code)
            data.appendUInt64LE(flags)
        case .activate:
            data.appendByte(7)
        case .enter(let y):
            data.appendByte(8)
            data.appendFloat32LE(Float32(y))
        case .release:
            data.appendByte(9)
        case .returnControl:
            data.appendByte(10)
        }
        return data
    }

    func decode(from data: Data) -> WireMessage? {
        var offset = 0
        guard let type = data.readByte(at: &offset) else { return nil }

        switch type {
        case 0:
            guard let id = data.readString(at: &offset),
                  let roleRaw = data.readString(at: &offset) else { return nil }
            return .hello(id: id, role: WireMessage.PeerRole(rawValue: roleRaw) ?? .receiver)
        case 1:
            guard let dx = data.readFloat32LE(at: &offset),
                  let dy = data.readFloat32LE(at: &offset) else { return nil }
            let button = data.readOptionalByte(at: &offset).map { Int($0) }
            return .mouseDelta(dx: Double(dx), dy: Double(dy), button: button)
        case 2:
            guard let button = data.readByte(at: &offset) else { return nil }
            return .mouseDown(button: Int(button))
        case 3:
            guard let button = data.readByte(at: &offset) else { return nil }
            return .mouseUp(button: Int(button))
        case 4:
            guard let dx = data.readFloat32LE(at: &offset),
                  let dy = data.readFloat32LE(at: &offset) else { return nil }
            return .scroll(dx: Double(dx), dy: Double(dy))
        case 5:
            guard let code = data.readUInt16LE(at: &offset),
                  let downRaw = data.readByte(at: &offset),
                  let flags = data.readUInt64LE(at: &offset) else { return nil }
            return .key(code: code, down: downRaw != 0, flags: flags)
        case 6:
            guard let code = data.readUInt16LE(at: &offset),
                  let flags = data.readUInt64LE(at: &offset) else { return nil }
            return .flags(code: code, flags: flags)
        case 7:
            return .activate
        case 8:
            guard let y = data.readFloat32LE(at: &offset) else { return nil }
            return .enter(y: Double(y))
        case 9:
            return .release
        case 10:
            return .returnControl
        default:
            return nil
        }
    }
}

extension Data {
    mutating func appendByte(_ value: UInt8) {
        append(value)
    }

    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt64LE(_ value: UInt64) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 32) & 0xFF))
        append(UInt8((value >> 40) & 0xFF))
        append(UInt8((value >> 48) & 0xFF))
        append(UInt8((value >> 56) & 0xFF))
    }

    mutating func appendFloat32LE(_ value: Float32) {
        appendUInt32LE(value.bitPattern)
    }

    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    mutating func appendString(_ string: String) {
        let bytes = Data(string.utf8)
        appendUInt16LE(UInt16(bytes.count))
        append(bytes)
    }

    mutating func appendOptionalByte(_ value: UInt8?) {
        if let value {
            appendByte(1)
            appendByte(value)
        } else {
            appendByte(0)
        }
    }

    func readByte(at offset: inout Int) -> UInt8? {
        guard offset + 1 <= count else { return nil }
        defer { offset += 1 }
        return self[offset]
    }

    func readUInt16LE(at offset: inout Int) -> UInt16? {
        guard offset + 2 <= count else { return nil }
        let v = UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
        offset += 2
        return v
    }

    func readUInt64LE(at offset: inout Int) -> UInt64? {
        guard offset + 8 <= count else { return nil }
        let byte0 = UInt64(self[offset])
        let byte1 = UInt64(self[offset + 1]) << 8
        let byte2 = UInt64(self[offset + 2]) << 16
        let byte3 = UInt64(self[offset + 3]) << 24
        let byte4 = UInt64(self[offset + 4]) << 32
        let byte5 = UInt64(self[offset + 5]) << 40
        let byte6 = UInt64(self[offset + 6]) << 48
        let byte7 = UInt64(self[offset + 7]) << 56
        let v = byte0 | byte1 | byte2 | byte3 | byte4 | byte5 | byte6 | byte7
        offset += 8
        return v
    }

    func readFloat32LE(at offset: inout Int) -> Float32? {
        guard offset + 4 <= count else { return nil }
        let bits = UInt32(self[offset]) |
                   UInt32(self[offset + 1]) << 8 |
                   UInt32(self[offset + 2]) << 16 |
                   UInt32(self[offset + 3]) << 24
        offset += 4
        return Float32(bitPattern: bits)
    }

    func readOptionalByte(at offset: inout Int) -> UInt8? {
        guard let present = readByte(at: &offset), present != 0 else { return nil }
        return readByte(at: &offset)
    }

    func readString(at offset: inout Int) -> String? {
        guard let length = readUInt16LE(at: &offset) else { return nil }
        let lengthInt = Int(length)
        guard offset + lengthInt <= count else { return nil }
        defer { offset += lengthInt }
        return String(data: self[offset..<offset + lengthInt], encoding: .utf8)
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
