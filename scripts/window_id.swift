// Prints the window number of the running app's main window (for screencapture -l).
import CoreGraphics
let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Spectrogram Studio"
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
let windows = list.filter { ($0[kCGWindowOwnerName as String] as? String) == owner && ($0[kCGWindowLayer as String] as? Int) == 0 }
// Largest window first (the main window rather than a sheet or the Settings window).
if let w = windows.max(by: { area($0) < area($1) }) { print(w[kCGWindowNumber as String]!) }
func area(_ w: [String: Any]) -> Double {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (b["Width"] ?? 0) * (b["Height"] ?? 0)
}
