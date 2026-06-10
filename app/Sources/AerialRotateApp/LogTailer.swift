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
    private let queue = DispatchQueue(label: "com.tyler.aerial-rotate.logtailer")

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

        let notifyLines = text.split(separator: "\n").filter { $0.contains("NOTIFY:") }
        guard let last = notifyLines.last.map(String.init),
              let payload = Self.payload(of: last) else { return }
        // Seed UI from the last event, but suppress banners during priming.
        applyParsed(payload, banner: false)
    }

    // MARK: - parsing

    private func parse(_ line: String) {
        guard let payload = Self.payload(of: line) else { return }
        applyParsed(payload, banner: true)
    }

    /// Returns the text after "NOTIFY: " for a log line, or nil if not a NOTIFY line.
    private static func payload(of line: String) -> String? {
        guard let range = line.range(of: "NOTIFY: ") else { return nil }
        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Interpret a `<title> - <msg>` NOTIFY payload, update AppState, and
    /// optionally post a banner.
    private func applyParsed(_ payload: String, banner: Bool) {
        let (title, msg) = Self.splitTitleMsg(payload)

        if title.hasPrefix("Downloading") {
            let name = String(title.dropFirst("Downloading".count)).trimmingCharacters(in: .whitespaces)
            let pct = Self.firstInt(in: msg, suffix: "%") ?? 0
            let mb = Self.firstInt(in: msg, suffix: "MB")
            let prog = DownloadProgress(name: name, percent: pct, megabytes: mb)
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
            DispatchQueue.main.async {
                AppState.shared.progress = nil
                AppState.shared.recordEvent("Failed: \(msg)")
            }
            if banner { postBanner("Aerial rotate failed", msg) }

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
