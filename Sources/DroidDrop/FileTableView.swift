import AppKit
import DroidDropCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Custom NSFilePromiseProvider (Finder drag + internal Mac pane drag)

final class AndroidFilePromiseProvider: NSFilePromiseProvider {
    static let internalType = NSPasteboard.PasteboardType("com.droiddrop.android-item")

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        types.append(Self.internalType)
        return types
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type == Self.internalType {
            return []
        }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == Self.internalType, let entry = userInfo as? FileEntry {
            return try? JSONEncoder().encode(entry)
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

// MARK: - NSTableView Subclass for Keyboard Navigation

final class InteractiveFileTableView: NSTableView {
    var onDeleteKey: (() -> Void)?
    var onGoUpKey: (() -> Void)?
    var onOpenKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Cmd + Backspace or Forward Delete
        if (event.keyCode == 51 && flags.contains(.command)) || event.keyCode == 117 {
            onDeleteKey?()
            return
        }
        // Cmd + Up Arrow -> Parent directory
        if event.keyCode == 126 && flags.contains(.command) {
            onGoUpKey?()
            return
        }
        // Cmd + Down Arrow or Return -> Open selected item
        if (event.keyCode == 125 && flags.contains(.command)) || event.keyCode == 36 {
            onOpenKey?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Native File Table NSViewRepresentable

struct FileTableView: NSViewRepresentable {
    let pane: PaneKind
    let entries: [FileEntry]
    @Binding var selection: Set<String>
    @Binding var sortColumn: SortColumn
    @Binding var sortAscending: Bool
    let isDeviceReady: Bool
    let showMacPane: Bool

    let onOpen: (FileEntry) -> Void
    let onGoUp: () -> Void
    let onDelete: ([FileEntry]) -> Void
    let onRename: (FileEntry) -> Void
    let onNewFolder: () -> Void
    let onCopyPrimary: ([FileEntry]) -> Void
    let onCopyChooseDestination: ([FileEntry]) -> Void
    let onRevealInFinder: (FileEntry) -> Void
    let onDropLocalURLs: ([URL], String?) -> Void
    let onDropRemoteEntries: ([FileEntry], URL?) -> Void
    let fulfillPromise: (FileEntry, URL) throws -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let tableView = InteractiveFileTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 8, height: 2)
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.draggingDestinationFeedbackStyle = .regular

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Name"
        nameCol.minWidth = 160
        nameCol.width = 280
        nameCol.resizingMask = [.autoresizingMask, .userResizingMask]
        nameCol.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.minWidth = 65
        sizeCol.width = 82
        sizeCol.maxWidth = 120
        sizeCol.headerCell.alignment = .right
        sizeCol.sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)

        let dateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateCol.title = "Modified"
        dateCol.minWidth = 100
        dateCol.width = 132
        dateCol.maxWidth = 180
        dateCol.sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)

        tableView.addTableColumn(nameCol)
        tableView.addTableColumn(sizeCol)
        tableView.addTableColumn(dateCol)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.doubleAction = #selector(Coordinator.handleDoubleClick(_:))

        tableView.setDraggingSourceOperationMask(.copy, forLocal: true)
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        if pane == .remote {
            tableView.registerForDraggedTypes([.fileURL])
        } else {
            tableView.registerForDraggedTypes([AndroidFilePromiseProvider.internalType])
        }

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        tableView.onDeleteKey = { [weak coordinator = context.coordinator] in
            coordinator?.triggerDeleteSelected()
        }
        tableView.onGoUpKey = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onGoUp()
        }
        tableView.onOpenKey = { [weak coordinator = context.coordinator] in
            coordinator?.triggerOpenSelected()
        }

        scrollView.documentView = tableView
        context.coordinator.tableView = tableView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let tableView = coordinator.tableView else { return }

        let entriesChanged = coordinator.entries != entries
        if entriesChanged {
            coordinator.entries = entries
            coordinator.isSyncingSelection = true
            tableView.reloadData()
            coordinator.applySelection(selection, to: tableView)
            coordinator.isSyncingSelection = false
        } else {
            let currentSelectedPaths = coordinator.selectedPaths(in: tableView)
            if currentSelectedPaths != selection {
                coordinator.isSyncingSelection = true
                coordinator.applySelection(selection, to: tableView)
                coordinator.isSyncingSelection = false
            }
        }

