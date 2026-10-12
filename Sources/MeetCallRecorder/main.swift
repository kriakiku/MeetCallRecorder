import AppKit

// No permission request here on purpose. `CGRequestScreenCaptureAccess()`
// used to run at startup, which raised the system prompt before the user
// had been told what the app even was - and on every subsequent launch it
// was a no-op that reported nothing, so a missing grant looked identical
// to a working app. Asking is now the welcome screen's job; see
// AppDelegate.applicationDidFinishLaunching.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
