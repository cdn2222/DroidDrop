import AppKit
import Combine
import DroidDropCore
import Foundation

public enum PaneKind: String, Identifiable {
    case local
    case remote
    public var id: String { rawValue }
}

@MainActor
final class AppViewModel: ObservableObject {
    // MARK: - Settings & ADB State
    @Published var customADBPath: String {
        didSet {
            UserDefaults.standard.set(customADBPath, forKey: "DroidDrop.customADBPath")
            adb.customADBPath = customADBPath.isEmpty ? nil : customADBPath
            resolvedADBPath = ADBClient.discoverADBPath(customPath: customADBPath)
        }
    }
    @Published var resolvedADBPath: String?
    @Published var showMacPane: Bool = true
    @Published var showHiddenFiles: Bool = false {
        didSet {
            refreshLocal()
            Task { await refreshRemote() }
        }
    }

    // MARK: - Devices
    @Published var devices: [AndroidDevice] = []
    @Published var selectedSerial: String? {
        didSet {
            if oldValue != selectedSerial {
                remotePath = "/sdcard"
                remoteSelection.removeAll()
                remoteEntries = []
                storageInfo = nil
                Task { await refreshRemoteAndStorage() }
            }
        }
    }
    @Published var wifiAddress: String = ""
    @Published var isConnectingWifi: Bool = false

    // MARK: - Mac Pane State
    @Published var localURL: URL
    @Published var localEntries: [FileEntry] = []
    @Published var localSelection: Set<String> = []
    @Published var localSearch: String = ""
    @Published var localSortColumn: SortColumn = .name
    @Published var localSortAscending: Bool = true
    @Published var localError: String?

    // MARK: - Android Pane State
    @Published var remotePath: String = "/sdcard"
    @Published var remoteEntries: [FileEntry] = []
    @Published var remoteSelection: Set<String> = []
    @Published var remoteSearch: String = ""
    @Published var remoteSortColumn: SortColumn = .name
    @Published var remoteSortAscending: Bool = true
    @Published var remoteLoading: Bool = false
    @Published var remoteError: String?
    @Published var storageInfo: StorageInfo?

    // MARK: - Transfer & Toast State
    @Published var isTransferring: Bool = false
    @Published var transferTitle: String = ""
    @Published var transferDetail: String = ""
    @Published var transferProgress: Double = 0
    @Published var transferDeterminate: Bool = false

    @Published var bannerMessage: String?
    @Published var bannerIsError: Bool = false

    // MARK: - Dialog / Sheet State
    @Published var newFolderPane: PaneKind?
    @Published var renameEntry: FileEntry?
    @Published var pendingDeleteEntries: [FileEntry] = []
    @Published var pendingDeletePane: PaneKind?

    let adb: ADBClient
    private var activeProcessBox: ProcessBox?
    private var pollTimer: Timer?
    private var bannerDismissTask: Task<Void, Never>?

    init() {
        let savedPath = UserDefaults.standard.string(forKey: "DroidDrop.customADBPath") ?? ""
        self.customADBPath = savedPath
        self.adb = ADBClient(customADBPath: savedPath.isEmpty ? nil : savedPath)
        self.resolvedADBPath = ADBClient.discoverADBPath(customPath: savedPath)

        let fm = FileManager.default
        let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first
        let home = fm.homeDirectoryForCurrentUser
        self.localURL = desktop ?? home

        refreshLocal()
        Task { await refreshDevices(silent: false) }
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Computed Properties

    var selectedDevice: AndroidDevice? {
        guard let serial = selectedSerial else { return nil }
        return devices.first { $0.serial == serial }
    }

    var isDeviceReady: Bool {
        selectedDevice?.state.isReady == true
    }

    var filteredLocalEntries: [FileEntry] {
        let base: [FileEntry]
        if localSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = localEntries
        } else {
            base = localEntries.filter { $0.name.localizedCaseInsensitiveContains(localSearch) }
        }
        return LocalFileService.sortEntries(base, by: localSortColumn, ascending: localSortAscending)
    }

