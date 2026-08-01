import PewterCore
import SwiftUI

/// All recording state and the key monitor live in KeyRecorderModel — this
/// view is a plain rendering of it.
struct KeyRecorderView: View {
    let slot: HotKeySlot
    let model: KeyRecorderModel

    private var chord: KeyChord? {
        model.chords[slot]
    }

    private var isRecording: Bool {
        model.active == slot
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                Text(isRecording ? "Press shortcut…" : (chord?.display ?? "Off"))
                    .font(.body.monospaced())
                    .foregroundStyle(badgeForeground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(badgeBackground, in: RoundedRectangle(cornerRadius: 6))

                Button(isRecording ? "Cancel" : "Change") {
                    isRecording ? model.cancel() : model.begin(slot)
                }

                if chord != nil, !isRecording {
                    Button("Turn Off") {
                        model.clear(slot)
                    }
                }
            }
            if let hint = model.hints[slot] {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var badgeForeground: Color {
        isRecording ? .orange : (chord == nil ? .secondary : .primary)
    }

    private var badgeBackground: Color {
        isRecording ? .orange.opacity(0.15) : .primary.opacity(0.06)
    }
}
