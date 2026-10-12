import CoreGraphics
import Foundation

struct DetectedWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String
    /// Live on-screen bounds in points, from `kCGWindowBounds` - used to
    /// detect resize (same windowID, new size) without needing a fresh
    /// ScreenCaptureKit content fetch just to check dimensions.
    let bounds: CGRect
    /// Identifies the specific call, not just the app - the quoted meeting
    /// code for Meet (`Meet: "ggg-www-ppp"` -> `ggg-www-ppp`), or the raw
    /// title for Slack (no structured code is exposed there, so the title
    /// itself is the best available differentiator). Used to tell "the
    /// window changed shape/ID but it's still the same call" (reattach,
    /// same recording) apart from "a genuinely different call is now
    /// active" (finish this recording, start a new one) - and goes into
    /// the output filename so you can tell calls apart in Finder.
    let callID: String
}

enum WindowDetector {
    /// Finds the first on-or-offscreen window owned by `ownerName` whose
    /// title starts with `titlePrefix`. `.optionAll` (not `.optionOnScreenOnly`)
    /// matters here: a call window that's occluded by other windows (very
    /// common - the whole point of recording in the background) is still
    /// "on screen" in Quartz's sense but gets silently dropped by the
    /// on-screen-only option.
    static func findWindow(ownerName: String, titlePrefix: String) -> DetectedWindow? {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: AnyObject]] else {
            return nil
        }
        var matches: [DetectedWindow] = []
        for info in infoList {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let name = info[kCGWindowName as String] as? String ?? ""
            guard owner == ownerName, name.hasPrefix(titlePrefix) else { continue }
            let windowID = info[kCGWindowNumber as String] as? Int ?? -1
            let pid = info[kCGWindowOwnerPID as String] as? Int ?? -1
            let boundsDict = info[kCGWindowBounds as String] as? NSDictionary
            let bounds = boundsDict.flatMap { CGRect(dictionaryRepresentation: $0) } ?? .zero
            let callID = extractCallID(ownerName: owner, title: name)
            matches.append(DetectedWindow(windowID: CGWindowID(windowID), pid: pid_t(pid), ownerName: owner, title: name, bounds: bounds, callID: callID))
        }
        // Several windows can match at once: entering fullscreen, the app
        // opens a *new*, display-sized window for the call and leaves the
        // original behind on the desktop as a "click to exit fullscreen"
        // placeholder - same owner, same title. First-in-z-order picked
        // the placeholder, so the recording showed the placeholder text
        // instead of the call. The call is wherever the pixels are: take
        // the largest window, and the reattach-on-new-windowID path moves
        // the capture there (and back, once the fullscreen window goes
        // away again).
        let best = matches.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        if matches.count > 1, let best {
            let described = matches.map { "#\($0.windowID) \(Int($0.bounds.width))x\(Int($0.bounds.height))" }.joined(separator: ", ")
            FileHandle.standardError.write("[\(ISO8601DateFormatter().string(from: Date()))] \(matches.count) windows match '\(titlePrefix)': \(described) -> picked #\(best.windowID)\n".data(using: .utf8)!)
        }
        return best
    }

    private static func extractCallID(ownerName: String, title: String) -> String {
        if ownerName == "Google Meet",
           let start = title.firstIndex(of: "\""),
           let end = title.lastIndex(of: "\""), start < end {
            let code = title[title.index(after: start)..<end]
            if !code.isEmpty { return String(code) }
        }
        return title
    }
}
