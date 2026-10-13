import AVFoundation
import Flutter
import UIKit

/// Foreground-only hosting. No background mode, CloudKit or ubiquitous container.
enum LocalBox {
  private static let thumbnails = DispatchQueue(label: "dev.tuantu.box.thumbnails", qos: .utility)
  private static var previousIdleTimer: Bool?

  /// Exclude the directory, rather than individual files: SQLite WAL/SHM,
  /// atomic replacements and files uploaded later must also stay out of backup.
  static func prepareDirectory(at location: URL) throws -> URL {
    var directory = location
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    guard try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true else {
      throw NSError(domain: "TuantuBox", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "无法确认盒子数据已排除 iCloud 备份，未开启盒子。"
      ])
    }
    return directory
  }

  static func prepareStorage() throws -> URL {
    let manager = FileManager.default
    let support = try manager.url(for: .applicationSupportDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true)
    let documents = try manager.url(for: .documentDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true)
    let library = try manager.url(for: .libraryDirectory,
        in: .userDomainMask, appropriateFor: nil, create: true)
    // Include upload staging, model copies, transfer/download history and
    // preferences. Photos explicitly exported to Photos remain system-managed.
    _ = try prepareDirectory(at: support)
    _ = try prepareDirectory(at: documents)
    _ = try prepareDirectory(at: library.appendingPathComponent("Preferences", isDirectory: true))
    return try prepareDirectory(at: support.appendingPathComponent("TuantuBox", isDirectory: true))
  }

  static func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "prepareStorage":
      do {
        let root = try prepareStorage()
        result(["path": root.path, "backupExcluded": true])
      } catch {
        result(FlutterError(code: "box_storage", message: error.localizedDescription, details: nil))
      }
    case "start":
      if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
      UIApplication.shared.isIdleTimerDisabled = true
      result(nil)
    case "stop":
      if let previous = previousIdleTimer { UIApplication.shared.isIdleTimerDisabled = previous }
      previousIdleTimer = nil
      result(nil)
    case "videoThumb":
      guard let args = call.arguments as? [String: Any],
            let src = args["src"] as? String, let dest = args["dest"] as? String else {
        result(FlutterError(code: "box_thumb", message: "缺少视频路径", details: nil))
        return
      }
      let size = max(1, min(2048, (args["maxWidth"] as? NSNumber)?.intValue ?? 480))
      thumbnails.async {
        autoreleasepool {
          do {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: src)))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: CGFloat(size), height: CGFloat(size))
            let frame = try generator.copyCGImage(at: .zero, actualTime: nil)
            guard let data = UIImage(cgImage: frame).jpegData(compressionQuality: 0.85) else {
              throw NSError(domain: "TuantuBox", code: 2)
            }
            let destination = URL(fileURLWithPath: dest)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            let width = frame.width, height = frame.height
            DispatchQueue.main.async { result(["ok": true, "width": width, "height": height]) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "box_thumb", message: error.localizedDescription, details: nil))
            }
          }
        }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }
}
