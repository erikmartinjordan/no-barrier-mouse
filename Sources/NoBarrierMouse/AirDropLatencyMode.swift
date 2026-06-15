import Foundation

enum AirDropLatencyMode {
    static let defaultsKey = "DisableAirDropWhileReceiving"
    private static let previousDiscoverableModeKey = "PreviousAirDropDiscoverableMode"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static var isAirDropOff: Bool {
        if let disabled = readDefaults(arguments: ["read", "com.apple.NetworkBrowser", "DisableAirDrop"])?.lowercased(),
           disabled == "1" || disabled == "yes" || disabled == "true" {
            return true
        }
        return readDefaults(arguments: ["read", "com.apple.sharingd", "DiscoverableMode"]) == "Off"
    }

    static func apply(disabled: Bool) {
        if disabled {
            if UserDefaults.standard.string(forKey: previousDiscoverableModeKey) == nil,
               let current = readDefaults(arguments: ["read", "com.apple.sharingd", "DiscoverableMode"]),
               !current.isEmpty {
                UserDefaults.standard.set(current, forKey: previousDiscoverableModeKey)
            }
            runDefaults(arguments: ["write", "com.apple.NetworkBrowser", "DisableAirDrop", "-bool", "YES"])
            runDefaults(arguments: ["write", "com.apple.sharingd", "DiscoverableMode", "Off"])
        } else {
            runDefaults(arguments: ["write", "com.apple.NetworkBrowser", "DisableAirDrop", "-bool", "NO"])
            if let previous = UserDefaults.standard.string(forKey: previousDiscoverableModeKey), !previous.isEmpty {
                runDefaults(arguments: ["write", "com.apple.sharingd", "DiscoverableMode", previous])
                UserDefaults.standard.removeObject(forKey: previousDiscoverableModeKey)
            }
        }
    }

    private static func runDefaults(arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }

    private static func readDefaults(arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }
}
