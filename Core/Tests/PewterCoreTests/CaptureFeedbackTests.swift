import Foundation
@testable import PewterCore
import Testing

struct CaptureFeedbackTests {
    @Test func everySurfaceValueIsPinned() {
        // Symbol, message, and duration feed both the HUD and the
        // VoiceOver-read status flash; a drift in any of them changes what
        // users are told.
        #expect(CaptureFeedback.captured.symbolName == "checkmark.circle")
        #expect(CaptureFeedback.captured.message == "Captured")
        #expect(CaptureFeedback.captured.duration == 1.2)

        #expect(CaptureFeedback.nothingSelected.symbolName == "xmark.circle")
        #expect(CaptureFeedback.nothingSelected.message == "No text selected")
        #expect(CaptureFeedback.nothingSelected.duration == 2)

        #expect(CaptureFeedback.captureFailed.symbolName == "exclamationmark.circle")
        #expect(CaptureFeedback.captureFailed.message == "Couldn't capture — try copying manually")
        #expect(CaptureFeedback.captureFailed.duration == 2)
    }

    @Test func failureFeedbackOutlastsSuccess() {
        #expect(CaptureFeedback.captureFailed.duration > CaptureFeedback.captured.duration)
        #expect(CaptureFeedback.nothingSelected.duration > CaptureFeedback.captured.duration)
    }

    @Test func everyOutcomeSoundsDifferent() {
        // The sound is the only capture feedback a VoiceOver user reliably
        // gets, so two outcomes sharing one would make them indistinguishable.
        // Distinctness is all this can prove — whether a name resolves to an
        // actual sound is a runtime question, answered by CaptureSound's
        // beep fallback rather than here.
        let names = [
            CaptureFeedback.captured.soundName,
            CaptureFeedback.nothingSelected.soundName,
            CaptureFeedback.captureFailed.soundName,
        ]
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.isEmpty })
    }
}
