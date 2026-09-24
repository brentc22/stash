import AppKit

/// One global keyboard shortcut: a virtual key code plus the modifiers held with it.
///
/// Deliberately storage-shaped — two integers — because that is exactly what survives a
/// round trip through `UserDefaults` and what Carbon's `RegisterEventHotKey` needs. The
/// modifiers are Cocoa's (`NSEvent.ModifierFlags.rawValue`), because that is what the
/// recorder reads off the event; the translation to Carbon's `cmdKey`/`optionKey`/… lives
/// with the Carbon call in `GlobalHotKey`, not here.
public struct HotKeyCombo: Equatable, Sendable {

    public let keyCode: UInt16
    /// `NSEvent.ModifierFlags.rawValue`, already narrowed to the device-independent set.
    public let modifiers: UInt

    public init(keyCode: UInt16, modifiers: UInt) {
        self.keyCode = keyCode
        self.modifiers = HotKeyCombo.normalize(modifiers)
    }

    /// The combination Stash used to hard-code. Kept only as the migration value for
    /// users who had the old fixed shortcut switched on — nothing else defaults to it.
    public static let legacyDefault = HotKeyCombo(
        keyCode: 1,  // kVK_ANSI_S
        modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue
    )

    /// Modifiers that a global shortcut may actually be built from. Caps lock, fn, the
    /// numeric-pad bit and the left/right-specific bits are dropped: they are either not
    /// something you can hold deliberately or they would make two presses of the same
    /// visible combination compare unequal.
    public static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private static func normalize(_ raw: UInt) -> UInt {
        NSEvent.ModifierFlags(rawValue: raw)
            .intersection(.deviceIndependentFlagsMask)
            .intersection(allowedModifiers)
            .rawValue
    }

    public var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiers)
    }

    /// A combination is only usable as a *global* shortcut if it carries ⌘, ⌥ or ⌃.
    /// Without one of those — or with only ⇧ — recording "S" would swallow the letter S
    /// everywhere and the user's keyboard would appear broken with no way back.
    public var isValid: Bool {
        !modifierFlags.intersection([.command, .option, .control]).isEmpty
    }

    /// Why a combination was refused, in Dutch, or `nil` when it is fine.
    public var rejectionReason: String? {
        isValid ? nil : "Kies een combinatie met ⌘, ⌥ of ⌃ erbij — anders werkt die toets nergens meer."
    }

    /// Modifiers in the fixed order ⌘⌥⌃⇧, then the key. The order is fixed
    /// so the same combination always renders identically, whatever order it was typed in.
    public var displayString: String {
        Self.modifierString(for: modifierFlags) + Self.keyName(for: keyCode)
    }

    /// Just the modifier glyphs, in the same fixed order. Split out so the recorder can
    /// show ⌃⌥ building up before the key has been pressed.
    public static func modifierString(for flags: NSEvent.ModifierFlags) -> String {
        var result = ""
        if flags.contains(.command) { result += "⌘" }
        if flags.contains(.option)  { result += "⌥" }
        if flags.contains(.control) { result += "⌃" }
        if flags.contains(.shift)   { result += "⇧" }
        return result
    }

    /// Virtual key code to a printable name. A small table of the keys people actually
    /// bind, and an honest fallback for everything else — guessing a character from a
    /// key code without consulting the active keyboard layout produces labels that are
    /// simply wrong on a non-US layout.
    public static func keyName(for keyCode: UInt16) -> String {
        if let name = names[keyCode] { return name }
        return "Toets \(keyCode)"
    }

    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8",
        29: "0", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
        45: "N", 46: "M",
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'", 41: ";", 42: "\\", 43: ",",
        44: "/", 47: ".", 50: "`",
        36: "Return", 48: "Tab", 49: "Spatie", 51: "Delete", 53: "Esc",
        65: ".", 67: "*", 69: "+", 71: "Clear", 75: "/", 76: "Enter", 78: "-", 81: "=",
        82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7",
        91: "8", 92: "9",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10", 111: "F12", 113: "F15",
        114: "Help", 115: "Home", 116: "Page Up", 117: "Delete vooruit", 118: "F4",
        119: "End", 120: "F2", 121: "Page Down", 122: "F1",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// The key code for Escape, which cancels a recording rather than being recorded.
    public static let escapeKeyCode: UInt16 = 53
}
