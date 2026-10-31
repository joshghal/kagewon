import CoreGraphics
import Foundation

// Prints the id of the biggest on-screen window of an application, for `screencapture -l`, so that only that window is
// recorded and nothing else on the desktop. Usage: wid <application name>
let args = CommandLine.arguments
guard args.count == 2 else { exit(1) }
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (id: Int, area: Double)?
for w in list where (w[kCGWindowOwnerName as String] as? String) == args[1] {
    guard let b = w[kCGWindowBounds as String] as? [String: Any], let width = b["Width"] as? Double, let height = b["Height"] as? Double,
          let id = w[kCGWindowNumber as String] as? Int, width > 100, height > 100 else { continue }
    if best == nil || width * height > best!.area { best = (id, width * height) }
}
guard let found = best else { exit(2) }
print(found.id)
