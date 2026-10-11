import Foundation

/// Moves finished recordings from local staging to the mounted [Speakr]
/// SMB share, where Speakr's Black Hole Processing picks them up. Never
/// records directly to the share - if it drops mid-call, recording just
/// keeps going locally and gets synced whenever the share comes back.
enum Syncer {
    static func sync(stagingDir: URL, destDir: URL) -> Int {
        guard FileManager.default.fileExists(atPath: destDir.path) else {
            return 0
        }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: stagingDir, includingPropertiesForKeys: nil) else {
            return 0
        }
        var moved = 0
        for file in files where file.pathExtension == "mp4" {
            let dest = destDir.appendingPathComponent(file.lastPathComponent)
            do {
                if fm.fileExists(atPath: dest.path) {
                    try fm.removeItem(at: dest)
                }
                try fm.copyItem(at: file, to: dest)
                try fm.removeItem(at: file)
                moved += 1
            } catch {
                FileHandle.standardError.write("sync failed for \(file.lastPathComponent): \(error)\n".data(using: .utf8)!)
            }
        }
        return moved
    }
}
