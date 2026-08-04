import AppKit
import os
import PewterCore

/// Plays the capture outcome as a sound for VoiceOver users. The gesture
/// fires while the source app is frontmost, and macOS speaks announcements
/// only for the frontmost app, so neither the HUD nor the status-item flash
/// reaches a VoiceOver user — this is the channel that does.
@MainActor
enum CaptureSound {
    private static let logger = Logger.capture
    /// The sound now playing, so a repeat of the same outcome restarts
    /// deterministically rather than relying on what `play` does to an
    /// already-playing instance.
    private static var playing: NSSound?

    /// No-op unless VoiceOver is running: everyone else has the HUD, and
    /// capture is frequent enough that an unsolicited sound would grate.
    /// The check lives here so no caller can play it for the wrong user.
    ///
    /// Every branch logs. This is the only capture feedback a VoiceOver
    /// user receives, so "I heard nothing" has to be separable in Copy
    /// Diagnostics from a gate that never fired or a device that refused.
    static func play(_ feedback: CaptureFeedback) {
        // Outcome and sound name together: a report of silence needs to
        // name which capture result went unheard, and which sound missed.
        let label = "\(feedback) (\(feedback.soundName))"
        guard NSWorkspace.shared.isVoiceOverEnabled else {
            logger.info("capture sound skipped, VoiceOver off: \(label, privacy: .public)")
            return
        }
        guard let sound = NSSound(named: feedback.soundName) else {
            logger.error("capture sound unavailable: \(label, privacy: .public)")
            NSSound.beep()
            return
        }
        // Restart a repeat of the same outcome, but let a different one
        // overlap: a user who hears only the second never learns that the
        // first capture failed.
        if playing === sound {
            sound.stop()
        }
        playing = sound
        guard sound.play() else {
            logger.error("capture sound failed to start: \(label, privacy: .public)")
            // A different mixer path, not a retry: the alert sound has its
            // own output device and volume, so it can be audible when the
            // default output isn't.
            NSSound.beep()
            return
        }
        logger.info("capture sound played: \(label, privacy: .public)")
    }
}
