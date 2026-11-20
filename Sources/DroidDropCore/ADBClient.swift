import Foundation
import Darwin

/// Thread-safe handle allowing cancellation of an in-flight `Process`.
public final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public func set(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled {
            return false
        }
        self.process = process
        return true
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        self.process = nil
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let current = process
        lock.unlock()
        if let current, current.isRunning {
            current.terminate()
        }
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public final class ADBClient: @unchecked Sendable {
    private let lock = NSLock()
    private var _customADBPath: String?

    public init(customADBPath: String? = nil) {
        self._customADBPath = customADBPath
    }

    public var customADBPath: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _customADBPath
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _customADBPath = newValue
        }
    }

    /// Searches user setting, common macOS locations, and PATH for `adb`.
    public static func discoverADBPath(customPath: String? = nil) -> String? {
        let fm = FileManager.default

        if let custom = customPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty,
           fm.isExecutableFile(atPath: custom)
        {
            return custom
        }

        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = [
            "\(home)/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(home)/Android/Sdk/platform-tools/adb"
        ]

        if let envHome = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            candidates.insert("\(envHome)/platform-tools/adb", at: 0)
        }
        if let envRoot = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] {
            candidates.insert("\(envRoot)/platform-tools/adb", at: 0)
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                candidates.append("\(dir)/adb")
            }
        }

        for candidate in candidates {
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public func resolvedADBPath() throws -> String {
        guard let path = Self.discoverADBPath(customPath: customADBPath) else {
            throw ADBError.adbNotFound
        }
        return path
    }

    // MARK: - Device Management

    public func listDevices() async throws -> [AndroidDevice] {
        let res = try await runADB(["devices", "-l"])
        if res.exitCode != 0 {
            throw ADBError.commandFailed(res.stderr.isEmpty ? res.stdout : res.stderr)
        }
        return ADBParsers.parseDevices(res.stdout)
    }

    public func connectWifi(address: String) async throws -> String {
        let cleaned = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ADBError.invalidInput("Enter an IP address and port (e.g., 192.168.1.42:5555).")
        }
        let res = try await runADB(["connect", cleaned])
        let combined = (res.stdout + "\n" + res.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if res.exitCode != 0 || combined.lowercased().contains("failed") || combined.lowercased().contains("cannot") {
            throw ADBError.commandFailed(combined)
        }
        return combined
    }

    public func restartServer() async throws {
        _ = try await runADB(["kill-server"])
        let startRes = try await runADB(["start-server"])
        if startRes.exitCode != 0 {
            throw ADBError.commandFailed(startRes.stderr.isEmpty ? startRes.stdout : startRes.stderr)
        }
    }

    // MARK: - Remote Filesystem Operations

    public func listDirectory(serial: String, path: String, showHidden: Bool) async throws -> [FileEntry] {
        let normalized = ADBParsers.normalizeRemotePath(path)
        let quotedDir = ADBParsers.shellQuote(normalized == "/" ? "/" : normalized + "/")
        let res = try await runADB(["-s", serial, "shell", "ls -la \(quotedDir)"])

        let stdoutTrimmed = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderrTrimmed = res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if res.exitCode != 0 && stdoutTrimmed.isEmpty {
            throw ADBError.commandFailed(stderrTrimmed.isEmpty ? "Cannot open \(normalized)" : stderrTrimmed)
        }
        if stdoutTrimmed.contains("Permission denied") && !stdoutTrimmed.contains("\n") {
            throw ADBError.commandFailed(stdoutTrimmed)
        }
        if stdoutTrimmed.contains("No such file or directory") && !stdoutTrimmed.contains("\n") {
            throw ADBError.commandFailed(stdoutTrimmed)
        }

        var entries = ADBParsers.parseListOutput(res.stdout, directory: normalized)
        if !showHidden {
            entries.removeAll { $0.isHidden }
        }
        return entries
    }

    public func isRemoteDirectory(serial: String, path: String) async -> Bool {
        let quoted = ADBParsers.shellQuote(ADBParsers.normalizeRemotePath(path))
        do {
            let res = try await runADB(["-s", serial, "shell", "[ -d \(quoted) ] && echo YES || echo NO"])
            return res.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "YES"
        } catch {
            return false
        }
    }

    public func getStorageInfo(serial: String, path: String = "/sdcard") async -> StorageInfo? {
        let quoted = ADBParsers.shellQuote(ADBParsers.normalizeRemotePath(path))
        do {
            let res = try await runADB(["-s", serial, "shell", "df -k \(quoted)"])
            guard res.exitCode == 0 else { return nil }
            return ADBParsers.parseStorageOutput(res.stdout)
        } catch {
            return nil
        }
    }

    public func createDirectory(serial: String, path: String) async throws {
        let normalized = ADBParsers.normalizeRemotePath(path)
        let quoted = ADBParsers.shellQuote(normalized)
        let res = try await runADB(["-s", serial, "shell", "mkdir -p \(quoted)"])
        let errMsg = [res.stderr, res.stdout].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if res.exitCode != 0 || errMsg.lowercased().contains("failed") || errMsg.lowercased().contains("denied") {
            throw ADBError.commandFailed(errMsg.isEmpty ? "Failed to create folder." : errMsg)
        }
    }

    public func rename(serial: String, from oldPath: String, to newPath: String) async throws {
        let qOld = ADBParsers.shellQuote(ADBParsers.normalizeRemotePath(oldPath))
        let qNew = ADBParsers.shellQuote(ADBParsers.normalizeRemotePath(newPath))
        let res = try await runADB(["-s", serial, "shell", "mv \(qOld) \(qNew)"])
        let errMsg = [res.stderr, res.stdout].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if res.exitCode != 0 || errMsg.lowercased().contains("failed") || errMsg.lowercased().contains("denied") {
            throw ADBError.commandFailed(errMsg.isEmpty ? "Failed to rename item." : errMsg)
        }
    }

    public func delete(serial: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        // Guard against accidentally deleting critical top-level roots
        let forbidden: Set<String> = ["/", "/sdcard", "/storage", "/storage/emulated", "/storage/emulated/0", "/system", "/data"]
        for path in paths {
            let norm = ADBParsers.normalizeRemotePath(path)
            if forbidden.contains(norm) {
                throw ADBError.invalidInput("Refusing to delete protected root directory: \(norm)")
            }
        }

        // Delete one by one to stay well below shell ARG_MAX and report exact errors
        for path in paths {
            let quoted = ADBParsers.shellQuote(ADBParsers.normalizeRemotePath(path))
            let res = try await runADB(["-s", serial, "shell", "rm -rf \(quoted)"])
            let errMsg = [res.stderr, res.stdout].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if res.exitCode != 0 || errMsg.lowercased().contains("denied") || errMsg.lowercased().contains("read-only") {
                throw ADBError.commandFailed(errMsg.isEmpty ? "Failed to delete \(path)." : errMsg)
            }
        }
    }

    // MARK: - Transfers (Push / Pull with live PTY progress)

    public func push(
        serial: String,
        localURL: URL,
        remoteDir: String,
        processBox: ProcessBox? = nil,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let adbPath = try resolvedADBPath()
        let dest = ADBParsers.normalizeRemotePath(remoteDir)
        let args = ["-s", serial, "push", localURL.path, dest]
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.runStreamingSync(
                        executable: adbPath,
                        arguments: args,
                        processBox: processBox,
                        onProgress: onProgress
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func pull(
        serial: String,
        remotePath: String,
        localDestination: URL,
        processBox: ProcessBox? = nil,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let adbPath = try resolvedADBPath()
        let normalized = ADBParsers.normalizeRemotePath(remotePath)
        let args = ["-s", serial, "pull", "-a", normalized, localDestination.path]
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try self.runStreamingSync(
                        executable: adbPath,
                        arguments: args,
                        processBox: processBox,
                        onProgress: onProgress
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Synchronous pull designed for AppKit `NSFilePromiseProviderDelegate`'s background operation queue.
    public func pullSync(
        serial: String,
        remotePath: String,
        localDestination: URL,
        processBox: ProcessBox? = nil,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) throws {
        let adbPath = try resolvedADBPath()
        let normalized = ADBParsers.normalizeRemotePath(remotePath)
        let args = ["-s", serial, "pull", "-a", normalized, localDestination.path]
        try runStreamingSync(
            executable: adbPath,
            arguments: args,
            processBox: processBox,
            onProgress: onProgress
        )
    }

    // MARK: - Low-Level Process Execution

    private func runADB(_ arguments: [String]) async throws -> CommandResult {
        let adbPath = try resolvedADBPath()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: adbPath)
                proc.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                proc.standardOutput = outPipe
                proc.standardError = errPipe

                // Read both pipes concurrently to avoid deadlocks on large directory listings.
                var outData = Data()
                var errData = Data()
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    group.wait()

                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    continuation.resume(returning: CommandResult(exitCode: proc.terminationStatus, stdout: stdout, stderr: stderr))
                } catch {
                    continuation.resume(throwing: ADBError.commandFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Runs `adb push` or `adb pull` connected to a PTY so `adb` emits live `[ 42%]` progress lines.
    private func runStreamingSync(
        executable: String,
        arguments: [String],
        processBox: ProcessBox?,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        let usePTY = (openpty(&masterFD, &slaveFD, nil, nil, nil) == 0)

        let fallbackPipe = usePTY ? nil : Pipe()
        let slaveHandle = usePTY ? FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true) : nil

        if let slaveHandle {
            proc.standardOutput = slaveHandle
            proc.standardError = slaveHandle
        } else {
            proc.standardOutput = fallbackPipe
            proc.standardError = fallbackPipe
        }

        defer {
            if usePTY && masterFD >= 0 {
                Darwin.close(masterFD)
            }
        }

        if let processBox, !processBox.set(proc) {
            throw ADBError.cancelled
        }
        defer { processBox?.clear() }

        do {
            try proc.run()
        } catch {
            throw ADBError.commandFailed(error.localizedDescription)
        }

        // Close parent's copy of slaveFD immediately so masterFD receives EOF when child exits.
        if usePTY {
            try? slaveHandle?.close()
        } else {
            try? fallbackPipe?.fileHandleForWriting.close()
        }

        var collectedLines: [String] = []
        var remainder = ""

        while true {
            let chunk: Data
            if usePTY {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let bytesRead = Darwin.read(masterFD, &buffer, buffer.count)
                if bytesRead <= 0 {
                    break
                }
                chunk = Data(buffer[0..<bytesRead])
            } else {
                chunk = fallbackPipe!.fileHandleForReading.availableData
                if chunk.isEmpty {
                    break
                }
            }

            if let text = String(data: chunk, encoding: .utf8) {
                let combined = remainder + text
                let parts = combined.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
                remainder = parts.last ?? ""

                for line in parts.dropLast() {
                    let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { continue }
                    let parsed = ADBParsers.parseProgressLine(clean)
                    if let pct = parsed.percent {
                        onProgress(pct, parsed.currentFile ?? "")
                    } else {
                        collectedLines.append(clean)
                        if collectedLines.count > 20 {
                            collectedLines.removeFirst()
                        }
                    }
                }
            }
        }

        if !remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let clean = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = ADBParsers.parseProgressLine(clean)
            if let pct = parsed.percent {
                onProgress(pct, parsed.currentFile ?? "")
            } else {
                collectedLines.append(clean)
            }
        }

        proc.waitUntilExit()

        if let processBox, processBox.isCancelled {
            throw ADBError.cancelled
        }

        if proc.terminationStatus != 0 {
            let message = collectedLines.suffix(5).joined(separator: "\n")
            throw ADBError.commandFailed(message.isEmpty ? "ADB transfer failed (exit \(proc.terminationStatus))." : message)
        }
    }
}
