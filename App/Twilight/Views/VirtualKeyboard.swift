import SwiftUI
import TwilightKit

/// A full PC keyboard for the stream: function row, number row, letters, modifiers and arrows.
/// Keys are sent as USB HID usages, which InputManager maps to the Windows key codes hosts expect,
/// so the host's own keyboard layout decides which character each key produces.
///
/// Shift, Ctrl, Alt and Windows are "sticky": tap one, then a key, to send the combination.
/// Tap a modifier twice to lock it until it's tapped again.
struct VirtualKeyboard: View {
    let input: InputManager
    @Binding var showSystemKeyboard: Bool

    @State private var latched: Set<Int> = []   // modifiers held for the next key
    @State private var locked: Set<Int> = []    // modifiers held until tapped again

    private static let shift = 0xE1, ctrl = 0xE0, alt = 0xE2, win = 0xE3, rightShift = 0xE5

    private struct Key: Identifiable {
        let usage: Int
        let label: String
        var shiftedLabel: String? = nil
        var width: CGFloat = 1
        var symbol: String? = nil
        var id: Int { usage }
    }

    private let functionRow: [Key] = [Key(usage: 0x29, label: "Esc", width: 1.25)]
        + (1...12).map { Key(usage: 0x3A + $0 - 1, label: "F\($0)") }
        + [Key(usage: 0x4C, label: "Del", width: 1.25)]

    private let numberRow: [Key] = [
        Key(usage: 0x35, label: "`", shiftedLabel: "~"),
        Key(usage: 0x1E, label: "1", shiftedLabel: "!"),
        Key(usage: 0x1F, label: "2", shiftedLabel: "@"),
        Key(usage: 0x20, label: "3", shiftedLabel: "#"),
        Key(usage: 0x21, label: "4", shiftedLabel: "$"),
        Key(usage: 0x22, label: "5", shiftedLabel: "%"),
        Key(usage: 0x23, label: "6", shiftedLabel: "^"),
        Key(usage: 0x24, label: "7", shiftedLabel: "&"),
        Key(usage: 0x25, label: "8", shiftedLabel: "*"),
        Key(usage: 0x26, label: "9", shiftedLabel: "("),
        Key(usage: 0x27, label: "0", shiftedLabel: ")"),
        Key(usage: 0x2D, label: "-", shiftedLabel: "_"),
        Key(usage: 0x2E, label: "=", shiftedLabel: "+"),
        Key(usage: 0x2A, label: "Backspace", width: 1.75, symbol: "delete.left"),
    ]

    private var topRow: [Key] {
        [Key(usage: 0x2B, label: "Tab", width: 1.5)]
            + letters("qwertyuiop")
            + [Key(usage: 0x2F, label: "[", shiftedLabel: "{"),
               Key(usage: 0x30, label: "]", shiftedLabel: "}"),
               Key(usage: 0x31, label: "\\", shiftedLabel: "|", width: 1.25)]
    }

    private var homeRow: [Key] {
        [Key(usage: 0x39, label: "Caps", width: 1.75)]
            + letters("asdfghjkl")
            + [Key(usage: 0x33, label: ";", shiftedLabel: ":"),
               Key(usage: 0x34, label: "'", shiftedLabel: "\""),
               Key(usage: 0x28, label: "Enter", width: 2, symbol: "return")]
    }

    private var bottomRow: [Key] {
        [Key(usage: Self.shift, label: "Shift", width: 2.25, symbol: "shift")]
            + letters("zxcvbnm")
            + [Key(usage: 0x36, label: ",", shiftedLabel: "<"),
               Key(usage: 0x37, label: ".", shiftedLabel: ">"),
               Key(usage: 0x38, label: "/", shiftedLabel: "?"),
               Key(usage: Self.rightShift, label: "Shift", width: 1.5, symbol: "shift"),
               Key(usage: 0x52, label: "Up", symbol: "arrowtriangle.up.fill")]
    }

