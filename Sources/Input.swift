import AppKit
import CoreGraphics

/// Posts synthetic mouse / keyboard / media events. Needs Accessibility permission.
enum Input {
    static func move(to p: CGPoint, dragging: Bool) {
        let type: CGEventType = dragging ? .leftMouseDragged : .mouseMoved
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func mouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, clicks: Int64 = 1) {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventClickState, value: clicks)
        e?.post(tap: .cghidEventTap)
    }

    static func rightClick(at p: CGPoint) {
        mouse(.rightMouseDown, at: p, button: .right)
        mouse(.rightMouseUp, at: p, button: .right)
    }

    static func scroll(_ dy: Int32) {
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                wheel1: dy, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    // Arrow key codes
    static let left: CGKeyCode = 123, right: CGKeyCode = 124, down: CGKeyCode = 125, up: CGKeyCode = 126

    /// Play / pause media key (works for Music, Spotify, YouTube in browsers).
    static func playPause() { mediaKey(16) }   // NX_KEYTYPE_PLAY

    private static func mediaKey(_ key: Int32) {
        func post(_ isDown: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: isDown ? 0xa00 : 0xb00)
            let data1 = Int((key << 16) | ((isDown ? 0xa : 0xb) << 8))
            let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                        timestamp: 0, windowNumber: 0, context: nil,
                                        subtype: 8, data1: data1, data2: -1)
            ev?.cgEvent?.post(tap: .cghidEventTap)
        }
        post(true)
        post(false)
    }

    static var currentCursor: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