        // Keep sort indicator in sync
        let descriptor = NSSortDescriptor(key: sortColumn.rawValue, ascending: sortAscending)
        if tableView.sortDescriptors.first?.key != descriptor.key || tableView.sortDescriptors.first?.ascending != descriptor.ascending {
            coordinator.isUpdatingSort = true
            tableView.sortDescriptors = [descriptor]
            coordinator.isUpdatingSort = false
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate, NSFilePromiseProviderDelegate {
        var parent: FileTableView
        weak var tableView: InteractiveFileTableView?
        var entries: [FileEntry] = []
        var isSyncingSelection = false
        var isUpdatingSort = false

        private let promiseQueue: OperationQueue = {
            let q = OperationQueue()
            q.name = "com.droiddrop.file-promise-queue"
            q.qualityOfService = .userInitiated
            q.maxConcurrentOperationCount = 1
            return q
        }()

        private static let folderIcon: NSImage = {
            let icon = NSWorkspace.shared.icon(for: .folder)
            icon.size = NSSize(width: 16, height: 16)
            return icon
        }()

        private static let symlinkIcon: NSImage = {
            if let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Symlink") {
                img.size = NSSize(width: 15, height: 15)
                return img
            }
            return folderIcon
        }()

        init(parent: FileTableView) {
            self.parent = parent
            self.entries = parent.entries
        }

        // MARK: - Helpers

        func selectedPaths(in tableView: NSTableView) -> Set<String> {
            var set = Set<String>()
            for idx in tableView.selectedRowIndexes where idx >= 0 && idx < entries.count {
                set.insert(entries[idx].path)
            }
            return set
        }

        func applySelection(_ paths: Set<String>, to tableView: NSTableView) {
            let indexes = NSMutableIndexSet()
            for (idx, entry) in entries.enumerated() where paths.contains(entry.path) {
                indexes.add(idx)
            }
            tableView.selectRowIndexes(indexes as IndexSet, byExtendingSelection: false)
        }

        private func targetEntriesForAction(clickedRow: Int? = nil) -> [FileEntry] {
            guard let tableView else { return [] }
            if let row = clickedRow, row >= 0, row < entries.count {
                if tableView.selectedRowIndexes.contains(row) {
                    return tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
                }
                return [entries[row]]
            }
            return tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
        }

        private func icon(for entry: FileEntry) -> NSImage {
            if !entry.isRemote {
                let img = NSWorkspace.shared.icon(forFile: entry.path)
                img.size = NSSize(width: 16, height: 16)
                return img
            }
            if entry.isDirectory {
                return Self.folderIcon
            }
            if entry.isSymlink {
                return Self.symlinkIcon
            }
            let utType = UTType(filenameExtension: entry.fileExtension) ?? .data
            let img = NSWorkspace.shared.icon(for: utType)
            img.size = NSSize(width: 16, height: 16)
            return img
        }

        // MARK: - NSTableViewDataSource

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdatingSort, let first = tableView.sortDescriptors.first, let key = first.key else { return }
            if let col = SortColumn(rawValue: key) {
                DispatchQueue.main.async {
                    self.parent.sortColumn = col
                    self.parent.sortAscending = first.ascending
                }
            }
        }

        // MARK: - NSTableViewDelegate

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard row >= 0, row < entries.count, let colId = tableColumn?.identifier else { return nil }
            let entry = entries[row]

