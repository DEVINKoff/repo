// Shared by the app and the widget extension.
import ActivityKit
import AppIntents
import Foundation

struct DevTestActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var count: Int
        var status: String
        var endDate: Date
    }

    var title: String
}

enum ActivityStatus {
    static let words = ["Running", "Cooking", "Vibing", "Shipping", "Glowing", "Rendering"]
}

/// "+1" button inside the Dynamic Island / Lock Screen. Runs in the app's process.
struct BumpActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Bump DevTest activity"

    func perform() async throws -> some IntentResult {
        for activity in Activity<DevTestActivityAttributes>.activities {
            var state = activity.content.state
            state.count += 1
            state.status = ActivityStatus.words.randomElement() ?? "Running"
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
        return .result()
    }
}

/// "End" button inside the Dynamic Island / Lock Screen.
struct EndActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "End DevTest activity"

    func perform() async throws -> some IntentResult {
        for activity in Activity<DevTestActivityAttributes>.activities {
            var state = activity.content.state
            state.status = "Done"
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
        return .result()
    }
}
