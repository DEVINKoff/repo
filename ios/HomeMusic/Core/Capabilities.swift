import Foundation

/// `lib/capabilities.ts`: what the Hub supports (`/healthz` `capabilities`), checked at most every 30 s.
/// Unknown/offline servers are treated conservatively; a later request checks again.
@MainActor
enum Capabilities {
    private static var supported = false
    private static var checkpointsSupported = false
    private(set) static var all: Set<String> = []
    private static var checkedAt = Date.distantPast
    private static var checking: Task<Bool?, Never>?

    @discardableResult
    static func typedFavoritesSupported() async -> Bool? {
        if Date().timeIntervalSince(checkedAt) < 30 { return supported }
        if let checking { return await checking.value }
        let task = Task<Bool?, Never> {
            do {
                let caps = Set(try await HubClient.shared.health().capabilities ?? [])
                all = caps
                supported = caps.contains("typed_favorites_v1")
                checkpointsSupported = caps.contains("listening_checkpoints_v1")
                checkedAt = Date()
                return supported
            } catch {
                supported = false
                checkpointsSupported = false
                return nil
            }
        }
        checking = task
        let result = await task.value
        checking = nil
        return result
    }

    static func has(_ name: String) -> Bool { all.contains(name) }

    static func canSend(_ e: PlayEventIn) -> Bool {
        if ["progress", "interrupted", "error"].contains(e.kind) && !checkpointsSupported { return false }
        return supported || ((e.targetType == nil || e.targetType == "track") && e.revertsEventId == nil)
    }

    static func reset() {
        checkedAt = .distantPast
        all = []
    }
}
