import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  func testProductionStorageMarksMediaAndMetadataDirectories() throws {
    let root = try LocalBox.prepareStorage()
    let manager = FileManager.default
    let support = try manager.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: false)
    let documents = try manager.url(for: .documentDirectory,
        in: .userDomainMask, appropriateFor: nil, create: false)
    let library = try manager.url(for: .libraryDirectory,
        in: .userDomainMask, appropriateFor: nil, create: false)
    XCTAssertEqual(root, support.appendingPathComponent("TuantuBox", isDirectory: true))
    for directory in [root, support, documents, library.appendingPathComponent("Preferences", isDirectory: true)] {
      XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
  }

  @MainActor
  func testStoppingBoxRestoresOriginalIdleTimerAfterRepeatedStarts() {
    let original = UIApplication.shared.isIdleTimerDisabled
    defer { UIApplication.shared.isIdleTimerDisabled = original }
    UIApplication.shared.isIdleTimerDisabled = false
    for _ in 0..<2 {
      LocalBox.handle(FlutterMethodCall(methodName: "start", arguments: nil)) { _ in }
      XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
    }
    LocalBox.handle(FlutterMethodCall(methodName: "stop", arguments: nil)) { _ in }
    XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled)
  }

  func testBoxBackupExclusionSurvivesReopenAndAtomicWrites() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("box-privacy-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let prepared = try LocalBox.prepareDirectory(at: root)
    for name in ["tuantu.db", "tuantu.db-wal", "tuantu.db-shm", "photo.jpg"] {
      let file = prepared.appendingPathComponent(name)
      try Data([1, 2, 3]).write(to: file, options: .atomic)
      try Data([4, 5, 6]).write(to: file, options: .atomic)
    }
    _ = try LocalBox.prepareDirectory(at: root)
    XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("photo.jpg")), Data([4, 5, 6]))
  }

  func testPrivacyFailureDoesNotReplaceExistingFile() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data([7]).write(to: file)
    XCTAssertThrowsError(try LocalBox.prepareDirectory(at: file))
    XCTAssertEqual(try Data(contentsOf: file), Data([7]))
  }

}
