import Foundation

public enum DeviceState: String, Sendable, Equatable, Hashable {
    case device
    case unauthorized
    case offline
    case recovery
    case sideload
    case unknown

    public var isReady: Bool { self == .device }

    public var displayLabel: String {
        switch self {
        case .device: return "Connected"
        case .unauthorized: return "Unauthorized — Tap Allow on phone"
        case .offline: return "Offline — Reconnect USB"
        case .recovery: return "Recovery Mode"
        case .sideload: return "Sideload Mode"
        case .unknown: return "Unknown State"
        }
    }
}

public struct AndroidDevice: Identifiable, Sendable, Equatable, Hashable {
    public var id: String { serial }
    public let serial: String
    public let state: DeviceState
    public let model: String?
    public let product: String?
    public let deviceName: String?
    public let transportId: String?

    public init(
        serial: String,
        state: DeviceState,
        model: String? = nil,
        product: String? = nil,
        deviceName: String? = nil,
        transportId: String? = nil
    ) {
        self.serial = serial
        self.state = state
        self.model = model
        self.product = product
        self.deviceName = deviceName
        self.transportId = transportId
    }

    public var displayName: String {
        if let model = model, !model.isEmpty {
            return model.replacingOccurrences(of: "_", with: " ")
        }
        if let deviceName = deviceName, !deviceName.isEmpty {
            return deviceName
        }
        return serial
    }

    public var isWireless: Bool {
        serial.contains(":")
    }
}

public struct FileEntry: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let symlinkTarget: String?
    public let size: Int64
    public let modifiedDate: Date?
    public let modifiedText: String
    public let permissions: String
    public let isRemote: Bool

    public init(
        name: String,
        path: String,
        isDirectory: Bool,
        isSymlink: Bool = false,
        symlinkTarget: String? = nil,
        size: Int64 = 0,
        modifiedDate: Date? = nil,
        modifiedText: String = "",
        permissions: String = "",
        isRemote: Bool
    ) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.symlinkTarget = symlinkTarget
        self.size = size
        self.modifiedDate = modifiedDate
        self.modifiedText = modifiedText
        self.permissions = permissions
        self.isRemote = isRemote
    }

    public var fileExtension: String {
        (name as NSString).pathExtension.lowercased()
    }

    public var isHidden: Bool {
        name.hasPrefix(".")
    }

    public var formattedSize: String {
        if isDirectory { return "--" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

public struct StorageInfo: Sendable, Equatable {
    public let totalBytes: Int64
    public let usedBytes: Int64
    public let availableBytes: Int64

    public init(totalBytes: Int64, usedBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.availableBytes = availableBytes
    }

    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1.0, max(0.0, Double(usedBytes) / Double(totalBytes)))
    }

    public var summaryText: String {
        let free = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(free) free of \(total)"
    }
}

public enum SortColumn: String, CaseIterable, Sendable {
    case name
    case size
    case date
}

public enum ADBError: LocalizedError, Sendable {
    case adbNotFound
    case noDeviceSelected
    case commandFailed(String)
    case cancelled
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .adbNotFound:
            return "ADB executable not found. Install Android Platform Tools or set the adb path in Settings."
        case .noDeviceSelected:
            return "No ready Android device is connected."
        case .commandFailed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "ADB command failed." : trimmed
        case .cancelled:
            return "Transfer cancelled."
        case .invalidInput(let message):
            return message
        }
    }
}
