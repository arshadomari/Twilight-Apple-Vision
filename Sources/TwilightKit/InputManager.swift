import CoreHaptics
import Foundation
import GameController
import TwilightKitC

/// Forwards game controllers, hardware keyboards and mice to the host.
public final class InputManager: @unchecked Sendable {
    private struct Pad {
        let number: Int
        let controller: GCController
        var haptics: CHHapticEngine?
        var rumblePlayer: CHHapticAdvancedPatternPlayer?
    }

    private var pads: [ObjectIdentifier: Pad] = [:]
    private var observers: [NSObjectProtocol] = []
    private var swapFaceButtons = false
    private var keyboardModifiers: Int8 = 0
    private var mouseButtonsDown: Set<Int32> = []
    private let lock = NSLock()
    private var running = false

    public init() {}

    /// Bitmask of controller slots, for the launch request's gcmap.
    public var activeGamepadMask: Int {
        let count = min(GCController.controllers().filter { $0.extendedGamepad != nil }.count, 16)
        return count == 0 ? 0 : (1 << count) - 1
    }

    private var currentMask: Int16 {
        lock.lock()
        defer { lock.unlock() }
        var mask: Int16 = 0
        for pad in pads.values { mask |= Int16(1 << pad.number) }
        return mask
    }

    // MARK: Lifecycle

