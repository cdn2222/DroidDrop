import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct DroidDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup("DroidDrop") {
            ContentView(vm: viewModel)
        }
        .defaultSize(width: 1080, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Folder on Phone") {
                    viewModel.newFolderPane = .remote
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!viewModel.isDeviceReady)

                Button("Upload Files to Phone…") {
                    viewModel.chooseFilesAndPushToAndroid()
                }
                .keyboardShortcut("u", modifiers: [.command])
                .disabled(!viewModel.isDeviceReady)
            }

            CommandMenu("View") {
                Button("Refresh") {
                    Task {
                        await viewModel.refreshDevices(silent: false)
                        viewModel.refreshLocal()
                        await viewModel.refreshRemoteAndStorage()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command])

                Divider()

                Button(viewModel.showMacPane ? "Hide Mac Pane" : "Show Mac Pane") {
                    viewModel.showMacPane.toggle()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])

                Button(viewModel.showHiddenFiles ? "Hide Hidden Files" : "Show Hidden Files") {
                    viewModel.showHiddenFiles.toggle()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }
    }
}
