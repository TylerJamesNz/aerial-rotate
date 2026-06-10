import Foundation

/// Reschedules the daemon's daily run time. This is the ONE privileged action:
/// it rewrites the root-owned LaunchDaemon plist and reloads it, so it goes
/// through an AppleScript `with administrator privileges` (native auth prompt,
/// Touch ID / password). A privileged helper (SMAppService) is not viable for a
/// self-signed CLT-only build, so one auth prompt per change is the trade-off.
enum DaemonScheduler {

    enum Result {
        case success
        case canceled            // operator dismissed the auth dialog
        case failure(String)
    }

    /// Rewrite StartCalendarInterval {Hour, Minute} and reload the daemon.
    static func reschedule(hour: Int, minute: Int) -> Result {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            return .failure("Time out of range (\(hour):\(minute)).")
        }

        // Validated integer literals only; no user free-text reaches the shell.
        let plist = Config.daemonPlist
        let shell = """
        /usr/bin/plutil -replace StartCalendarInterval.Hour -integer \(hour) '\(plist)' && \
        /usr/bin/plutil -replace StartCalendarInterval.Minute -integer \(minute) '\(plist)' && \
        /bin/launchctl bootout system '\(plist)' 2>/dev/null; \
        /bin/launchctl bootstrap system '\(plist)'
        """
        return executePrivileged(shell)
    }

    /// Run the rotation immediately, exactly as the daily LaunchDaemon does: the
    /// daemon's ProgramArguments are `/bin/bash <script>`, so we invoke the same
    /// script as root through the shared admin-auth prompt. Backs the "Refresh
    /// now" button for on-demand swaps and smoke testing. Blocks until the run
    /// finishes (~minutes) so the caller gets a real result; the log tailer
    /// drives the live progress bar meanwhile. Not via `launchctl kickstart`
    /// because the daemon isn't always bootstrapped.
    static func runNow() -> Result {
        executePrivileged("/bin/bash '\(Config.daemonScript)'")
    }

    /// Run a shell command as root via a native auth prompt (Touch ID / password).
    private static func executePrivileged(_ shell: String) -> Result {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: source)
        script?.executeAndReturnError(&errorInfo)

        if let err = errorInfo {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -128 { return .canceled }   // user canceled auth
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "Unknown error (\(code))."
            return .failure(msg)
        }
        return .success
    }
}