    var filteredRemoteEntries: [FileEntry] {
        let base: [FileEntry]
        if remoteSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            base = remoteEntries
        } else {
            base = remoteEntries.filter { $0.name.localizedCaseInsensitiveContains(remoteSearch) }
        }
        return LocalFileService.sortEntries(base, by: remoteSortColumn, ascending: remoteSortAscending)
    }

    var selectedLocalEntryObjects: [FileEntry] {
        localEntries.filter { localSelection.contains($0.path) }
    }

    var selectedRemoteEntryObjects: [FileEntry] {
        remoteEntries.filter { remoteSelection.contains($0.path) }
    }

    // MARK: - Polling & Device Discovery

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isTransferring else { return }
                await self.refreshDevices(silent: true)
            }
        }
    }

    func refreshDevices(silent: Bool = false) async {
        resolvedADBPath = ADBClient.discoverADBPath(customPath: customADBPath)
        guard resolvedADBPath != nil else {
            devices = []
            selectedSerial = nil
            return
        }

        do {
            let found = try await adb.listDevices()
            let previousReady = isDeviceReady
            devices = found

            if let current = selectedSerial, found.contains(where: { $0.serial == current }) {
                let nowReady = found.first(where: { $0.serial == current })?.state.isReady == true
                if !previousReady && nowReady {
                    await refreshRemoteAndStorage()
                }
            } else if let ready = found.first(where: { $0.state.isReady }) {
                selectedSerial = ready.serial
            } else if let first = found.first {
                selectedSerial = first.serial
            } else {
                selectedSerial = nil
                remoteEntries = []
                storageInfo = nil
            }
        } catch {
            if !silent {
                showBanner(error.localizedDescription, isError: true)
            }
        }
    }

    func connectWifi() async {
        let addr = wifiAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else { return }
        isConnectingWifi = true
        defer { isConnectingWifi = false }

        do {
            let output = try await adb.connectWifi(address: addr)
            showBanner(output, isError: false)
            await refreshDevices(silent: false)
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func restartADBServer() async {
        do {
            showBanner("Restarting ADB server…", isError: false)
            try await adb.restartServer()
            await refreshDevices(silent: false)
            showBanner("ADB server restarted.", isError: false)
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func pickCustomADBExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Select adb Executable"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            customADBPath = url.path
            Task { await refreshDevices(silent: false) }
        }
    }

    // MARK: - Mac Pane Navigation & Actions

    func navigateLocal(to url: URL) {
        localURL = url.standardizedFileURL
        localSelection.removeAll()
        localSearch = ""
        refreshLocal()
    }

    func goUpLocal() {
        let parent = localURL.deletingLastPathComponent()
        if parent.path != localURL.path {
            navigateLocal(to: parent)
        }
    }

    func refreshLocal() {
        do {
            localEntries = try LocalFileService.listDirectory(at: localURL, showHidden: showHiddenFiles)
            localError = nil
            let validPaths = Set(localEntries.map(\.path))
            localSelection = localSelection.intersection(validPaths)
        } catch {
            localError = error.localizedDescription
            localEntries = []
        }
    }

    func openLocalEntry(_ entry: FileEntry) {
        let url = URL(fileURLWithPath: entry.path)
        if entry.isDirectory {
            navigateLocal(to: url)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func revealLocalInFinder(_ entry: FileEntry? = nil) {
        if let entry {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([localURL])
        }
    }

    // MARK: - Android Pane Navigation & Actions

    func navigateRemote(to path: String) async {
        remotePath = ADBParsers.normalizeRemotePath(path)
        remoteSelection.removeAll()
        remoteSearch = ""
        await refreshRemote()
    }

    func goUpRemote() async {
        let parent = ADBParsers.parentRemotePath(remotePath)
        if parent != remotePath {
            await navigateRemote(to: parent)
        }
    }

    func refreshRemoteAndStorage() async {
        await refreshRemote()
        await refreshStorage()
    }

    func refreshRemote() async {
        guard let serial = selectedSerial, isDeviceReady else {
            remoteEntries = []
            remoteError = nil
            return
        }
        remoteLoading = true
        defer { remoteLoading = false }

        do {
            let entries = try await adb.listDirectory(serial: serial, path: remotePath, showHidden: showHiddenFiles)
            remoteEntries = entries
            remoteError = nil
            let validPaths = Set(entries.map(\.path))
            remoteSelection = remoteSelection.intersection(validPaths)
        } catch {
            remoteError = error.localizedDescription
            remoteEntries = []
        }
    }

    func refreshStorage() async {
        guard let serial = selectedSerial, isDeviceReady else {
            storageInfo = nil
            return
        }
        storageInfo = await adb.getStorageInfo(serial: serial, path: "/sdcard")
    }

    func openRemoteEntry(_ entry: FileEntry) async {
        guard let serial = selectedSerial, isDeviceReady else { return }
        if entry.isDirectory {
            await navigateRemote(to: entry.path)
            return
        }
        if entry.isSymlink {
            if await adb.isRemoteDirectory(serial: serial, path: entry.path) {
                await navigateRemote(to: entry.path)
                return
            }
        }
        await quickOpenRemoteFile(entry)
    }

    func quickOpenRemoteFile(_ entry: FileEntry) async {
        guard let serial = selectedSerial, isDeviceReady, !entry.isDirectory else { return }
        guard !isTransferring else {
            showBanner("Wait for the current transfer to finish.", isError: true)
            return
        }

        let previewDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidDropPreview", isDirectory: true)
        try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
        let destURL = previewDir.appendingPathComponent(entry.name)
        try? FileManager.default.removeItem(at: destURL)

        let box = ProcessBox()
        beginTransfer(title: "Opening \(entry.name)…", detail: entry.path, box: box)
        defer { endTransfer() }

        do {
            try await adb.pull(serial: serial, remotePath: entry.path, localDestination: destURL, processBox: box) { [weak self] pct, file in
                Task { @MainActor [weak self] in
                    self?.updateTransferProgress(pct, detail: file)
                }
            }
            NSWorkspace.shared.open(destURL)
        } catch {
            showBanner(error.localizedDescription, isError: true)
        }
    }

    // MARK: - Transfers (Mac <-> Android)

    func pushFilesToAndroid(_ localURLs: [URL], remoteDirectory: String? = nil) async {
        guard let serial = selectedSerial, isDeviceReady else {
            showBanner("Connect and authorize an Android device first.", isError: true)
            return
        }
        guard !localURLs.isEmpty else { return }
        guard !isTransferring else {
            showBanner("Another transfer is already in progress.", isError: true)
            return
        }

        let targetDir = ADBParsers.normalizeRemotePath(remoteDirectory ?? remotePath)
        let box = ProcessBox()
        let total = localURLs.count
        beginTransfer(title: "Copying to Phone…", detail: "", box: box)
        defer { endTransfer() }

        var succeeded = 0
        do {
            for (index, url) in localURLs.enumerated() {
                if box.isCancelled { throw ADBError.cancelled }
                let label = total > 1 ? "Copying to Phone (\(index + 1)/\(total)): \(url.lastPathComponent)" : "Copying to Phone: \(url.lastPathComponent)"
                transferTitle = label
                transferDetail = targetDir
                transferProgress = Double(index) / Double(total)
                transferDeterminate = false

                try await adb.push(serial: serial, localURL: url, remoteDir: targetDir, processBox: box) { [weak self] pct, file in
                    Task { @MainActor [weak self] in
                        let overall = (Double(index) + pct) / Double(total)
                        self?.updateTransferProgress(overall, detail: file.isEmpty ? url.lastPathComponent : file)
                    }
                }
                succeeded += 1
            }

            await refreshRemoteAndStorage()
            let noun = succeeded == 1 ? "item" : "items"
            showBanner("Copied \(succeeded) \(noun) to \(targetDir)", isError: false)
        } catch {
            await refreshRemoteAndStorage()
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func pullEntriesToMac(_ entries: [FileEntry], localDirectory: URL? = nil) async {
        guard let serial = selectedSerial, isDeviceReady else {
            showBanner("Connect and authorize an Android device first.", isError: true)
            return
        }
        guard !entries.isEmpty else { return }
        guard !isTransferring else {
            showBanner("Another transfer is already in progress.", isError: true)
            return
        }

        let targetDir = (localDirectory ?? localURL).standardizedFileURL
        let box = ProcessBox()
        let total = entries.count
        beginTransfer(title: "Copying to Mac…", detail: "", box: box)
        defer { endTransfer() }

        var succeeded = 0
        do {
            for (index, entry) in entries.enumerated() {
                if box.isCancelled { throw ADBError.cancelled }
                let label = total > 1 ? "Copying to Mac (\(index + 1)/\(total)): \(entry.name)" : "Copying to Mac: \(entry.name)"
                transferTitle = label
                transferDetail = targetDir.path
                transferProgress = Double(index) / Double(total)
                transferDeterminate = false

                try await adb.pull(serial: serial, remotePath: entry.path, localDestination: targetDir, processBox: box) { [weak self] pct, file in
                    Task { @MainActor [weak self] in
                        let overall = (Double(index) + pct) / Double(total)
                        self?.updateTransferProgress(overall, detail: file.isEmpty ? entry.name : file)
                    }
                }
                succeeded += 1
            }

            refreshLocal()
            let noun = succeeded == 1 ? "item" : "items"
            showBanner("Copied \(succeeded) \(noun) to \(targetDir.lastPathComponent)", isError: false)
        } catch {
            refreshLocal()
            showBanner(error.localizedDescription, isError: true)
        }
    }

    func chooseFilesAndPushToAndroid() {
        guard isDeviceReady else { return }
        let panel = NSOpenPanel()
        panel.title = "Copy Files or Folders to Phone"
        panel.prompt = "Copy to Phone"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            Task { await pushFilesToAndroid(panel.urls, remoteDirectory: remotePath) }
        }
    }

    func chooseFolderAndPullFromAndroid(_ entries: [FileEntry]) {
        guard isDeviceReady, !entries.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Destination Folder on Mac"
        panel.prompt = "Copy Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = localURL
        if panel.runModal() == .OK, let folderURL = panel.url {
            Task { await pullEntriesToMac(entries, localDirectory: folderURL) }
        }
    }

    /// Invoked on a background thread by `NSFilePromiseProviderDelegate` when the user drags from Android directly to Finder/Desktop.
    nonisolated func fulfillFinderPromise(entry: FileEntry, destinationURL: URL) throws {
        let serial: String? = DispatchQueue.main.sync {
            MainActor.assumeIsolated { self.isDeviceReady ? self.selectedSerial : nil }
        }
        guard let serial else {
            throw ADBError.noDeviceSelected
        }

        let box = ProcessBox()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.beginTransfer(title: "Dragging to Finder: \(entry.name)", detail: destinationURL.deletingLastPathComponent().lastPathComponent, box: box)
            }
        }
        defer {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.endTransfer()
                    self.refreshLocal()
                }
            }
        }

        do {
            try adb.pullSync(serial: serial, remotePath: entry.path, localDestination: destinationURL, processBox: box) { pct, file in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.updateTransferProgress(pct, detail: file.isEmpty ? entry.name : file)
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.showBanner("Copied \(entry.name) to \(destinationURL.deletingLastPathComponent().lastPathComponent)", isError: false)
                }
            }
        } catch {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.showBanner(error.localizedDescription, isError: true)
                }
            }
            throw error
        }
    }

    func cancelTransfer() {
        activeProcessBox?.cancel()
    }

    // MARK: - Create Folder / Rename / Delete

    func createFolder(name: String, in pane: PaneKind) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            showBanner("Folder name cannot be empty or contain '/'.", isError: true)
            return
        }

        switch pane {
        case .local:
            do {
                _ = try LocalFileService.createDirectory(in: localURL, name: trimmed)
                refreshLocal()
                showBanner("Created folder \"\(trimmed)\"", isError: false)
            } catch {
                showBanner(error.localizedDescription, isError: true)
            }
        case .remote:
            guard let serial = selectedSerial, isDeviceReady else { return }
            let target = ADBParsers.joinRemotePath(remotePath, trimmed)
            do {
                try await adb.createDirectory(serial: serial, path: target)
                await refreshRemote()
                showBanner("Created folder \"\(trimmed)\" on phone", isError: false)
            } catch {
                showBanner(error.localizedDescription, isError: true)
            }
        }
    }

    func rename(_ entry: FileEntry, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/"), trimmed != entry.name else { return }

        if entry.isRemote {
            guard let serial = selectedSerial, isDeviceReady else { return }
            let parent = ADBParsers.parentRemotePath(entry.path)
            let target = ADBParsers.joinRemotePath(parent, trimmed)
            do {
                try await adb.rename(serial: serial, from: entry.path, to: target)
                await refreshRemote()
                showBanner("Renamed to \"\(trimmed)\"", isError: false)
            } catch {
                showBanner(error.localizedDescription, isError: true)
            }
        } else {
            do {
                _ = try LocalFileService.rename(itemAt: URL(fileURLWithPath: entry.path), to: trimmed)
                refreshLocal()
                showBanner("Renamed to \"\(trimmed)\"", isError: false)
            } catch {
                showBanner(error.localizedDescription, isError: true)
            }
        }
    }

    func requestDelete(_ entries: [FileEntry], pane: PaneKind) {
        guard !entries.isEmpty else { return }
        pendingDeleteEntries = entries
        pendingDeletePane = pane
    }

    func confirmPendingDelete() async {
        let entries = pendingDeleteEntries
        guard let pane = pendingDeletePane, !entries.isEmpty else { return }
        pendingDeleteEntries = []
        pendingDeletePane = nil

        switch pane {
        case .local:
            do {
                try LocalFileService.trashItems(at: entries.map { URL(fileURLWithPath: $0.path) })
                refreshLocal()
                let noun = entries.count == 1 ? "item" : "items"
                showBanner("Moved \(entries.count) \(noun) to Trash", isError: false)
            } catch {
                showBanner(error.localizedDescription, isError: true)
            }
        case .remote:
            guard let serial = selectedSerial, isDeviceReady else { return }
            do {
                try await adb.delete(serial: serial, paths: entries.map(\.path))
                await refreshRemoteAndStorage()
                let noun = entries.count == 1 ? "item" : "items"
                showBanner("Deleted \(entries.count) \(noun) from phone", isError: false)
            } catch {
                await refreshRemoteAndStorage()
                showBanner(error.localizedDescription, isError: true)
            }
        }
    }

    // MARK: - Helpers

    private func beginTransfer(title: String, detail: String, box: ProcessBox) {
        activeProcessBox = box
        isTransferring = true
        transferTitle = title
        transferDetail = detail
        transferProgress = 0
        transferDeterminate = false
    }

    private func updateTransferProgress(_ progress: Double, detail: String) {
        transferDeterminate = true
        transferProgress = min(1.0, max(0.0, progress))
        if !detail.isEmpty {
            transferDetail = detail
        }
    }

    private func endTransfer() {
        isTransferring = false
        activeProcessBox = nil
        transferProgress = 0
        transferDeterminate = false
    }

    func showBanner(_ message: String, isError: Bool) {
        bannerDismissTask?.cancel()
        bannerMessage = message
        bannerIsError = isError

        if !isError {
            bannerDismissTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                self?.bannerMessage = nil
            }
        }
    }
}
