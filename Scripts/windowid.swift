import CoreGraphics
import Foundation

// Prints the CoreGraphics window number for the named app's largest on-screen window.
//
// `screencapture -R <rect>` grabs a screen *region*, so any window sitting on top of the
// target ends up in the image instead. `screencapture -l <windowid>` captures the window's
// own backing store, which is correct even when the window is occluded or partly offscreen.

let appName = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "BetterClaude"

guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                               kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write(Data("could not list windows\n".utf8))
    exit(1)
}

let matches = windows.compactMap { info -> (Int, Double, Double, Double, Double, Double)? in
    guard let owner = info[kCGWindowOwnerName as String] as? String, owner == appName,
          let number = info[kCGWindowNumber as String] as? Int,
          let bounds = info[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
          let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
          width > 200, height > 200
    else { return nil }
    return (number, width * height, x, y, width, height)
}

guard let best = matches.max(by: { $0.1 < $1.1 }) else {
    FileHandle.standardError.write(Data("no window found for \(appName)\n".utf8))
    exit(2)
}
// `--bounds` prints "x y w h" in screen points so a caller can click at a known offset
// inside the window without going through the accessibility API, which is unreliable while
// the app is doing work on the main thread.
if CommandLine.arguments.contains("--bounds") {
    print("\(Int(best.2)) \(Int(best.3)) \(Int(best.4)) \(Int(best.5))")
} else {
    print(best.0)
}
