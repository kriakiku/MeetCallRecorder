import CoreGraphics

struct DetectedWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let ownerName: String
    let title: String
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
        for info in infoList {
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            let name = info[kCGWindowName as String] as? String ?? ""
            guard owner == ownerName, name.hasPrefix(titlePrefix) else { continue }
            let windowID = info[kCGWindowNumber as String] as? Int ?? -1
            let pid = info[kCGWindowOwnerPID as String] as? Int ?? -1
            return DetectedWindow(windowID: CGWindowID(windowID), pid: pid_t(pid), ownerName: owner, title: name)
        }
        return nil
    }
}
