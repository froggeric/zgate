// Posts a real CGEvent mouse click at a status item's position.
// Usage: click_status_item.swift <pid>
//
// macOS 26.2 MenuBarExtra popovers do not open from System Events' AXPress /
// "click at" (Task 9 executor finding); a real CGEvent click does. This reads
// the item's frame through System Events (reading works fine — only clicking
// is neutered) and posts the click from this process, which needs the same
// Accessibility grant as any CGEvent poster.
import AppKit
import Foundation

let pid = Int32(CommandLine.arguments.dropFirst().first ?? "") ?? {
    FileHandle.standardError.write("usage: click_status_item.swift <pid>\n".data(using: .utf8)!)
    exit(2)
}()

let script = """
tell application "System Events" to tell (first process whose unix id is \(pid)) \
    to get {position, size} of menu bar item 1 of menu bar 2
"""
var error: NSDictionary?
let result = NSAppleScript(source: script)!.executeAndReturnError(&error)
let parts = result.description
    .components(separatedBy: CharacterSet(charactersIn: ", "))
    .compactMap { Int($0) }
guard parts.count == 4 else {
    FileHandle.standardError.write("could not read status item frame: \(error ?? "nil" as NSString)\n".data(using: .utf8)!)
    exit(1)
}
let point = CGPoint(x: CGFloat(parts[0] + parts[2] / 2), y: CGFloat(parts[1] + parts[3] / 2))

let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)!
let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)!
down.post(tap: .cghidEventTap)
up.post(tap: .cghidEventTap)
print("clicked at \(Int(point.x)),\(Int(point.y))")
