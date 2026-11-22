import AVFoundation
import MediaPlayer
import SwiftUI

/// The device volume, watched: at zero the music pauses, and plays on when it is turned up again.
@MainActor
@Observable
final class VolumeWatch {
    static let shared = VolumeWatch()
    private(set) var level: Float = AVAudioSession.sharedInstance().outputVolume
    /// bumped on every change from outside (the buttons): the dial shows itself
    private(set) var changes = 0
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored weak var slider: UISlider?
    @ObservationIgnored private var settingUntil = Date.distantPast

    func start() {
        guard observation == nil else { return }
        level = AVAudioSession.sharedInstance().outputVolume
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { session, _ in
            let v = session.outputVolume
            Task { @MainActor in
                let w = VolumeWatch.shared
                w.level = v
                if Date() > w.settingUntil { w.changes += 1 }
                w.followMute(v)
            }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }

    /// Volume at zero pauses the music; turned up again, it plays on (only when it was the zero that paused it).
    @ObservationIgnored private var pausedByMute = false

    private func followMute(_ v: Float) {
        let p = Player.shared
        if v <= 0.001 {
            if p.isPlaying { p.pause(); pausedByMute = true }
        } else if pausedByMute {
            pausedByMute = false
            if !p.isPlaying, p.track != nil { p.resume() }
        }
    }

    func set(_ v: Float) {
        let v = min(1, max(0, v))
        settingUntil = Date().addingTimeInterval(0.3)
        level = v
        slider?.setValue(v, animated: false)
        slider?.sendActions(for: .valueChanged)
    }
}
