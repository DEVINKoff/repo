import UIKit

/// Light taps under the finger for the app's actions (the system's generators, prepared ahead).
@MainActor
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let softGen = UIImpactFeedbackGenerator(style: .soft)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let selection = UISelectionFeedbackGenerator()
    private static let notify = UINotificationFeedbackGenerator()

    /// A button: play, next, open.
    static func tap() { light.impactOccurred() }
    /// Something heavier: play / pause, a big button.
    static func press() { rigid.impactOccurred(intensity: 0.7) }
    /// A soft one: a sheet or a panel appears.
    static func soft(_ intensity: CGFloat = 0.6) { softGen.impactOccurred(intensity: intensity) }
    /// A choice among several (a mode, a tab, a dial step).
    static func select() { selection.selectionChanged() }
    static func success() { notify.notificationOccurred(.success) }
    static func error() { notify.notificationOccurred(.error) }
}
