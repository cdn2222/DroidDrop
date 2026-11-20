import Foundation
import XCTest
@testable import DroidDropCore

final class ADBParsersTests: XCTestCase {
    func testShellQuoteEscapesSpecialCharacters() {
        XCTAssertEqual(ADBParsers.shellQuote("/sdcard/Download"), "'/sdcard/Download'")
        XCTAssertEqual(ADBParsers.shellQuote("/sdcard/My Photos/it's $(rm -rf).jpg"), "'/sdcard/My Photos/it'\\''s $(rm -rf).jpg'")
        XCTAssertEqual(ADBParsers.shellQuote("a'b'c"), "'a'\\''b'\\''c'")
    }

    func testRemotePathOperations() {
        XCTAssertEqual(ADBParsers.normalizeRemotePath("sdcard/DCIM/"), "/sdcard/DCIM")
        XCTAssertEqual(ADBParsers.normalizeRemotePath("/sdcard/DCIM/../Download/./"), "/sdcard/Download")
        XCTAssertEqual(ADBParsers.normalizeRemotePath("/"), "/")
        XCTAssertEqual(ADBParsers.normalizeRemotePath(""), "/")

        XCTAssertEqual(ADBParsers.joinRemotePath("/sdcard", "Download"), "/sdcard/Download")
        XCTAssertEqual(ADBParsers.joinRemotePath("/", "sdcard"), "/sdcard")

        XCTAssertEqual(ADBParsers.parentRemotePath("/sdcard/DCIM/Camera"), "/sdcard/DCIM")
        XCTAssertEqual(ADBParsers.parentRemotePath("/sdcard"), "/")
        XCTAssertEqual(ADBParsers.parentRemotePath("/"), "/")

        let crumbs = ADBParsers.remoteBreadcrumbs(for: "/sdcard/DCIM/Camera")
        XCTAssertEqual(crumbs.map(\.title), ["/", "sdcard", "DCIM", "Camera"])
        XCTAssertEqual(crumbs.map(\.path), ["/", "/sdcard", "/sdcard/DCIM", "/sdcard/DCIM/Camera"])
    }

