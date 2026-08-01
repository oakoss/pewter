import AppKit
import Carbon.HIToolbox
import PewterCore

extension KeyChord {
    var carbonChord: HotKeyCenter.Chord {
        var mods: UInt32 = 0
        if modifiers.contains(.control) {
            mods |= UInt32(controlKey)
        }
        if modifiers.contains(.option) {
            mods |= UInt32(optionKey)
        }
        if modifiers.contains(.shift) {
            mods |= UInt32(shiftKey)
        }
        if modifiers.contains(.command) {
            mods |= UInt32(cmdKey)
        }
        return HotKeyCenter.Chord(keyCode: UInt32(keyCode), modifiers: mods)
    }

    init(keyDown event: NSEvent) {
        var mods: Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.control) {
            mods.insert(.control)
        }
        if flags.contains(.option) {
            mods.insert(.option)
        }
        if flags.contains(.shift) {
            mods.insert(.shift)
        }
        if flags.contains(.command) {
            mods.insert(.command)
        }
        self.init(keyCode: event.keyCode, modifiers: mods)
    }
}