    func start(swapFaceButtons: Bool) {
        self.swapFaceButtons = swapFaceButtons
        running = true
        GCController.shouldMonitorBackgroundEvents = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController { self?.attach(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            if let controller = note.object as? GCController { self?.detach(controller) }
        })
        observers.append(center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { [weak self] _ in
            self?.attachKeyboard()
        })
        observers.append(center.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attachMouse(mouse) }
        })

        GCController.controllers().forEach(attach)
        attachKeyboard()
        GCMouse.mice().forEach(attachMouse)
    }

    func stop() {
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        lock.lock()
        let all = pads.values
        pads.removeAll()
        lock.unlock()
        for pad in all {
            pad.controller.extendedGamepad?.valueChangedHandler = nil
            pad.haptics?.stop()
        }
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        for mouse in GCMouse.mice() {
            mouse.mouseInput?.mouseMovedHandler = nil
            mouse.mouseInput?.leftButton.pressedChangedHandler = nil
            mouse.mouseInput?.rightButton?.pressedChangedHandler = nil
            mouse.mouseInput?.middleButton?.pressedChangedHandler = nil
            mouse.mouseInput?.scroll.yAxis.valueChangedHandler = nil
        }
    }

    // MARK: Controllers

    private func attach(_ controller: GCController) {
        guard running, let gamepad = controller.extendedGamepad else { return }
        lock.lock()
        let used = Set(pads.values.map(\.number))
        guard let number = (0..<16).first(where: { !used.contains($0) }), pads[ObjectIdentifier(controller)] == nil else {
            lock.unlock()
            return
        }
        var pad = Pad(number: number, controller: controller)
        pad.haptics = controller.haptics?.createEngine(withLocality: .default)
        try? pad.haptics?.start()
        pads[ObjectIdentifier(controller)] = pad
        lock.unlock()

        controller.playerIndex = GCControllerPlayerIndex(rawValue: number) ?? .indexUnset

        let type: UInt8
        if gamepad is GCDualSenseGamepad || gamepad is GCDualShockGamepad {
            type = UInt8(LI_CTYPE_PS)
        } else if gamepad is GCXboxGamepad {
            type = UInt8(LI_CTYPE_XBOX)
        } else if controller.productCategory.localizedCaseInsensitiveContains("switch") || controller.productCategory.contains("Joy-Con") {
            type = UInt8(LI_CTYPE_NINTENDO)
        } else {
            type = UInt8(LI_CTYPE_UNKNOWN)
        }
        var caps = UInt16(LI_CCAP_ANALOG_TRIGGERS)
        if controller.haptics != nil { caps |= UInt16(LI_CCAP_RUMBLE) }
        let buttons = UInt32(A_FLAG | B_FLAG | X_FLAG | Y_FLAG | UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG |
                             LB_FLAG | RB_FLAG | PLAY_FLAG | BACK_FLAG | LS_CLK_FLAG | RS_CLK_FLAG | SPECIAL_FLAG)
        LiSendControllerArrivalEvent(UInt8(number), UInt16(bitPattern: currentMask), type, buttons, caps)

        gamepad.valueChangedHandler = { [weak self] gamepad, _ in
            self?.send(gamepad, number: number)
        }
        TwilightLog.info("Controller \(number) attached: \(controller.vendorName ?? "unknown"), category \(controller.productCategory), profile \(Swift.type(of: gamepad)), type \(type)")
    }

    private func detach(_ controller: GCController) {
        lock.lock()
        let pad = pads.removeValue(forKey: ObjectIdentifier(controller))
        lock.unlock()
        guard let pad else { return }
        pad.haptics?.stop()
        controller.extendedGamepad?.valueChangedHandler = nil
        // A neutral event with the updated mask tells the host the pad is gone
        LiSendMultiControllerEvent(Int16(pad.number), currentMask, 0, 0, 0, 0, 0, 0, 0)
    }

    private func send(_ g: GCExtendedGamepad, number: Int) {
        var flags: Int32 = 0
        func set(_ pressed: Bool, _ flag: Int32) { if pressed { flags |= flag } }

        let (a, b, x, y) = swapFaceButtons ? (g.buttonB, g.buttonA, g.buttonY, g.buttonX) : (g.buttonA, g.buttonB, g.buttonX, g.buttonY)
        set(a.isPressed, Int32(A_FLAG))
        set(b.isPressed, Int32(B_FLAG))
        set(x.isPressed, Int32(X_FLAG))
        set(y.isPressed, Int32(Y_FLAG))
        set(g.dpad.up.isPressed, Int32(UP_FLAG))
        set(g.dpad.down.isPressed, Int32(DOWN_FLAG))
        set(g.dpad.left.isPressed, Int32(LEFT_FLAG))
        set(g.dpad.right.isPressed, Int32(RIGHT_FLAG))
        set(g.leftShoulder.isPressed, Int32(LB_FLAG))
        set(g.rightShoulder.isPressed, Int32(RB_FLAG))
        set(g.buttonMenu.isPressed, Int32(PLAY_FLAG))
        set(g.buttonOptions?.isPressed ?? false, Int32(BACK_FLAG))
        set(g.leftThumbstickButton?.isPressed ?? false, Int32(LS_CLK_FLAG))
        set(g.rightThumbstickButton?.isPressed ?? false, Int32(RS_CLK_FLAG))
        set(g.buttonHome?.isPressed ?? false, Int32(SPECIAL_FLAG))
        if let ds = g as? GCDualSenseGamepad { set(ds.touchpadButton.isPressed, Int32(TOUCHPAD_FLAG)) }
        if let ds = g as? GCDualShockGamepad { set(ds.touchpadButton.isPressed, Int32(TOUCHPAD_FLAG)) }
        if let xbox = g as? GCXboxGamepad { set(xbox.buttonShare?.isPressed ?? false, Int32(MISC_FLAG)) }

        func axis(_ v: Float) -> Int16 { Int16(max(-1, min(1, v)) * 32767) }
        func trigger(_ v: Float) -> UInt8 { UInt8(max(0, min(1, v)) * 255) }

        TwilightLog.debug(String(format: "Pad %d buttons %06x LT %.2f RT %.2f L (%.2f, %.2f) R (%.2f, %.2f)",
                                 number, flags, g.leftTrigger.value, g.rightTrigger.value,
                                 g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value,
                                 g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value))
        LiSendMultiControllerEvent(Int16(number), currentMask, flags,
                                   trigger(g.leftTrigger.value), trigger(g.rightTrigger.value),
                                   axis(g.leftThumbstick.xAxis.value), axis(g.leftThumbstick.yAxis.value),
                                   axis(g.rightThumbstick.xAxis.value), axis(g.rightThumbstick.yAxis.value))
    }

    func rumble(controller number: Int, lowFrequency: UInt16, highFrequency: UInt16) {
        lock.lock()
        guard let key = pads.first(where: { $0.value.number == number })?.key, var pad = pads[key], let engine = pad.haptics else {
            lock.unlock()
            return
        }
        let intensity = Float(max(lowFrequency, highFrequency)) / 65535
        let sharpness = lowFrequency > highFrequency ? Float(0.2) : Float(0.8)
        do {
            if intensity == 0 {
                try pad.rumblePlayer?.stop(atTime: CHHapticTimeImmediate)
                pad.rumblePlayer = nil
            } else if let player = pad.rumblePlayer {
                try player.sendParameters([
                    CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
                    CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0),
                ], atTime: CHHapticTimeImmediate)
            } else {
                let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
                ], relativeTime: 0, duration: 30)
                let player = try engine.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
                try player.start(atTime: CHHapticTimeImmediate)
                try player.sendParameters([
                    CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: intensity, relativeTime: 0),
                    CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0),
                ], atTime: CHHapticTimeImmediate)
                pad.rumblePlayer = player
            }
        } catch {
            pad.rumblePlayer = nil
        }
        pads[key] = pad
        lock.unlock()
    }

    // MARK: Keyboard

    private func attachKeyboard() {
        guard running, let keyboard = GCKeyboard.coalesced?.keyboardInput else { return }
        keyboard.keyChangedHandler = { [weak self] _, _, keyCode, pressed in
            self?.sendKey(hidUsage: keyCode.rawValue, pressed: pressed)
        }
    }

    /// Sends a key using its USB HID usage code (GCKeyCode raw value).
    public func sendKey(hidUsage: Int, pressed: Bool) {
        guard let vk = Self.virtualKey(forHidUsage: hidUsage) else { return }
        let modifier: Int8
        switch hidUsage {
        case 0xE0, 0xE4: modifier = Int8(MODIFIER_CTRL)
        case 0xE1, 0xE5: modifier = Int8(MODIFIER_SHIFT)
        case 0xE2, 0xE6: modifier = Int8(MODIFIER_ALT)
        case 0xE3, 0xE7: modifier = Int8(MODIFIER_META)
        default: modifier = 0
        }
        if pressed { keyboardModifiers |= modifier } else { keyboardModifiers &= ~modifier }
        LiSendKeyboardEvent(Int16(bitPattern: UInt16(0x8000) | vk), Int8(pressed ? KEY_ACTION_DOWN : KEY_ACTION_UP), keyboardModifiers)
    }

    /// Maps USB HID keyboard usages to Windows virtual-key codes, which GameStream hosts expect.
    static func virtualKey(forHidUsage u: Int) -> UInt16? {
        switch u {
        case 0x04...0x1D: return UInt16(0x41 + u - 0x04)           // A-Z
        case 0x1E...0x26: return UInt16(0x31 + u - 0x1E)           // 1-9
        case 0x27: return 0x30                                     // 0
        case 0x28: return 0x0D                                     // Return
        case 0x29: return 0x1B                                     // Escape
        case 0x2A: return 0x08                                     // Backspace
        case 0x2B: return 0x09                                     // Tab
        case 0x2C: return 0x20                                     // Space
        case 0x2D: return 0xBD                                     // -
        case 0x2E: return 0xBB                                     // =
        case 0x2F: return 0xDB                                     // [
        case 0x30: return 0xDD                                     // ]
        case 0x31, 0x32: return 0xDC                               // \
        case 0x33: return 0xBA                                     // ;
        case 0x34: return 0xDE                                     // '
        case 0x35: return 0xC0                                     // `
        case 0x36: return 0xBC                                     // ,
        case 0x37: return 0xBE                                     // .
        case 0x38: return 0xBF                                     // /
        case 0x39: return 0x14                                     // Caps Lock
        case 0x3A...0x45: return UInt16(0x70 + u - 0x3A)           // F1-F12
        case 0x46: return 0x2C                                     // Print Screen
        case 0x47: return 0x91                                     // Scroll Lock
        case 0x48: return 0x13                                     // Pause
        case 0x49: return 0x2D                                     // Insert
        case 0x4A: return 0x24                                     // Home
        case 0x4B: return 0x21                                     // Page Up
        case 0x4C: return 0x2E                                     // Delete
        case 0x4D: return 0x23                                     // End
        case 0x4E: return 0x22                                     // Page Down
        case 0x4F: return 0x27                                     // Right
        case 0x50: return 0x25                                     // Left
        case 0x51: return 0x28                                     // Down
        case 0x52: return 0x26                                     // Up
        case 0x53: return 0x90                                     // Num Lock
        case 0x54: return 0x6F                                     // Keypad /
        case 0x55: return 0x6A                                     // Keypad *
        case 0x56: return 0x6D                                     // Keypad -
        case 0x57: return 0x6B                                     // Keypad +
        case 0x58: return 0x0D                                     // Keypad Enter
        case 0x59...0x61: return UInt16(0x61 + u - 0x59)           // Keypad 1-9
        case 0x62: return 0x60                                     // Keypad 0
        case 0x63: return 0x6E                                     // Keypad .
        case 0x64: return 0xE2                                     // Non-US backslash
        case 0x65: return 0x5D                                     // Application
        case 0x68...0x73: return UInt16(0x7C + u - 0x68)           // F13-F24
        case 0xE0: return 0xA2                                     // Left Control
        case 0xE1: return 0xA0                                     // Left Shift
        case 0xE2: return 0xA4                                     // Left Alt/Option
        case 0xE3: return 0x5B                                     // Left Windows/Command
        case 0xE4: return 0xA3                                     // Right Control
        case 0xE5: return 0xA1                                     // Right Shift
        case 0xE6: return 0xA5                                     // Right Alt/Option
        case 0xE7: return 0x5C                                     // Right Windows/Command
        default: return nil
        }
    }

    // MARK: Mouse

    private func attachMouse(_ mouse: GCMouse) {
        guard running, let input = mouse.mouseInput else { return }
        input.mouseMovedHandler = { _, dx, dy in
            LiSendMouseMoveEvent(Int16(clamping: Int(dx.rounded())), Int16(clamping: Int(-dy.rounded())))
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendMouseButton(Int32(BUTTON_LEFT), pressed: pressed)
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendMouseButton(Int32(BUTTON_RIGHT), pressed: pressed)
        }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.sendMouseButton(Int32(BUTTON_MIDDLE), pressed: pressed)
        }
        input.scroll.yAxis.valueChangedHandler = { _, value in
            LiSendHighResScrollEvent(Int16(clamping: Int(value * 120)))
        }
    }

    // MARK: Pointer (gaze + pinch, or direct touch)

    public func sendMouseButton(_ button: Int32, pressed: Bool) {
        if pressed { mouseButtonsDown.insert(button) } else { mouseButtonsDown.remove(button) }
        let result = LiSendMouseButtonEvent(Int8(pressed ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE), button)
        if result != 0 {
            TwilightLog.error("Mouse button \(button) \(pressed ? "down" : "up") rejected: \(result)")
        }
    }

    /// Moves the host cursor to a point in stream coordinates.
    public func sendMousePosition(x: Double, y: Double, streamWidth: Int, streamHeight: Int) {
        let result = LiSendMousePositionEvent(Int16(clamping: Int(x)), Int16(clamping: Int(y)),
                                              Int16(clamping: streamWidth), Int16(clamping: streamHeight))
        if result != 0 {
            TwilightLog.error("Mouse position (\(Int(x)), \(Int(y))) rejected: \(result)")
        }
    }

    /// Moves the host cursor by a relative amount (in host pixels), like a real mouse.
    public func sendMouseMove(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        let result = LiSendMouseMoveEvent(Int16(clamping: dx), Int16(clamping: dy))
        if result != 0 {
            TwilightLog.error("Mouse move (\(dx), \(dy)) rejected: \(result)")
        }
    }

    public func sendScroll(amount: Double) {
        LiSendHighResScrollEvent(Int16(clamping: Int(amount)))
    }

    public func sendText(_ text: String) {
        let utf8 = Array(text.utf8)
        _ = utf8.withUnsafeBufferPointer { p in
            p.withMemoryRebound(to: CChar.self) { LiSendUtf8TextEvent($0.baseAddress, UInt32($0.count)) }
        }
    }
}
