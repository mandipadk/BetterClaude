import CoreGraphics
import Foundation

// Posts a real mouse click at an absolute screen point.
//
// `System Events`' `click at` is unreliable — it silently no-ops depending on which process
// is frontmost — and the accessibility API cannot be used here because element indices shift
// as panes expand and AX queries fail while the app is busy on its main thread. A posted
// CGEvent is what the window server itself would deliver.

guard CommandLine.arguments.count >= 3,
      let x = Double(CommandLine.arguments[1]),
      let y = Double(CommandLine.arguments[2]) else {
    FileHandle.standardError.write(Data("usage: click <x> <y>\n".utf8))
    exit(1)
}

let point = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)

CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(60_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(40_000)
CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
        mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
