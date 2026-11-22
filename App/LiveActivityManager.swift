import ActivityKit
import Foundation

@MainActor
final class LiveActivityManager: ObservableObject {
    @Published var isRunning = false
    @Published var count = 0
    @Published var message = ""

    private var activity: Activity<DevTestActivityAttributes>?
    private var watchers: [Task<Void, Never>] = []

    init() {
        reattach()
    }

    /// Picks up an activity that is already running (e.g. after the app was relaunched).
    func reattach() {
        if let existing = Activity<DevTestActivityAttributes>.activities.first(where: { $0.activityState == .active }) {
            attach(existing)
        } else if activity != nil {
            detach()
        }
    }

    func start() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            message = "Live Activities are turned off for DevTest in Settings."
            return
        }
        let state = DevTestActivityAttributes.ContentState(
            count: 0,
            status: "Running",
            endDate: Date().addingTimeInterval(5 * 60)
        )
        do {
            let new = try Activity.request(
                attributes: DevTestActivityAttributes(title: "DevTest"),
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil
            )
            attach(new)
            message = "Started. Swipe home or lock the phone to see it."
        } catch {
            message = "Couldn't start: \(error.localizedDescription)"
        }
    }

    func bump() {
        guard let activity else { return }
        var state = activity.content.state
        state.count += 1
        state.status = ActivityStatus.words.randomElement() ?? "Running"
        count = state.count
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    func end() {
        guard let activity else { return }
        var state = activity.content.state
        state.status = "Done"
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
        }
        detach()
        message = "Ended."
    }

    private func attach(_ new: Activity<DevTestActivityAttributes>) {
        if activity?.id == new.id { return }
        watchers.forEach { $0.cancel() }
        activity = new
        isRunning = true
        count = new.content.state.count

        watchers = [
            Task { [weak self] in
                for await content in new.contentUpdates {
                    self?.count = content.state.count
                }
            },
            Task { [weak self] in
                for await state in new.activityStateUpdates {
                    if state != .active {
                        self?.detach()
                    }
                }
            },
        ]
    }

    private func detach() {
        watchers.forEach { $0.cancel() }
        watchers = []
        activity = nil
        isRunning = false
    }
}
