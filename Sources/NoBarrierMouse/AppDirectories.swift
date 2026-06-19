import Foundation

enum AppDirectories {
    private static var bundleID: String {
        Bundle.main.bundleIdentifier ?? "com.erikmartinjordan.NoBarrierMouse"
    }

    static func caches(subdirectory: String) throws -> URL {
        try directory(for: .cachesDirectory, subdirectory: subdirectory)
    }

    static func applicationSupport(subdirectory: String) throws -> URL {
        try directory(for: .applicationSupportDirectory, subdirectory: subdirectory)
    }

    private static func directory(for searchPath: FileManager.SearchPathDirectory, subdirectory: String) throws -> URL {
        let fileManager = FileManager.default
        let url = try fileManager.url(
            for: searchPath,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent(bundleID, isDirectory: true)
        .appendingPathComponent(subdirectory, isDirectory: true)

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