            switch colId.rawValue {
            case "name":
                let cellId = NSUserInterfaceItemIdentifier("NameCell")
                let cell: NSTableCellView
                if let reused = tableView.makeView(withIdentifier: cellId, owner: nil) as? NSTableCellView {
                    cell = reused
                } else {
                    cell = NSTableCellView()
                    cell.identifier = cellId

                    let imageView = NSImageView()
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    imageView.imageScaling = .scaleProportionallyDown

                    let textField = NSTextField(labelWithString: "")
                    textField.translatesAutoresizingMaskIntoConstraints = false
                    textField.lineBreakMode = .byTruncatingMiddle
                    textField.font = NSFont.systemFont(ofSize: 13)

                    cell.addSubview(imageView)
                    cell.addSubview(textField)
                    cell.imageView = imageView
                    cell.textField = textField

                    NSLayoutConstraint.activate([
                        imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                        imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        imageView.widthAnchor.constraint(equalToConstant: 16),
                        imageView.heightAnchor.constraint(equalToConstant: 16),
                        textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                        textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                    ])
                }
                cell.imageView?.image = icon(for: entry)
                if entry.isSymlink, let target = entry.symlinkTarget {
                    cell.textField?.stringValue = "\(entry.name)  →  \(target)"
                } else {
                    cell.textField?.stringValue = entry.name
                }
                cell.textField?.textColor = entry.isHidden ? .secondaryLabelColor : .labelColor
                return cell

            case "size":
                let cellId = NSUserInterfaceItemIdentifier("SizeCell")
                let cell = makeRightOrSecondaryTextCell(tableView: tableView, identifier: cellId, alignment: .right, monospaced: true)
                cell.textField?.stringValue = entry.formattedSize
                return cell

            case "date":
                let cellId = NSUserInterfaceItemIdentifier("DateCell")
                let cell = makeRightOrSecondaryTextCell(tableView: tableView, identifier: cellId, alignment: .left, monospaced: false)
                cell.textField?.stringValue = entry.modifiedText
                return cell

            default:
                return nil
            }
        }

        private func makeRightOrSecondaryTextCell(
            tableView: NSTableView,
            identifier: NSUserInterfaceItemIdentifier,
            alignment: NSTextAlignment,
            monospaced: Bool
        ) -> NSTableCellView {
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                return reused
            }
            let cell = NSTableCellView()
            cell.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.alignment = alignment
            tf.lineBreakMode = .byTruncatingTail
            tf.textColor = .secondaryLabelColor
            tf.font = monospaced
                ? NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                : NSFont.systemFont(ofSize: 12)
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection, let tableView else { return }
            let paths = selectedPaths(in: tableView)
            DispatchQueue.main.async {
                self.parent.selection = paths
            }
        }

        // MARK: - Double Click & Keyboard

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let tableView else { return }
            let row = tableView.clickedRow
            guard row >= 0, row < entries.count else { return }
            parent.onOpen(entries[row])
        }

        func triggerDeleteSelected() {
            let selected = targetEntriesForAction()
            if !selected.isEmpty {
                parent.onDelete(selected)
            }
        }

        func triggerOpenSelected() {
            let selected = targetEntriesForAction()
            if selected.count == 1, let first = selected.first {
                parent.onOpen(first)
            }
        }

        // MARK: - Drag Source

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard row >= 0, row < entries.count else { return nil }
            let entry = entries[row]

            if parent.pane == .local {
                return NSURL(fileURLWithPath: entry.path)
            } else {
                guard parent.isDeviceReady else { return nil }
                let utType: UTType
                if entry.isDirectory {
                    utType = .folder
                } else {
                    utType = UTType(filenameExtension: entry.fileExtension) ?? .data
                }
                let provider = AndroidFilePromiseProvider(fileType: utType.identifier, delegate: self)
                provider.userInfo = entry
                return provider
            }
        }

        // MARK: - NSFilePromiseProviderDelegate (Android -> Finder / Desktop)

        func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
            promiseQueue
        }

        func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
            guard let entry = filePromiseProvider.userInfo as? FileEntry else {
                return "file"
            }
            return entry.name
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            guard let entry = filePromiseProvider.userInfo as? FileEntry else {
                completionHandler(ADBError.invalidInput("Missing file metadata."))
                return
            }
            do {
                try parent.fulfillPromise(entry, url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }

        // MARK: - Drop Target

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: any NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            // Prevent dropping from a table onto itself
            if let source = info.draggingSource as? NSTableView, source === tableView {
                return []
            }

            if parent.pane == .remote {
                guard parent.isDeviceReady else { return [] }
                guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
                    return []
                }
                if dropOperation == .on, row >= 0, row < entries.count, entries[row].isDirectory {
                    return .copy
                }
                tableView.setDropRow(-1, dropOperation: .on)
                return .copy
            } else {
                guard info.draggingPasteboard.types?.contains(AndroidFilePromiseProvider.internalType) == true else {
                    return []
                }
                if dropOperation == .on, row >= 0, row < entries.count, entries[row].isDirectory {
                    return .copy
                }
                tableView.setDropRow(-1, dropOperation: .on)
                return .copy
            }
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: any NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            if parent.pane == .remote {
                guard let urls = info.draggingPasteboard.readObjects(
                    forClasses: [NSURL.self],
                    options: [.urlReadingFileURLsOnly: true]
                ) as? [URL], !urls.isEmpty else {
                    return false
                }
                let targetSubdir: String? = (row >= 0 && row < entries.count && entries[row].isDirectory)
                    ? entries[row].path
                    : nil
                DispatchQueue.main.async {
                    self.parent.onDropLocalURLs(urls, targetSubdir)
                }
                return true
            } else {
                guard let items = info.draggingPasteboard.pasteboardItems else { return false }
                let decoder = JSONDecoder()
                let remoteEntries: [FileEntry] = items.compactMap { item in
                    guard let data = item.data(forType: AndroidFilePromiseProvider.internalType) else { return nil }
                    return try? decoder.decode(FileEntry.self, from: data)
                }
                guard !remoteEntries.isEmpty else { return false }
                let targetLocalDir: URL? = (row >= 0 && row < entries.count && entries[row].isDirectory)
                    ? URL(fileURLWithPath: entries[row].path)
                    : nil
                DispatchQueue.main.async {
                    self.parent.onDropRemoteEntries(remoteEntries, targetLocalDir)
                }
                return true
            }
        }

        // MARK: - Context Menu

        private var contextTargetEntries: [FileEntry] = []

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView else { return }

            let clickedRow = tableView.clickedRow
            let targets = targetEntriesForAction(clickedRow: clickedRow >= 0 ? clickedRow : nil)
            contextTargetEntries = targets

            if targets.isEmpty {
                let newFolderItem = NSMenuItem(title: "New Folder…", action: #selector(menuNewFolder), keyEquivalent: "")
                newFolderItem.target = self
                menu.addItem(newFolderItem)
                return
            }

            let countSuffix = targets.count > 1 ? " (\(targets.count) items)" : ""

            if parent.pane == .remote {
                if parent.showMacPane {
                    let copyPane = NSMenuItem(title: "Copy to Mac Pane\(countSuffix)", action: #selector(menuCopyPrimary), keyEquivalent: "")
                    copyPane.target = self
                    menu.addItem(copyPane)
                }
                let copyChoose = NSMenuItem(title: "Copy to Mac Folder…\(countSuffix)", action: #selector(menuCopyChoose), keyEquivalent: "")
                copyChoose.target = self
                menu.addItem(copyChoose)

                if targets.count == 1, let single = targets.first {
                    let openTitle = single.isDirectory ? "Open Folder" : "Quick Open on Mac"
                    let openItem = NSMenuItem(title: openTitle, action: #selector(menuOpenSingle), keyEquivalent: "")
                    openItem.target = self
                    menu.addItem(openItem)

                    menu.addItem(.separator())

                    let renameItem = NSMenuItem(title: "Rename…", action: #selector(menuRenameSingle), keyEquivalent: "")
                    renameItem.target = self
                    menu.addItem(renameItem)

                    let copyPath = NSMenuItem(title: "Copy Remote Path", action: #selector(menuCopyRemotePath), keyEquivalent: "")
                    copyPath.target = self
                    menu.addItem(copyPath)
                }

                menu.addItem(.separator())

                let newFolderItem = NSMenuItem(title: "New Folder…", action: #selector(menuNewFolder), keyEquivalent: "")
                newFolderItem.target = self
                menu.addItem(newFolderItem)

                menu.addItem(.separator())

                let delItem = NSMenuItem(title: "Delete from Phone…\(countSuffix)", action: #selector(menuDelete), keyEquivalent: "")
                delItem.target = self
                menu.addItem(delItem)
            } else {
                if parent.isDeviceReady {
                    let copyPhone = NSMenuItem(title: "Copy to Phone\(countSuffix)", action: #selector(menuCopyPrimary), keyEquivalent: "")
                    copyPhone.target = self
                    menu.addItem(copyPhone)
                    menu.addItem(.separator())
                }

                if targets.count == 1, let single = targets.first {
                    let openItem = NSMenuItem(title: single.isDirectory ? "Open Folder" : "Open", action: #selector(menuOpenSingle), keyEquivalent: "")
                    openItem.target = self
                    menu.addItem(openItem)

                    let revealItem = NSMenuItem(title: "Reveal in Finder", action: #selector(menuRevealInFinder), keyEquivalent: "")
                    revealItem.target = self
                    menu.addItem(revealItem)

                    menu.addItem(.separator())

                    let renameItem = NSMenuItem(title: "Rename…", action: #selector(menuRenameSingle), keyEquivalent: "")
                    renameItem.target = self
                    menu.addItem(renameItem)
                }

                let newFolderItem = NSMenuItem(title: "New Folder…", action: #selector(menuNewFolder), keyEquivalent: "")
                newFolderItem.target = self
                menu.addItem(newFolderItem)

                menu.addItem(.separator())

                let trashItem = NSMenuItem(title: "Move to Trash…\(countSuffix)", action: #selector(menuDelete), keyEquivalent: "")
                trashItem.target = self
                menu.addItem(trashItem)
            }
        }

        @objc private func menuCopyPrimary() { parent.onCopyPrimary(contextTargetEntries) }
        @objc private func menuCopyChoose() { parent.onCopyChooseDestination(contextTargetEntries) }
        @objc private func menuOpenSingle() { if let first = contextTargetEntries.first { parent.onOpen(first) } }
        @objc private func menuRenameSingle() { if let first = contextTargetEntries.first { parent.onRename(first) } }
        @objc private func menuRevealInFinder() { if let first = contextTargetEntries.first { parent.onRevealInFinder(first) } }
        @objc private func menuNewFolder() { parent.onNewFolder() }
        @objc private func menuDelete() { parent.onDelete(contextTargetEntries) }
        @objc private func menuCopyRemotePath() {
            if let first = contextTargetEntries.first {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(first.path, forType: .string)
            }
        }
    }
}
