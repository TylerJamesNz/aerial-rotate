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

    /// Rewrite the user agent's StartCalendarInterval {Hour, Minute} and reload
    /// it in the GUI domain. All user-owned, so no password. Validated integer
    /// literals only; no user free-text reaches the shell.
    static func reschedule(hour: Int, minute: Int) -> Result {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            return .failure("Time out of range (\(hour):\(minute)).")
        }
        let plist = Config.userAgentPlist
        let uid = getuid()
        let shell = """
        /usr/bin/plutil -replace StartCalendarInterval.Hour -integer \(hour) '\(plist)' && \
        /usr/bin/plutil -replace StartCalendarInterval.Minute -integer \(minute) '\(plist)' && \
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
