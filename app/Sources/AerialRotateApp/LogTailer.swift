import Foundation

/// Watches the daemon's world-readable log and turns appended `NOTIFY:` lines
/// into UI updates + Notification Center banners. This is the daemon -> app
/// channel: no daemon change, the log is the existing source of truth.
///
/// Uses a vnode `DispatchSource` (lowest-overhead fit) rather than FSEvents
/// (directory-granular, batched) or mtime polling. Handles log rotation by
/// reopening from the start when the file is renamed/deleted.
final class LogTailer {
    private let path = Config.log
    private let queue = DispatchQueue(label: "com.aerialrotate.logtailer")

    private var fd: Int32 = -1
    private var source: DispatchSourceFileSystemObject?
    private var offset: off_t = 0
    private var carry = Data()
    private var downloadBannerShown = false   // gate the "started" banner to once per download

    func start() {
        queue.async { [weak self] in
            self?.primeFromTail()
            self?.openAndWatch()
        }
        DispatchQueue.main.async { AppState.shared.refresh() }
    }

    // MARK: - watch lifecycle

    private func openAndWatch() {
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { retrySoon(); return }
        offset = lseek(fd, 0, SEEK_END)   // primeFromTail already seeded UI; watch only new lines

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            self.handle(src.data)
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    private func handle(_ event: DispatchSource.FileSystemEvent) {
        if event.contains(.delete) || event.contains(.rename) || event.contains(.revoke) {
            // Log rotated/recreated: tear down and reopen from the top.
            source?.cancel()
            source = nil
            offset = 0
            carry.removeAll()
            retrySoon()
            return
        }
        readAppended()
    }

    private func retrySoon() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            if self.source == nil { self.openAndWatch() }
        }
    }

    // MARK: - reading

    private func readAppended() {
        let end = lseek(fd, 0, SEEK_END)
        if end < offset { offset = 0 }   // truncated in place
        let count = Int(end - offset)
        guard count > 0 else { return }

        var buf = [UInt8](repeating: 0, count: count)
        let n = pread(fd, &buf, count, offset)
        guard n > 0 else { return }
        offset += off_t(n)
        carry.append(contentsOf: buf[0..<n])
        emitCompleteLines()
    }

    private func emitCompleteLines() {
        while let nl = carry.firstIndex(of: 0x0A) {
            let lineData = carry.subdata(in: carry.startIndex..<nl)
            carry.removeSubrange(carry.startIndex...nl)
            if let line = String(data: lineData, encoding: .utf8) {
                parse(line)
            }
        }
    }

    /// Read the last ~8 KB on launch to reconstruct the current state (last
    /// event, and whether a download appears to be in flight) without bannering.
    /// Also seeds preflight banner state from the last PREFLIGHT: FAIL / WARN
    /// line so the UI shows the daemon's last-known health on cold start, not
    /// only after the next run.
    private func primeFromTail() {
        let f = open(path, O_RDONLY)
        guard f >= 0 else { return }
        defer { close(f) }
        let end = lseek(f, 0, SEEK_END)
        let window: off_t = 8192
        let start = max(0, end - window)
        lseek(f, start, SEEK_SET)
        var buf = [UInt8](repeating: 0, count: Int(end - start))
        let n = read(f, &buf, buf.count)
        guard n > 0, let text = String(bytes: buf[0..<n], encoding: .utf8) else { return }

        let lines = text.split(separator: "\n").map(String.init)

        // Walk every line in order so PREFLIGHT: OK lines that clear earlier
        // FAILs (a successful run after a failed one) win, and the most recent
        // NOTIFY: applied clears the preflight banner. Suppress banners during
        // priming so a cold launch doesn't spam a tray of historical events.
        for line in lines {
            if line.contains("PREFLIGHT:") {
                Self.applyPreflight(line: line)
            } else if let payload = Self.payload(of: line) {
                applyParsed(payload, banner: false)
            }
        }
    }

    // MARK: - parsing

    private func parse(_ line: String) {
        // PREFLIGHT: lines are the daemon's own health stream; classify them
        // before the NOTIFY: payload check so OK / WARN / FAIL banners land
        // even when no NOTIFY follows (typical for warn-only runs).
        if line.contains("PREFLIGHT:") {
            Self.applyPreflight(line: line)
            return
        }
        guard let payload = Self.payload(of: line) else { return }
        applyParsed(payload, banner: true)
    }

    /// Returns the text after "NOTIFY: " for a log line, or nil if not a NOTIFY line.
    private static func payload(of line: String) -> String? {
        guard let range = line.range(of: "NOTIFY: ") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Parse a `PREFLIGHT: <LEVEL> <check> [key=value ...]` line and update
    /// AppState. Anchored on the `PREFLIGHT: ` substring; surrounding timestamp
    /// is ignored. OK lines clear the matching failure or update resolvedUser;
    /// WARN lines flip informational flags; FAIL lines set `state.preflight`.
    private static func applyPreflight(line: String) {
        guard let range = line.range(of: "PREFLIGHT: ") else { return }
        let tail = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        let tokens = tail.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard tokens.count >= 1 else { return }
        let level = String(tokens[0])
        let rest = tokens.count > 1 ? String(tokens[1]) : ""

        let restTokens = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let check = restTokens.first.map(String.init) ?? ""
        let kvText = restTokens.count > 1 ? String(restTokens[1]) : ""
        let fields = Self.parseFields(kvText)

        DispatchQueue.main.async {
            dispatchPreflight(level: level, check: check, fields: fields)
        }
    }

    private static func parseFields(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for token in text.split(separator: " ") {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            out[String(parts[0])] = String(parts[1])
        }
        return out
    }

    @MainActor
    private static func dispatchPreflight(level: String, check: String, fields: [String: String]) {
        let state = AppState.shared
        switch (level, check) {
        case ("OK", "user.console"):
            state.resolvedUser = fields["target_user"]
        case ("OK", "dialog"):
            state.dialogPresent = true
        case ("WARN", "dialog.missing"):
            state.dialogPresent = false
        case ("FAIL", "user.no_gui_session"):
            state.preflight = .noGUIUser
        case ("FAIL", "catalog.missing"):
            state.preflight = .catalogMissing(path: fields["path"] ?? "")
        case ("FAIL", "catalog.malformed"):
            state.preflight = .catalogMalformed(path: fields["path"] ?? "")
        case ("FAIL", "catalog.empty"):
            state.preflight = .catalogEmpty(path: fields["path"] ?? "")
        case ("FAIL", "store.missing"):
            state.preflight = .wallpaperStoreMissing(path: fields["path"] ?? "")
        case ("FAIL", "store.schema_changed"):
            state.preflight = .schemaShifted
        case ("FAIL", "source"):
            let provider = fields["provider"] ?? ""
            state.preflight = provider == "<unset>" ? .wallpaperSourceUnset : .wallpaperSourceWrong(provider: provider)
        case ("OK", _):
            // Mirror image of the FAIL above: a fresh OK on the same check
            // clears a stale FAIL so the banner doesn't linger past recovery.
            if case .wallpaperSourceWrong = state.preflight, check == "source" { state.preflight = nil }
            if case .wallpaperSourceUnset = state.preflight, check == "source" { state.preflight = nil }
            if case .wallpaperStoreMissing = state.preflight, check == "store.exists" { state.preflight = nil }
            if case .schemaShifted = state.preflight, check == "store.schema" { state.preflight = nil }
            if case .catalogMissing = state.preflight, check == "catalog" { state.preflight = nil }
            if case .catalogMalformed = state.preflight, check == "catalog" { state.preflight = nil }
            if case .catalogEmpty = state.preflight, check == "catalog" { state.preflight = nil }
        default:
            break
        }
    }

    /// Interpret a `<title> - <msg>` NOTIFY payload, update AppState, and
    /// optionally post a banner.
    private func applyParsed(_ payload: String, banner: Bool) {
        let (title, msg) = Self.splitTitleMsg(payload)

        if title.hasPrefix("Downloading") {
            var name = String(title.dropFirst("Downloading".count)).trimmingCharacters(in: .whitespaces)
            // The daemon appends the asset id in brackets ("Downloading Yosemite
            // [<uuid>]") so the UI can tell same-named aerials apart. Peel it off;
            // older log lines without brackets leave assetID nil.
            var assetID: String? = nil
            if name.hasSuffix("]"), let open = name.lastIndex(of: "[") {
                assetID = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
                name = String(name[..<open]).trimmingCharacters(in: .whitespaces)
            }
            let pct = Self.firstInt(in: msg, suffix: "%") ?? 0
            let mb = Self.firstInt(in: msg, suffix: "MB")
            let prog = DownloadProgress(name: name, percent: pct, megabytes: mb, assetID: assetID)
            DispatchQueue.main.async {
                AppState.shared.progress = prog
                AppState.shared.recordEvent("Downloading \(name): \(pct)%")
            }
            if banner && !downloadBannerShown {
                downloadBannerShown = true
                postBanner("Downloading aerial", name.isEmpty ? "Fetching a new wallpaper" : name)
            }

        } else if title.contains("applied") {           // "✅ New wallpaper applied"
            downloadBannerShown = false
            DispatchQueue.main.async {
                AppState.shared.progress = nil
                AppState.shared.preflight = nil   // a successful run clears any prior failure
                AppState.shared.recordEvent(msg)
                AppState.shared.refresh()
            }
            if banner { postBanner("Aerial wallpaper updated", msg) }

        } else if title.contains("Downloaded") {         // "Downloaded — applying"
            DispatchQueue.main.async {
                if AppState.shared.progress != nil { AppState.shared.progress?.percent = 100 }
                AppState.shared.recordEvent("Applying \(msg)")
            }

        } else if title.contains("failed") {             // "Aerial rotate failed"
            downloadBannerShown = false
            // Peel the optional "code=<token> " prefix the daemon's die() helper
            // emits so the banner can render a typed FatalBanner. Without code=
            // we fall through to a generic runtimeError.
            let (code, detail) = Self.peelCode(msg)
            DispatchQueue.main.async {
                AppState.shared.progress = nil
                AppState.shared.recordEvent("Failed: \(detail)")
                if let code = code {
                    AppState.shared.preflight = .runtimeError(code: code, detail: detail)
                }
            }
            if banner { postBanner("Aerial rotate failed", detail) }

        } else if title.contains("Retrying") {
            DispatchQueue.main.async { AppState.shared.recordEvent("Retrying: \(msg)") }
            if banner { postBanner("Retrying download", msg) }

        } else if title.contains("Prefetch") {           // "Prefetch check"
            DispatchQueue.main.async {
                AppState.shared.recordEvent("Prefetch: \(msg)")
                AppState.shared.refresh()
            }
            if banner { postBanner("Prefetch check", msg) }

        } else {
            DispatchQueue.main.async { AppState.shared.recordEvent(payload) }
        }
    }

    private func postBanner(_ title: String, _ body: String) {
        DispatchQueue.main.async { Notifier.shared.post(title: title, body: body) }
    }

    // MARK: - string helpers

    private static func splitTitleMsg(_ payload: String) -> (String, String) {
        if let r = payload.range(of: " - ") {
            return (String(payload[..<r.lowerBound]), String(payload[r.upperBound...]))
        }
        return (payload, "")
    }

    /// Split a NOTIFY failed message into (code, detail). die() in the daemon
    /// emits `code=<token> <detail>` when called with a code= prefix; older log
    /// lines and uncoded failures return nil for the code.
    private static func peelCode(_ msg: String) -> (String?, String) {
        guard msg.hasPrefix("code=") else { return (nil, msg) }
        let afterCode = msg.dropFirst("code=".count)
        guard let sp = afterCode.firstIndex(of: " ") else { return (String(afterCode), "") }
        return (String(afterCode[..<sp]), String(afterCode[afterCode.index(after: sp)...]))
    }

    /// First integer immediately preceding `suffix` (e.g. "40" for "40%", "123"
    /// for "123 MB" or "123MB"). Scans tokens to stay tolerant of "0% of 123 MB"
    /// and "40% (123 MB)" shapes.
    private static func firstInt(in text: String, suffix: String) -> Int? {
        let tokens = text.replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .split(whereSeparator: { $0 == " " })
            .map(String.init)
        for (i, tok) in tokens.enumerated() {
            if suffix == "%" {
                if let v = Int(tok.replacingOccurrences(of: "%", with: "")), tok.contains("%") { return v }
            } else { // "MB" — either "123MB" in one token or "123" then "MB"
                if tok.uppercased() == "MB", i > 0, let v = Int(tokens[i-1]) { return v }
                if tok.uppercased().hasSuffix("MB"),
                   let v = Int(tok.dropLast(2)) { return v }
            }
        }
        return nil
    }
}
