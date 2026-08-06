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

        let unreadable = CaptureFeedback.notesUnavailable(.unreadable(cause: .other("disk on fire")))
        #expect(unreadable.symbolName == "exclamationmark.triangle")
        #expect(unreadable.message == "Can't read your notes file — nothing was saved")
        #expect(unreadable.duration == 2)

        let inFlight = CaptureFeedback.notesUnavailable(.adoptionInFlight)
        #expect(inFlight.symbolName == "arrow.triangle.2.circlepath")
        #expect(inFlight.message == "Your notes just changed on disk — capture again")
        #expect(inFlight.duration == 2)
    }

    /// The whole reason the cause travels: two unreadable files need two
    /// different repairs, and one string for both sends half the users to
    /// check something that was never wrong.
    @Test func eachUnreadableCauseNamesItsOwnRepair() {
        func message(for cause: UnreadableCause) -> String {
            CaptureFeedback.notesUnavailable(.unreadable(cause: cause)).message
        }
        let messages = [message(for: .notPermitted), message(for: .notUTF8), message(for: .other("disk on fire"))]

        #expect(Set(messages).count == messages.count)
        // Keyed by cause, not by position: reordering the list above would
        // otherwise swap which repair each assertion checks, and both strings
        // would still be somewhere in the set for the distinctness check.
        //
        // Each names the *repair*, not merely the cause. "isn't UTF-8" says
        // what is wrong and leaves the user to work out what to do; the
        // complaint behind this was a message that gave neither.
        #expect(message(for: .notPermitted).contains("check its permissions"))
        #expect(message(for: .notUTF8).contains("re-save it as UTF-8"))
    }

    /// The two named causes are the ones with a repair the app can state, so
    /// both the at-a-glance HUD and the composer's toast have to state it.
    /// `.other` is exempt: there is no specific remedy to give.
    @Test func bothSurfacesNameTheRepairForEveryCauseThatHasOne() {
        for cause in [UnreadableCause.notPermitted, .notUTF8] {
            let hud = CaptureFeedback.notesUnavailable(.unreadable(cause: cause)).message
            let toast = Unavailability.unreadable(cause: cause).refusalMessage
            let banner = FileStorage.Health.unreadable(cause: cause).bannerMessage ?? ""
            let repair = cause == .notPermitted ? "permissions" : "UTF-8"
            #expect(hud.contains(repair))
            #expect(toast.contains(repair))
            #expect(banner.contains(repair))
        }
    }

    /// An in-flight adoption is a "try again", not a broken file. Sharing the
    /// unreadable wording would send the user to repair a file that reads
    /// perfectly — the conflation this outcome exists to end.
    @Test func anInFlightAdoptionIsNotReportedAsAnUnreadableFile() {
        let inFlight = CaptureFeedback.notesUnavailable(.adoptionInFlight)
        for cause in [UnreadableCause.notPermitted, .notUTF8, .other("disk on fire")] {
            let unreadable = CaptureFeedback.notesUnavailable(.unreadable(cause: cause))
            #expect(inFlight.message != unreadable.message)
            #expect(inFlight.symbolName != unreadable.symbolName)
            #expect(inFlight.soundName != unreadable.soundName)
        }
        #expect(!inFlight.message.lowercased().contains("can't read"))
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
            CaptureFeedback.notesUnavailable(.unreadable(cause: .notUTF8)).soundName,
            CaptureFeedback.notesUnavailable(.adoptionInFlight).soundName,
        ]
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.isEmpty })
    }
}