    func testParseDevices() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        R5CT123456A            device usb:1-1 product:dm1qxxx model:SM_S911B device:dm1q transport_id:1
        192.168.1.42:5555      unauthorized transport_id:2
        emulator-5554          offline transport_id:3
        """
        let devices = ADBParsers.parseDevices(output)
        XCTAssertEqual(devices.count, 3)

        XCTAssertEqual(devices[0].serial, "R5CT123456A")
        XCTAssertEqual(devices[0].state, .device)
        XCTAssertEqual(devices[0].displayName, "SM S911B")
        XCTAssertFalse(devices[0].isWireless)

        XCTAssertEqual(devices[1].serial, "192.168.1.42:5555")
        XCTAssertEqual(devices[1].state, .unauthorized)
        XCTAssertTrue(devices[1].isWireless)

        XCTAssertEqual(devices[2].serial, "emulator-5554")
        XCTAssertEqual(devices[2].state, .offline)
    }

    func testParseListOutputToyboxAndSymlinks() {
        let output = """
        total 64
        drwxrwx---  4 u0_a123 media_rw    3452 2025-10-31 14:22 .
        drwxrwx--- 12 u0_a123 media_rw    3452 2025-10-31 14:22 ..
        drwxrwx---  2 u0_a123 media_rw    3452 2025-10-31 14:22 .hidden_dir
        drwxrwx---  5 u0_a123 media_rw    3452 2025-11-01 09:15 DCIM
        -rw-rw----  1 u0_a123 media_rw 4512345 2025-11-02 18:45 My Vacation Photo (2025) 🏖️.jpg
        -rw-rw----  1 u0_a123 media_rw     128 2025-11-03 08:00 file with 'quotes' & $var.txt
        lrwxrwxrwx  1 root    root          21 2025-01-01 00:00 sdcard -> /storage/emulated/0
        """
        let entries = ADBParsers.parseListOutput(output, directory: "/sdcard")
        XCTAssertEqual(entries.count, 5)

        XCTAssertTrue(entries[0].isHidden)
        XCTAssertEqual(entries[0].name, ".hidden_dir")
        XCTAssertTrue(entries[0].isDirectory)

        XCTAssertEqual(entries[1].name, "DCIM")
        XCTAssertEqual(entries[1].path, "/sdcard/DCIM")
        XCTAssertTrue(entries[1].isDirectory)

        XCTAssertEqual(entries[2].name, "My Vacation Photo (2025) 🏖️.jpg")
        XCTAssertEqual(entries[2].size, 4_512_345)
        XCTAssertFalse(entries[2].isDirectory)
        XCTAssertNotNil(entries[2].modifiedDate)

        XCTAssertEqual(entries[3].name, "file with 'quotes' & $var.txt")
        XCTAssertEqual(entries[3].size, 128)

        XCTAssertEqual(entries[4].name, "sdcard")
        XCTAssertTrue(entries[4].isSymlink)
        XCTAssertEqual(entries[4].symlinkTarget, "/storage/emulated/0")
    }

    func testParseListOutputBusyBoxDateFormat() {
        let output = """
        drwxr-xr-x 2 root root 4096 Oct 31 14:22 Download
        -rw-r--r-- 1 root root 1024 Oct 31  2024 notes.txt
        """
        let entries = ADBParsers.parseListOutput(output, directory: "/sdcard")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].name, "Download")
        XCTAssertTrue(entries[0].isDirectory)
        XCTAssertEqual(entries[1].name, "notes.txt")
        XCTAssertEqual(entries[1].size, 1024)
    }

    func testParseStorageOutput() {
        let output = """
        Filesystem      1K-blocks     Used Available Use% Mounted on
        /dev/fuse       115343360 48234496  67108864  42% /storage/emulated
        """
        let info = ADBParsers.parseStorageOutput(output)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.totalBytes, 115_343_360 * 1024)
        XCTAssertEqual(info?.usedBytes, 48_234_496 * 1024)
        XCTAssertEqual(info?.availableBytes, 67_108_864 * 1024)
    }

    func testParseProgressLine() {
        let p1 = ADBParsers.parseProgressLine("[ 42%] /sdcard/Download/Big Movie.mp4")
        XCTAssertEqual(p1.percent ?? -1, 0.42, accuracy: 0.001)
        XCTAssertEqual(p1.currentFile, "Big Movie.mp4")

        let p2 = ADBParsers.parseProgressLine("[100%] /sdcard/photo.jpg")
        XCTAssertEqual(p2.percent ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(p2.currentFile, "photo.jpg")

        let p3 = ADBParsers.parseProgressLine("/sdcard/photo.jpg: 1 file pulled, 0 skipped.")
        XCTAssertNil(p3.percent)
    }

    func testLocalFileServiceLifecycleAndSorting() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("DroidDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let folderURL = try LocalFileService.createDirectory(in: tmp, name: "Photos")
        let fileA = tmp.appendingPathComponent("b.txt")
        let fileB = tmp.appendingPathComponent("a.txt")
        try Data("hello".utf8).write(to: fileA)
        try Data("hello world!".utf8).write(to: fileB)

        let entries = try LocalFileService.listDirectory(at: tmp, showHidden: false)
        XCTAssertEqual(entries.count, 3)

        let sortedByName = LocalFileService.sortEntries(entries, by: .name, ascending: true)
        // Folders always come first
        XCTAssertEqual(sortedByName.map(\.name), ["Photos", "a.txt", "b.txt"])

        let sortedBySizeDesc = LocalFileService.sortEntries(entries, by: .size, ascending: false)
        XCTAssertEqual(sortedBySizeDesc.map(\.name), ["Photos", "a.txt", "b.txt"])

        let renamed = try LocalFileService.rename(itemAt: folderURL, to: "Camera")
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
    }
}
