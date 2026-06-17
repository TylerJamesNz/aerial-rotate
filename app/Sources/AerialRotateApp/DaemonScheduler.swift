import Foundation

/// Fires and reschedules the rotation, both WITHOUT a password. The privileged
/// work stays in the root daemon; the app only touches user-owned files:
///
/// - "Refresh now" bumps the mtime of the WatchPaths trigger (`Config.sentinel`).
///   The root daemon watches that path and runs the rotation as root, so no
///   admin prompt. Fire-and-forget: the run is async and `LogTailer` drives the
///   progress bar from the daemon's log.
/// - Reschedule rewrites the USER LaunchAgent plist (`Config.userAgentPlist`)
///   and reloads it in the user's GUI domain. The agent is user-owned, so this
///   needs no root either. The agent touches the trigger at the chosen time.
///
/// This replaces the old `NSAppleScript … with administrator privileges` path,
/// which prompted for a password on every click.
enum DaemonScheduler {

    enum Result {
        case success
        case failure(String)
    }

    /// Fire a rotation now by bumping the trigger's mtime. The dir is user-owned
    /// (created by install.sh), so no root is needed. Creates the file on first
    /// use. Returns immediately; the daemon runs async and `LogTailer` reports
    /// progress.
    static func runNow() -> Result {
        let path = Config.sentinel
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: path) {
                try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
            } else if !fm.createFile(atPath: path, contents: Data()) {
                return .failure("Could not create the trigger at \(path). Is the app installed?")
            }
            return .success
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Rewrite the user agent's whole `StartCalendarInterval` to fire at every
    /// time in `times`, then reload it in the GUI domain. All user-owned, so no
    /// password. The key is written in one shot as a JSON array (avoids fragile
    /// per-index `plutil` paths); an empty list removes the key entirely so the
    /// agent simply never auto-fires (manual Refresh still works).
    ///
    /// The JSON is built from validated integers only, so no user free-text
    /// reaches the shell, same safety posture as the old literal-int path.
    static func reschedule(times: [RotationTime]) -> Result {
        for t in times where !(0...23).contains(t.hour) || !(0...59).contains(t.minute) {
            return .failure("Time out of range (\(t.hour):\(t.minute)).")
        }
        // Dedupe by (hour, minute) and sort so the written schedule is canonical.
        var seen = Set<[Int]>()
        let clean = times.sorted().filter { seen.insert([$0.hour, $0.minute]).inserted }

        let plist = Config.userAgentPlist
        let uid = getuid()

        let writeCmd: String
        if clean.isEmpty {
            // -remove on an absent key exits non-zero; swallow so an
            // already-empty schedule still reloads cleanly.
            writeCmd = "/usr/bin/plutil -remove StartCalendarInterval '\(plist)' 2>/dev/null; true"
        } else {
            let json = "[" + clean.map { "{\"Hour\":\($0.hour),\"Minute\":\($0.minute)}" }.joined(separator: ",") + "]"
            writeCmd = "/usr/bin/plutil -replace StartCalendarInterval -json '\(json)' '\(plist)'"
        }

        let shell = """
        \(writeCmd) && \
        /bin/launchctl bootout gui/\(uid) '\(plist)' 2>/dev/null; \
        /bin/launchctl bootstrap gui/\(uid) '\(plist)'
        """
        let (code, output) = runShell(shell)
        // bootstrap exits non-zero only on a real load failure (bootout's
        // "not loaded" case is swallowed above), so the exit code is the verdict.
        return code == 0 ? .success
                         : .failure(output.isEmpty ? "launchctl exited \(code)." : output)
    }

    /// Run a shell line as the current (non-root) user, returning (exit code,
    /// combined stdout+stderr).
    private static func runShell(_ shell: String) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", shell]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, out)
    }
}
