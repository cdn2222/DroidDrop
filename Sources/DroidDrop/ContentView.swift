import AppKit
import DroidDropCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var vm: AppViewModel
    @State private var showSettingsPopover = false
    @State private var editingRemotePath = false
    @State private var remotePathDraft = ""
    @State private var newFolderName = ""
    @State private var renameDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()

            if vm.resolvedADBPath == nil {
                adbMissingView
            } else {
                mainWorkspace
            }

            if vm.isTransferring {
                Divider()
                transferBar
            }

            if let message = vm.bannerMessage {
                Divider()
                bannerBar(message: message, isError: vm.bannerIsError)
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .sheet(item: $vm.newFolderPane) { pane in
            namePromptSheet(
                title: pane == .remote ? "New Folder on Phone" : "New Folder on Mac",
                subtitle: pane == .remote ? vm.remotePath : vm.localURL.path,
                placeholder: "Folder Name",
                confirmLabel: "Create",
                text: $newFolderName
            ) {
                let name = newFolderName
                newFolderName = ""
                vm.newFolderPane = nil
                Task { await vm.createFolder(name: name, in: pane) }
            } onCancel: {
                newFolderName = ""
                vm.newFolderPane = nil
            }
            .onAppear { newFolderName = "" }
        }
        .sheet(item: $vm.renameEntry) { entry in
            namePromptSheet(
                title: "Rename Item",
                subtitle: entry.path,
                placeholder: "New Name",
                confirmLabel: "Rename",
                text: $renameDraft
            ) {
                let targetName = renameDraft
                vm.renameEntry = nil
                Task { await vm.rename(entry, to: targetName) }
            } onCancel: {
                vm.renameEntry = nil
            }
            .onAppear { renameDraft = entry.name }
        }
        .alert(
            deleteAlertTitle,
            isPresented: Binding(
                get: { !vm.pendingDeleteEntries.isEmpty },
                set: { if !$0 { vm.pendingDeleteEntries = []; vm.pendingDeletePane = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                vm.pendingDeleteEntries = []
                vm.pendingDeletePane = nil
            }
            Button(vm.pendingDeletePane == .remote ? "Delete Permanently" : "Move to Trash", role: .destructive) {
                Task { await vm.confirmPendingDelete() }
            }
        } message: {
            Text(deleteAlertMessage)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Device selector
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 9, height: 9)

                if vm.devices.isEmpty {
                    Text("No Android Device")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Device", selection: Binding(
                        get: { vm.selectedSerial ?? "" },
                        set: { vm.selectedSerial = $0.isEmpty ? nil : $0 }
                    )) {
                        ForEach(vm.devices) { device in
                            Text("\(device.displayName)\(device.state.isReady ? "" : " (\(device.state.rawValue))")")
                                .tag(device.serial)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }

                Button {
                    Task {
                        await vm.refreshDevices(silent: false)
                        vm.refreshLocal()
                        await vm.refreshRemoteAndStorage()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh devices and folders (⌘R)")
            }

            // Storage indicator
            if let storage = vm.storageInfo, vm.isDeviceReady {
                Divider().frame(height: 18)
                HStack(spacing: 8) {
                    ProgressView(value: storage.usedFraction)
                        .frame(width: 72)
                        .tint(storage.usedFraction > 0.9 ? .red : .accentColor)
                    Text(storage.summaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // View Controls
            Toggle(isOn: $vm.showMacPane) {
                Label("Mac Pane", systemImage: "sidebar.left")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Show or hide the Mac file browser pane (⌥⌘M)")

            Toggle(isOn: $vm.showHiddenFiles) {
                Label("Hidden", systemImage: "eye")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Show hidden files (⇧⌘.)")

            Button {
                showSettingsPopover.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("ADB Settings & Wi-Fi Connect")
            .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                settingsPopover
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusColor: Color {
        guard let device = vm.selectedDevice else { return .gray }
        switch device.state {
        case .device: return .green
        case .unauthorized: return .orange
        default: return .red
        }
    }

    // MARK: - Settings Popover (ADB Path + Wi-Fi Connect)

    private var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ADB Connection & Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("ADB Executable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(vm.resolvedADBPath ?? "Not found")
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .cornerRadius(6)

                    Button("Browse…") {
                        vm.pickCustomADBExecutable()
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Wireless ADB Connect (optional)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    TextField("192.168.1.42:5555", text: $vm.wifiAddress)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await vm.connectWifi() }
                        }
                    Button(vm.isConnectingWifi ? "Connecting…" : "Connect") {
                        Task { await vm.connectWifi() }
                    }
                    .disabled(vm.wifiAddress.trimmingCharacters(in: .whitespaces).isEmpty || vm.isConnectingWifi)
                    .controlSize(.small)
                }
            }

            Divider()

            HStack {
                Button("Restart ADB Server") {
                    Task { await vm.restartADBServer() }
                }
                .controlSize(.small)
                Spacer()
                Button("Done") {
                    showSettingsPopover = false
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    // MARK: - Main Dual-Pane Workspace

    private var mainWorkspace: some View {
        HSplitView {
            if vm.showMacPane {
                macPane
                    .frame(minWidth: 320, idealWidth: 420)
            }
            androidPane
                .frame(minWidth: 380, idealWidth: 520)
        }
    }

    // MARK: - Mac Pane (Left)

    private var macPane: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "laptopcomputer")
                        .foregroundStyle(.secondary)
                    Text("Mac")
                        .font(.headline)

                    Spacer()

                    localShortcutButton("Desktop", url: FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first)
                    localShortcutButton("Downloads", url: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
                    localShortcutButton("Documents", url: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
                    localShortcutButton("Home", url: FileManager.default.homeDirectoryForCurrentUser)
                }

                // Breadcrumbs + Search
                HStack(spacing: 6) {
                    Button { vm.goUpLocal() } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(vm.localURL.path == "/")
                    .help("Parent Folder (⌘↑)")

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 2) {
                            let crumbs = localBreadcrumbs(for: vm.localURL)
                            ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, crumb in
                                if idx > 0 {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                                Button(crumb.title) {
                                    vm.navigateLocal(to: crumb.url)
                                }
                                .buttonStyle(.plain)
                                .font(.caption)
                                .foregroundStyle(idx == crumbs.count - 1 ? .primary : .secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    searchField(text: $vm.localSearch, placeholder: "Filter")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

            Divider()

            // File Table
            if let error = vm.localError {
                paneErrorView(error) { vm.refreshLocal() }
            } else {
                FileTableView(
                    pane: .local,
                    entries: vm.filteredLocalEntries,
                    selection: $vm.localSelection,
                    sortColumn: $vm.localSortColumn,
                    sortAscending: $vm.localSortAscending,
                    isDeviceReady: vm.isDeviceReady,
                    showMacPane: vm.showMacPane,
                    onOpen: { vm.openLocalEntry($0) },
                    onGoUp: { vm.goUpLocal() },
                    onDelete: { vm.requestDelete($0, pane: .local) },
                    onRename: { vm.renameEntry = $0 },
                    onNewFolder: { vm.newFolderPane = .local },
                    onCopyPrimary: { entries in
                        let urls = entries.map { URL(fileURLWithPath: $0.path) }
                        Task { await vm.pushFilesToAndroid(urls) }
                    },
                    onCopyChooseDestination: { _ in },
                    onRevealInFinder: { vm.revealLocalInFinder($0) },
                    onDropLocalURLs: { _, _ in },
                    onDropRemoteEntries: { remoteEntries, targetDir in
                        Task { await vm.pullEntriesToMac(remoteEntries, localDirectory: targetDir) }
                    },
                    fulfillPromise: { _, _ in }
                )
            }

            Divider()

            // Footer Bar
            HStack(spacing: 8) {
                Text(itemCountLabel(total: vm.filteredLocalEntries.count, selected: vm.localSelection.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button { vm.newFolderPane = .local } label: {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .help("New Folder on Mac")

                Button { vm.revealLocalInFinder() } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")

                Button {
                    vm.requestDelete(vm.selectedLocalEntryObjects, pane: .local)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(vm.localSelection.isEmpty)
                .help("Move Selected to Trash (⌘⌫)")

                Button {
                    let urls = vm.selectedLocalEntryObjects.map { URL(fileURLWithPath: $0.path) }
                    Task { await vm.pushFilesToAndroid(urls) }
                } label: {
                    Label("Copy to Phone", systemImage: "arrow.right")
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(vm.localSelection.isEmpty || !vm.isDeviceReady || vm.isTransferring)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)
        }
    }

    // MARK: - Android Pane (Right)

    private var androidPane: some View {
        VStack(spacing: 0) {
            if !vm.isDeviceReady {
                disconnectedAndroidView
            } else {
                // Header
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "iphone.gen3")
                            .foregroundStyle(.green)
                        Text(vm.selectedDevice?.displayName ?? "Android")
                            .font(.headline)
                            .lineLimit(1)

                        Spacer()

                        remoteShortcutButton("Internal", path: "/sdcard")
                        remoteShortcutButton("Camera", path: "/sdcard/DCIM/Camera")
                        remoteShortcutButton("Downloads", path: "/sdcard/Download")
                        remoteShortcutButton("Pictures", path: "/sdcard/Pictures")
                        remoteShortcutButton("Docs", path: "/sdcard/Documents")
                    }

                    // Breadcrumbs / Manual Path Input + Search
                    HStack(spacing: 6) {
                        Button {
                            Task { await vm.goUpRemote() }
                        } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(vm.remotePath == "/")
                        .help("Parent Folder (⌘↑)")

                        if editingRemotePath {
                            TextField("/sdcard", text: $remotePathDraft)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.caption, design: .monospaced))
                                .onSubmit {
                                    editingRemotePath = false
                                    Task { await vm.navigateRemote(to: remotePathDraft) }
                                }
                            Button("Go") {
                                editingRemotePath = false
                                Task { await vm.navigateRemote(to: remotePathDraft) }
                            }
                            .controlSize(.small)
                            Button { editingRemotePath = false } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.borderless)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 2) {
                                    let crumbs = ADBParsers.remoteBreadcrumbs(for: vm.remotePath)
                                    ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, crumb in
                                        if idx > 0 {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 9))
                                                .foregroundStyle(.tertiary)
                                        }
                                        Button(crumb.title) {
                                            Task { await vm.navigateRemote(to: crumb.path) }
                                        }
                                        .buttonStyle(.plain)
                                        .font(.caption)
                                        .foregroundStyle(idx == crumbs.count - 1 ? .primary : .secondary)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                    }
                                }
                            }

                            Button {
                                remotePathDraft = vm.remotePath
                                editingRemotePath = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption)
                            }
                            .buttonStyle(.borderless)
                            .help("Type a path directly")
                        }

                        searchField(text: $vm.remoteSearch, placeholder: "Filter")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))

                Divider()

                // Android File Table
                ZStack {
                    if let error = vm.remoteError {
                        paneErrorView(error) {
                            Task { await vm.refreshRemote() }
                        }
                    } else {
                        FileTableView(
                            pane: .remote,
                            entries: vm.filteredRemoteEntries,
                            selection: $vm.remoteSelection,
                            sortColumn: $vm.remoteSortColumn,
                            sortAscending: $vm.remoteSortAscending,
                            isDeviceReady: vm.isDeviceReady,
                            showMacPane: vm.showMacPane,
                            onOpen: { entry in
                                Task { await vm.openRemoteEntry(entry) }
                            },
                            onGoUp: {
                                Task { await vm.goUpRemote() }
                            },
                            onDelete: { entries in
                                vm.requestDelete(entries, pane: .remote)
                            },
                            onRename: { vm.renameEntry = $0 },
                            onNewFolder: { vm.newFolderPane = .remote },
                            onCopyPrimary: { entries in
                                if vm.showMacPane {
                                    Task { await vm.pullEntriesToMac(entries) }
                                } else {
                                    vm.chooseFolderAndPullFromAndroid(entries)
                                }
                            },
                            onCopyChooseDestination: { entries in
                                vm.chooseFolderAndPullFromAndroid(entries)
                            },
                            onRevealInFinder: { _ in },
                            onDropLocalURLs: { urls, targetSubdir in
                                Task { await vm.pushFilesToAndroid(urls, remoteDirectory: targetSubdir) }
                            },
                            onDropRemoteEntries: { _, _ in },
                            fulfillPromise: { entry, destURL in
                                try vm.fulfillFinderPromise(entry: entry, destinationURL: destURL)
                            }
                        )

                        if vm.filteredRemoteEntries.isEmpty && !vm.remoteLoading {
                            VStack(spacing: 8) {
                                Image(systemName: "arrow.down.doc")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.tertiary)
                                Text(vm.remoteSearch.isEmpty ? "Empty Folder — Drop files from Finder here" : "No matching files")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .allowsHitTesting(false)
                        }
                    }

                    if vm.remoteLoading {
                        ProgressView()
                            .controlSize(.small)
                            .padding(10)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                Divider()

                // Footer Bar
                HStack(spacing: 8) {
                    Text(itemCountLabel(total: vm.filteredRemoteEntries.count, selected: vm.remoteSelection.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("• Drag to/from Finder")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Button { vm.newFolderPane = .remote } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Folder on Phone (⇧⌘N)")

                    Button { vm.chooseFilesAndPushToAndroid() } label: {
                        Label("Upload…", systemImage: "square.and.arrow.down")
                    }
                    .controlSize(.small)
                    .disabled(vm.isTransferring)
                    .help("Choose files or folders from Mac to copy to Phone")

                    Button {
                        let entries = vm.selectedRemoteEntryObjects
                        if vm.showMacPane {
                            Task { await vm.pullEntriesToMac(entries) }
                        } else {
                            vm.chooseFolderAndPullFromAndroid(entries)
                        }
                    } label: {
                        Label("Copy to Mac", systemImage: "arrow.left")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.remoteSelection.isEmpty || vm.isTransferring)

                    Button(role: .destructive) {
                        vm.requestDelete(vm.selectedRemoteEntryObjects, pane: .remote)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(vm.remoteSelection.isEmpty ? Color.secondary : Color.red)
                    .disabled(vm.remoteSelection.isEmpty || vm.isTransferring)
                    .help("Delete Selected from Phone (⌘⌫)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.bar)
            }
        }
    }

    // MARK: - Empty / Disconnected States

    private var disconnectedAndroidView: some View {
        VStack(spacing: 16) {
            if let device = vm.selectedDevice, device.state == .unauthorized {
                Image(systemName: "lock.iphone")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                Text("Allow USB Debugging on Your Phone")
                    .font(.title3.bold())
                Text("Unlock your phone (\(device.serial)) and tap **Allow** on the \"Allow USB debugging?\" prompt.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
            } else {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Connect Your Android Phone")
                    .font(.title3.bold())
                VStack(alignment: .leading, spacing: 6) {
                    Label("Plug your Android phone into your Mac with a USB cable", systemImage: "1.circle.fill")
                    Label("Enable Developer Options → USB Debugging on the phone", systemImage: "2.circle.fill")
                    Label("Tap \"Allow\" if prompted on the phone screen", systemImage: "3.circle.fill")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button {
                    Task { await vm.refreshDevices(silent: false) }
                } label: {
                    Label("Scan for Device", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)

                Button("Wi-Fi ADB…") {
                    showSettingsPopover = true
                }
            }

            Text("Auto-detecting every 3 seconds…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var adbMissingView: some View {
        VStack(spacing: 14) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("ADB Not Found")
                .font(.title2.bold())
            Text("Install Android Platform Tools (`brew install android-platform-tools`) or select your existing `adb` binary.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack {
                Button("Locate adb…") {
                    vm.pickCustomADBExecutable()
                }
                .buttonStyle(.borderedProminent)
                Button("Re-check") {
                    Task { await vm.refreshDevices(silent: false) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Bars

    private var transferBar: some View {
        HStack(spacing: 12) {
            if vm.transferDeterminate {
                ProgressView(value: vm.transferProgress)
                    .frame(width: 140)
            } else {
                ProgressView()
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(vm.transferTitle)
                    .font(.caption.bold())
                    .lineLimit(1)
                if !vm.transferDetail.isEmpty {
                    Text(vm.transferDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if vm.transferDeterminate {
                Text("\(Int((vm.transferProgress * 100).rounded()))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Button("Cancel") {
                vm.cancelTransfer()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.08))
    }

    private func bannerBar(message: String, isError: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? .red : .green)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button {
                vm.bannerMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background((isError ? Color.red : Color.green).opacity(0.10))
    }

    // MARK: - Reusable Small Components

    private func localShortcutButton(_ title: String, url: URL?) -> some View {
        Button(title) {
            if let url { vm.navigateLocal(to: url) }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(vm.localURL.path == url?.path ? .accentColor : nil)
    }

    private func remoteShortcutButton(_ title: String, path: String) -> some View {
        Button(title) {
            Task { await vm.navigateRemote(to: path) }
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .tint(vm.remotePath == path ? .accentColor : nil)
    }

    private func searchField(text: Binding<String>, placeholder: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.caption)
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .frame(width: 120)
    }

    private func paneErrorView(_ error: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Retry", action: retry)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func namePromptSheet(
        title: String,
        subtitle: String,
        placeholder: String,
        confirmLabel: String,
        text: Binding<String>,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if !text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty {
                        onConfirm()
                    }
                }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func localBreadcrumbs(for url: URL) -> [(title: String, url: URL)] {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let stdPath = url.standardizedFileURL.path
        var crumbs: [(String, URL)] = []

        if stdPath == homePath || stdPath.hasPrefix(homePath + "/") {
            crumbs.append(("Home", URL(fileURLWithPath: homePath)))
            let suffix = String(stdPath.dropFirst(homePath.count))
            var running = URL(fileURLWithPath: homePath)
            for part in suffix.split(separator: "/", omittingEmptySubsequences: true) {
                running.appendPathComponent(String(part))
                crumbs.append((String(part), running))
            }
        } else {
            crumbs.append(("/", URL(fileURLWithPath: "/")))
            var running = URL(fileURLWithPath: "/")
            for part in stdPath.split(separator: "/", omittingEmptySubsequences: true) {
                running.appendPathComponent(String(part))
                crumbs.append((String(part), running))
            }
        }
        return crumbs
    }

    private func itemCountLabel(total: Int, selected: Int) -> String {
        let base = total == 1 ? "1 item" : "\(total) items"
        return selected > 0 ? "\(base) (\(selected) selected)" : base
    }

    private var deleteAlertTitle: String {
        let count = vm.pendingDeleteEntries.count
        if vm.pendingDeletePane == .remote {
            return count == 1 ? "Delete from Android Phone?" : "Delete \(count) Items from Android Phone?"
        }
        return count == 1 ? "Move to Trash?" : "Move \(count) Items to Trash?"
    }

    private var deleteAlertMessage: String {
        let names = vm.pendingDeleteEntries.prefix(3).map(\.name).joined(separator: ", ")
        let extra = vm.pendingDeleteEntries.count > 3 ? " and \(vm.pendingDeleteEntries.count - 3) more" : ""
        if vm.pendingDeletePane == .remote {
            return "\"\(names)\"\(extra) will be permanently deleted from your phone. This cannot be undone."
        }
        return "\"\(names)\"\(extra) will be moved to your Mac's Trash."
    }
}
