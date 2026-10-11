import AppKit
import CoreGraphics

if !CGRequestScreenCaptureAccess() {
    FileHandle.standardError.write("Screen Recording access not granted\n".data(using: .utf8)!)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
