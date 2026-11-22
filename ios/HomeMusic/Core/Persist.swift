import Foundation

/// localStorage of the PWA: small JSON values in UserDefaults, bigger ones in Application Support files.
enum Persist {
    static let defaults = UserDefaults.standard

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T?, key: String) {
        guard let value else { defaults.removeObject(forKey: key); return }
        if let data = try? encoder.encode(value) { defaults.set(data, forKey: key) }
    }

    static var directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeMusic", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func loadFile<T: Decodable>(_ type: T.Type, name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    @discardableResult
    static func saveFile<T: Encodable>(_ value: T, name: String) -> Bool {
        guard let data = try? encoder.encode(value) else { return false }
        do { try data.write(to: directory.appendingPathComponent(name), options: .atomic); return true } catch { return false }
    }

    static func removeFile(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
    }
}

enum Ids {
    static func new() -> String { UUID().uuidString.lowercased() }

    /// `hm-listening-device`: one per installation.
    static let device: String = {
        if let id = Persist.defaults.string(forKey: "hm-listening-device") { return id }
        let id = new()
        Persist.defaults.set(id, forKey: "hm-listening-device")
        return id
    }()

    static func iso(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}
