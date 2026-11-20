import Foundation

public enum ADBParsers {
    /// Safely escapes a string for POSIX `/system/bin/sh` using single quotes.
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Normalizes a POSIX remote path (always starts with `/`, no trailing `/` except root).
    public static func normalizeRemotePath(_ path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "/" }
        if !trimmed.hasPrefix("/") {
            trimmed = "/" + trimmed
        }
        var parts: [String] = []
        for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." {
                continue
            } else if component == ".." {
                if !parts.isEmpty { parts.removeLast() }
            } else {
                parts.append(String(component))
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Joins a remote directory and child name cleanly.
    public static func joinRemotePath(_ base: String, _ name: String) -> String {
        let normalizedBase = normalizeRemotePath(base)
        let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if cleanName.isEmpty { return normalizedBase }
        if normalizedBase == "/" { return "/" + cleanName }
        return normalizedBase + "/" + cleanName
    }

    /// Returns the parent directory of a remote path.
    public static func parentRemotePath(_ path: String) -> String {
        let normalized = normalizeRemotePath(path)
        if normalized == "/" { return "/" }
        var components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return "/" }
        components.removeLast()
        return "/" + components.joined(separator: "/")
    }

    /// Splits a remote path into clickable breadcrumb `(title, fullPath)` segments.
    public static func remoteBreadcrumbs(for path: String) -> [(title: String, path: String)] {
        let normalized = normalizeRemotePath(path)
        var crumbs: [(String, String)] = [("/", "/")]
        var running = ""
        for part in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            running += "/\(part)"
            crumbs.append((String(part), running))
        }
        return crumbs
    }

    /// Parses `adb devices -l` output into `AndroidDevice` entries.
    public static func parseDevices(_ output: String) -> [AndroidDevice] {
        var devices: [AndroidDevice] = []
        let lines = output.components(separatedBy: .newlines)

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty
                || line.hasPrefix("List of devices")
                || line.hasPrefix("*")
            {
                continue
            }

            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2 else { continue }

            let serial = tokens[0]
            let stateToken = tokens[1]
            let state = DeviceState(rawValue: stateToken) ?? .unknown

            var model: String?
            var product: String?
            var deviceName: String?
            var transportId: String?

            for token in tokens.dropFirst(2) {
                if let colonIdx = token.firstIndex(of: ":") {
                    let key = String(token[..<colonIdx])
                    let val = String(token[token.index(after: colonIdx)...])
                    switch key {
                    case "model": model = val
                    case "product": product = val
                    case "device": deviceName = val
                    case "transport_id": transportId = val
                    default: break
                    }
                }
            }

            devices.append(
                AndroidDevice(
                    serial: serial,
                    state: state,
                    model: model,
                    product: product,
                    deviceName: deviceName,
                    transportId: transportId
                )
            )
        }
        return devices
    }

    // Standard Android toybox `ls -la`:
    // drwxrwx--- 4 u0_a123 media_rw 3452 2025-10-31 14:22 DCIM
    // -rw-rw---- 1 u0_a123 media_rw 4512345 2025-11-01 09:15 My Photo.jpg
    // Also handles optional link count (legacy Android toolbox) and SELinux/ACL suffix.
    private static let isoListRegex = try! NSRegularExpression(
        pattern: #"^([dlcbps-])([rwxstST-]{9}[+@.]?)\s+(?:\d+\s+)?\S+\s+\S+\s+(?:(\d+)|\d+,\s*\d+)\s+(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})\s+(.+)$"#
    )

    // BusyBox / BSD style `ls -la`:
    // drwxr-xr-x 2 root root 4096 Oct 31 14:22 Download
    // -rw-r--r-- 1 root root 1024 Oct 31  2024 notes.txt
    private static let bsdListRegex = try! NSRegularExpression(
        pattern: #"^([dlcbps-])([rwxstST-]{9}[+@.]?)\s+(?:\d+\s+)?\S+\s+\S+\s+(?:(\d+)|\d+,\s*\d+)\s+([A-Z][a-z]{2}\s+\d{1,2}\s+(?:\d{2}:\d{2}|\d{4}))\s+(.+)$"#
    )

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    /// Parses `ls -la` output from an Android shell into `FileEntry` records.
    public static func parseListOutput(_ output: String, directory: String) -> [FileEntry] {
        let baseDir = normalizeRemotePath(directory)
        var entries: [FileEntry] = []

        let normalizedOutput = output.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        for line in normalizedOutput.components(separatedBy: "\n") {
            if line.isEmpty || line.hasPrefix("total ") {
                continue
            }

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            let match: NSTextCheckingResult?
            let isISO: Bool
            if let isoMatch = isoListRegex.firstMatch(in: line, range: fullRange) {
                match = isoMatch
                isISO = true
            } else if let bsdMatch = bsdListRegex.firstMatch(in: line, range: fullRange) {
                match = bsdMatch
                isISO = false
            } else {
                continue
            }

            guard let m = match else { continue }

            let typeChar = nsLine.substring(with: m.range(at: 1))
            let perms = typeChar + nsLine.substring(with: m.range(at: 2))
            let sizeStr = m.range(at: 3).location != NSNotFound ? nsLine.substring(with: m.range(at: 3)) : "0"
            let dateStr = nsLine.substring(with: m.range(at: 4))
            let rawName = nsLine.substring(with: m.range(at: 5))

            let isSymlink = (typeChar == "l")
            var name = rawName
            var symlinkTarget: String? = nil

            if isSymlink, let arrowRange = rawName.range(of: " -> ") {
                name = String(rawName[..<arrowRange.lowerBound])
                symlinkTarget = String(rawName[arrowRange.upperBound...])
            }

            if name == "." || name == ".." || name.isEmpty {
                continue
            }

            let isDirectory = (typeChar == "d")
            let size = Int64(sizeStr) ?? 0
            let parsedDate: Date? = isISO ? isoDateFormatter.date(from: dateStr) : nil
            let fullPath = joinRemotePath(baseDir, name)

            entries.append(
                FileEntry(
                    name: name,
                    path: fullPath,
                    isDirectory: isDirectory,
                    isSymlink: isSymlink,
                    symlinkTarget: symlinkTarget,
                    size: size,
                    modifiedDate: parsedDate,
                    modifiedText: dateStr,
                    permissions: perms,
                    isRemote: true
                )
            )
        }

        return entries
    }

    /// Parses `df -k <path>` output into `StorageInfo`.
    public static func parseStorageOutput(_ output: String) -> StorageInfo? {
        let lines = output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { return nil }
        // Data row may wrap across two lines if filesystem name is long; join everything after header.
        let dataTokens = lines.dropFirst()
            .joined(separator: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)

        // Expected columns: Filesystem 1K-blocks Used Available Use% Mounted-on
        // Find the first sequence of 3 consecutive integers (total, used, available).
        for idx in 0..<dataTokens.count {
            if idx + 2 < dataTokens.count,
               let totalKB = Int64(dataTokens[idx]),
               let usedKB = Int64(dataTokens[idx + 1]),
               let availKB = Int64(dataTokens[idx + 2]),
               totalKB > 0
            {
                return StorageInfo(
                    totalBytes: totalKB * 1024,
                    usedBytes: usedKB * 1024,
                    availableBytes: availKB * 1024
                )
            }
        }
        return nil
    }

    private static let progressRegex = try! NSRegularExpression(
        pattern: #"\[\s*(\d{1,3})%\]\s*(.+)"#
    )

    /// Parses an `adb push` / `adb pull` progress line such as `[ 42%] /sdcard/Download/video.mp4`.
    public static func parseProgressLine(_ line: String) -> (percent: Double?, currentFile: String?) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        let nsLine = trimmed as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        if let match = progressRegex.firstMatch(in: trimmed, range: range) {
            let pctStr = nsLine.substring(with: match.range(at: 1))
            let fileStr = nsLine.substring(with: match.range(at: 2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let pct = (Double(pctStr) ?? 0) / 100.0
            let fileName = (fileStr as NSString).lastPathComponent
            return (min(1.0, max(0.0, pct)), fileName.isEmpty ? fileStr : fileName)
        }
        return (nil, nil)
    }
}