    private let spaceRow: [Key] = [
        Key(usage: 0xE0, label: "Ctrl", width: 1.5),
        Key(usage: 0xE3, label: "Win", width: 1.25, symbol: "square.grid.2x2"),
        Key(usage: 0xE2, label: "Alt", width: 1.25),
        Key(usage: 0x2C, label: "Space", width: 6.5),
        Key(usage: 0x50, label: "Left", symbol: "arrowtriangle.left.fill"),
        Key(usage: 0x51, label: "Down", symbol: "arrowtriangle.down.fill"),
        Key(usage: 0x4F, label: "Right", symbol: "arrowtriangle.right.fill"),
    ]

    private func letters(_ string: String) -> [Key] {
        string.map { c in
            Key(usage: 0x04 + Int(c.asciiValue! - Character("a").asciiValue!), label: String(c), shiftedLabel: c.uppercased())
        }
    }

    private static let unit: CGFloat = 50
    private static let spacing: CGFloat = 6

    var body: some View {
        VStack(spacing: Self.spacing) {
            row(functionRow, height: 0.8)
            row(numberRow)
            row(topRow)
            row(homeRow)
            row(bottomRow)
            HStack(spacing: Self.spacing) {
                row(spaceRow)
                Toggle(isOn: $showSystemKeyboard) {
                    Label("System Keyboard", systemImage: "keyboard.badge.ellipsis")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
                .help("Type with the visionOS keyboard, including dictation")
            }
        }
        .padding(14)
        .glassBackgroundEffect()
        .onDisappear(perform: releaseAll)
    }

    private var shifted: Bool {
        let held = latched.union(locked)
        return held.contains(Self.shift) || held.contains(Self.rightShift)
    }

    private func row(_ keys: [Key], height: CGFloat = 1) -> some View {
        HStack(spacing: Self.spacing) {
            ForEach(keys) { key in
                keyButton(key, height: height)
            }
        }
    }

    private func keyButton(_ key: Key, height: CGFloat) -> some View {
        let isModifier = (0xE0...0xE7).contains(key.usage)
        let isOn = latched.contains(key.usage) || locked.contains(key.usage)
        return Button {
            tap(key.usage)
        } label: {
            Group {
                if let symbol = key.symbol {
                    Image(systemName: locked.contains(key.usage) && key.symbol == "shift" ? "capslock.fill" : symbol)
                } else {
                    Text(shifted ? (key.shiftedLabel ?? key.label) : key.label)
                }
            }
            .font(key.label.count > 1 && key.symbol == nil ? .footnote : .body)
            .frame(width: Self.unit * key.width + Self.spacing * (key.width - 1),
                   height: Self.unit * height)
            .background(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.thinMaterial), in: .rect(cornerRadius: 10))
            .contentShape(.hoverEffect, .rect(cornerRadius: 10))
            .hoverEffect()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(key.label)
        .accessibilityAddTraits(isModifier && isOn ? .isSelected : [])
    }

    private func tap(_ usage: Int) {
        if (0xE0...0xE7).contains(usage) {
            toggleModifier(usage)
            return
        }
        input.sendKey(hidUsage: usage, pressed: true)
        input.sendKey(hidUsage: usage, pressed: false)
        // One-shot modifiers apply to a single key
        for modifier in latched {
            input.sendKey(hidUsage: modifier, pressed: false)
        }
        latched.removeAll()
    }

    /// First tap holds the modifier for the next key, a second tap locks it, a third releases it.
    private func toggleModifier(_ usage: Int) {
        if locked.contains(usage) {
            locked.remove(usage)
            input.sendKey(hidUsage: usage, pressed: false)
        } else if latched.contains(usage) {
            latched.remove(usage)
            locked.insert(usage)
        } else {
            latched.insert(usage)
            input.sendKey(hidUsage: usage, pressed: true)
        }
    }

    /// Never leave a modifier stuck down on the host when the keyboard closes.
    private func releaseAll() {
        for modifier in latched.union(locked) {
            input.sendKey(hidUsage: modifier, pressed: false)
        }
        latched.removeAll()
        locked.removeAll()
    }
}
