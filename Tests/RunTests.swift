import DroidDropCore
import Foundation

var passed = 0
var failed = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition() {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String = "", file: String = #file, line: Int = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        fputs("FAIL [\(file):\(line)]: \(message) expected \(b), got \(a)\n", stderr)
    }
}

// 1. Shell quoting
expectEqual(ADBParsers.shellQuote("/sdcard/Download"), "'/sdcard/Download'", "basic quote")
expectEqual(
    ADBParsers.shellQuote("/sdcard/My Photos/it's $(rm -rf).jpg"),
    "'/sdcard/My Photos/it'\\''s $(rm -rf).jpg'",
    "special chars & single quote"
)

// 2. Remote path manipulation
expectEqual(ADBParsers.normalizeRemotePath("sdcard/DCIM/"), "/sdcard/DCIM", "normalize relative")
expectEqual(ADBParsers.normalizeRemotePath("/sdcard/DCIM/../Download/./"), "/sdcard/Download", "normalize dotdot")
expectEqual(ADBParsers.normalizeRemotePath("/"), "/", "normalize root")
expectEqual(ADBParsers.joinRemotePath("/sdcard", "Download"), "/sdcard/Download", "join")
expectEqual(ADBParsers.joinRemotePath("/", "sdcard"), "/sdcard", "join root")
expectEqual(ADBParsers.parentRemotePath("/sdcard/DCIM/Camera"), "/sdcard/DCIM", "parent")
expectEqual(ADBParsers.parentRemotePath("/sdcard"), "/", "parent of top")
expectEqual(ADBParsers.parentRemotePath("/"), "/", "parent of root")
let crumbs = ADBParsers.remoteBreadcrumbs(for: "/sdcard/DCIM/Camera")
expectEqual(crumbs.map(\.title), ["/", "sdcard", "DCIM", "Camera"], "crumb titles")
expectEqual(crumbs.map(\.path), ["/", "/sdcard", "/sdcard/DCIM", "/sdcard/DCIM/Camera"], "crumb paths")

// 3. Devices parser
let devOutput = """
* daemon not running; starting now at tcp:5037
* daemon started successfully
List of devices attached
R5CT123456A            device usb:1-1 product:dm1qxxx model:SM_S911B device:dm1q transport_id:1
192.168.1.42:5555      unauthorized transport_id:2
emulator-5554          offline transport_id:3
"""
let devices = ADBParsers.parseDevices(devOutput)
expectEqual(devices.count, 3, "device count")
expectEqual(devices[0].displayName, "SM S911B", "device display name")
expectEqual(devices[0].state, .device, "device state")
expect(!devices[0].isWireless, "usb device")
expectEqual(devices[1].state, .unauthorized, "unauthorized state")
expect(devices[1].isWireless, "wifi device")
expectEqual(devices[2].state, .offline, "offline state")

// 4. Toybox ls -la parser + symlinks + spaces + Unicode + quotes
let lsOutput = """
total 64
drwxrwx---  4 u0_a123 media_rw    3452 2025-10-31 14:22 .
drwxrwx--- 12 u0_a123 media_rw    3452 2025-10-31 14:22 ..
drwxrwx---  2 u0_a123 media_rw    3452 2025-10-31 14:22 .hidden_dir
drwxrwx---  5 u0_a123 media_rw    3452 2025-11-01 09:15 DCIM
-rw-rw----  1 u0_a123 media_rw 4512345 2025-11-02 18:45 My Vacation Photo (2025) 🏖️.jpg
-rw-rw----  1 u0_a123 media_rw     128 2025-11-03 08:00 file with 'quotes' & $var.txt
lrwxrwxrwx  1 root    root          21 2025-01-01 00:00 sdcard -> /storage/emulated/0
"""
let entries = ADBParsers.parseListOutput(lsOutput, directory: "/sdcard")
expectEqual(entries.count, 5, "ls entries count")
expect(entries[0].isHidden && entries[0].isDirectory, "hidden dir")
expectEqual(entries[1].path, "/sdcard/DCIM", "DCIM path")
expectEqual(entries[2].name, "My Vacation Photo (2025) 🏖️.jpg", "unicode spaces filename")
expectEqual(entries[2].size, 4_512_345, "file size")
expect(entries[2].modifiedDate != nil, "iso date parsed")
expectEqual(entries[3].name, "file with 'quotes' & $var.txt", "quoted filename")
expect(entries[4].isSymlink, "symlink flag")
expectEqual(entries[4].name, "sdcard", "symlink name")
expectEqual(entries[4].symlinkTarget, "/storage/emulated/0", "symlink target")

// 5. BusyBox date format
let busyboxOut = """
drwxr-xr-x 2 root root 4096 Oct 31 14:22 Download
-rw-r--r-- 1 root root 1024 Oct 31  2024 notes.txt
"""
let bbEntries = ADBParsers.parseListOutput(busyboxOut, directory: "/sdcard")
expectEqual(bbEntries.count, 2, "busybox count")
expectEqual(bbEntries[0].name, "Download", "busybox dir")
expectEqual(bbEntries[1].size, 1024, "busybox size")

// 6. Storage df -k parser
let dfOut = """
Filesystem      1K-blocks     Used Available Use% Mounted on
/dev/fuse       115343360 48234496  67108864  42% /storage/emulated
"""
let storage = ADBParsers.parseStorageOutput(dfOut)
expect(storage != nil, "storage parsed")
expectEqual(storage?.availableBytes, 67_108_864 * 1024, "storage available")

// 7. Transfer progress parser
let p1 = ADBParsers.parseProgressLine("[ 42%] /sdcard/Download/Big Movie.mp4")
expect(abs((p1.percent ?? -1) - 0.42) < 0.001, "progress 42%")
expectEqual(p1.currentFile, "Big Movie.mp4", "progress filename")
let p2 = ADBParsers.parseProgressLine("[100%] /sdcard/photo.jpg")
expect(abs((p2.percent ?? -1) - 1.0) < 0.001, "progress 100%")
let p3 = ADBParsers.parseProgressLine("/sdcard/photo.jpg: 1 file pulled, 0 skipped.")
expect(p3.percent == nil, "summary line ignored")

// 8. ADB discovery finds platform-tools on this Mac
let discoveredADB = ADBClient.discoverADBPath()
expect(discoveredADB != nil, "adb discovered on system")

// 9. LocalFileService create, list, sort, rename
do {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("DroidDropTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let folderURL = try LocalFileService.createDirectory(in: tmp, name: "Photos")
    try Data("hello".utf8).write(to: tmp.appendingPathComponent("b.txt"))
    try Data("hello world!".utf8).write(to: tmp.appendingPathComponent("a.txt"))

    let listed = try LocalFileService.listDirectory(at: tmp, showHidden: false)
    expectEqual(listed.count, 3, "local list count")

    let byName = LocalFileService.sortEntries(listed, by: .name, ascending: true)
    expectEqual(byName.map(\.name), ["Photos", "a.txt", "b.txt"], "folders first then name")

    let bySizeDesc = LocalFileService.sortEntries(listed, by: .size, ascending: false)
    expectEqual(bySizeDesc.map(\.name), ["Photos", "a.txt", "b.txt"], "folders first then size desc")

    let renamed = try LocalFileService.rename(itemAt: folderURL, to: "Camera")
    expect(FileManager.default.fileExists(atPath: renamed.path), "renamed exists")
} catch {
    failed += 1
    fputs("FAIL: LocalFileService threw \(error)\n", stderr)
}

print("DroidDropCore tests: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }
