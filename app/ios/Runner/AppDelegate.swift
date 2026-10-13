import Flutter
import UIKit
import Photos
import ImageIO
import NetworkExtension
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TuantuLocalBox") {
      let channel = FlutterMethodChannel(name: "dev.tuantu/box", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in LocalBox.handle(call, result: result) }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TuantuHotspot") {
      let channel = FlutterMethodChannel(name: "dev.tuantu/hotspot", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        switch call.method {
        case "state": TuantuHotspot.state(result)
        case "boxCandidates": TuantuBoxDiscovery.discover(result)
        case "join":
          let args = call.arguments as? [String: String] ?? [:]
          TuantuHotspot.join(ssid: args["ssid"] ?? "", password: args["passphrase"] ?? "", result: result)
        case "cancelPending": TuantuHotspot.cancelPending(); result(nil)
        case "openSettings":
          // Public iOS API opens app settings, not the private App-Prefs Wi-Fi URL.
          if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
          }
          result(nil)
        default: result(FlutterMethodNotImplemented)
        }
      }
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "TuantuLivePhoto") {
      let channel = FlutterMethodChannel(name: "dev.tuantu/live_photo", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { call, result in
        if call.method == "savePair",
           let args = call.arguments as? [String: String],
           let still = args["still"], let video = args["video"] {
          TuantuLivePhoto.savePair(still: still, video: video, result: result)
          return
        }
        if call.method == "cancelExport" || call.method == "ackExport",
           let args = call.arguments as? [String: Any], let key = args["requestId"] as? String {
          TuantuLivePhoto.finishExport(key, cancel: call.method == "cancelExport")
          result(nil)
          return
        }
        if call.method == "excludeUploadBackup" {
          do {
            var url = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("UploadJobs", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            result(nil)
          } catch { result(FlutterError(code: "upload_storage", message: error.localizedDescription, details: nil)) }
          return
        }
        guard call.method == "exportPair",
              let args = call.arguments as? [String: Any],
              let id = args["id"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        TuantuLivePhoto.exportPair(id: id, key: args["requestId"] as? String ?? UUID().uuidString,
            timeout: (args["timeoutSeconds"] as? NSNumber)?.doubleValue ?? 90, result: result)
      }
    }
  }
}

// NetService supplies resolved sockaddr records. Persisting hostName alone can
// leave Dart/AVPlayer repeatedly resolving an unavailable Android .local name.
private final class TuantuBoxDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  private static var active: TuantuBoxDiscovery?
  private let browser = NetServiceBrowser()
  private var services: [NetService] = []
  private var replies: [FlutterResult] = []
  private var candidates: [[String: Any]] = []
  private var deadline: DispatchWorkItem?

  static func discover(_ reply: @escaping FlutterResult) {
    if let active = active { active.replies.append(reply); return }
    let discovery = TuantuBoxDiscovery()
    active = discovery
    discovery.replies.append(reply)
    discovery.browser.delegate = discovery
    discovery.browser.searchForServices(ofType: "_tuantu._tcp.", inDomain: "local.")
    let deadline = DispatchWorkItem { [weak discovery] in discovery?.finish() }
    discovery.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: deadline)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    services.append(service)
    service.delegate = self
    service.resolve(withTimeout: 3)
  }

  func netServiceDidResolveAddress(_ sender: NetService) {
    guard (1...65535).contains(sender.port) else { return }
    for data in sender.addresses ?? [] {
      let ip: String? = data.withUnsafeBytes { bytes in
        guard let raw = bytes.baseAddress, bytes.count >= MemoryLayout<sockaddr_in>.size else { return nil }
        let address = raw.assumingMemoryBound(to: sockaddr.self)
        guard address.pointee.sa_family == UInt8(AF_INET) else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(data.count), &host, socklen_t(host.count),
                          nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
      }
      if let ip = ip, !ip.hasPrefix("127.") {
        candidates.append(["ip": ip, "port": sender.port, "host": sender.hostName ?? ""])
      }
    }
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    finish()
  }

  private func finish() {
    guard Self.active === self else { return }
    deadline?.cancel()
    browser.stop()
    browser.delegate = nil
    for service in services { service.stop(); service.delegate = nil }
    services.removeAll()
    let callbacks = replies
    replies.removeAll()
    Self.active = nil
    for callback in callbacks { callback(candidates) }
  }
}

private enum TuantuHotspot {
  private static var applying = false
  private static var pending: FlutterResult?

  // Interface presence does not require precise-location authorization. iOS
  // does not expose the Wi-Fi radio toggle; absence means "not connected".
  static func wifiConnected() -> Bool {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0 else { return false }
    defer { if let list = list { freeifaddrs(list) } }
    var current = list
    while let item = current {
      let value = item.pointee
      if String(cString: value.ifa_name) == "en0",
         value.ifa_flags & UInt32(IFF_UP) != 0,
         value.ifa_flags & UInt32(IFF_RUNNING) != 0,
         let address = value.ifa_addr,
         address.pointee.sa_family == UInt8(AF_INET) || address.pointee.sa_family == UInt8(AF_INET6) {
        return true
      }
      current = value.ifa_next
    }
    return false
  }

  static func state(_ result: @escaping FlutterResult) {
    NEHotspotNetwork.fetchCurrent { network in
      DispatchQueue.main.async {
        var value: [String: Any] = ["connected": wifiConnected(), "enabled": true]
        if let network = network { value["ssid"] = network.ssid }
        result(value)
      }
    }
  }

  static func join(ssid: String, password: String, result: @escaping FlutterResult) {
    guard !applying else { result("busy"); return }
    guard !ssid.isEmpty, ssid.utf8.count <= 32, (8...63).contains(password.count) else {
      result("invalid_config"); return
    }
    guard UIApplication.shared.applicationState == .active else {
      result("not_foreground"); return
    }
    let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
    // Persist the approved configuration so subsequent visits can auto-join.
    configuration.joinOnce = false
    applying = true
    pending = result
    NEHotspotConfigurationManager.shared.apply(configuration) { error in
      DispatchQueue.main.async {
        applying = false
        let reply = pending
        pending = nil
        guard let reply = reply else { return }
        if let error = error as NSError? {
          if error.domain == NEHotspotConfigurationErrorDomain &&
              error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            reply("connected")
          } else if error.domain == NEHotspotConfigurationErrorDomain &&
              error.code == NEHotspotConfigurationError.userDenied.rawValue {
            reply("permission_denied")
          } else {
            reply("unavailable")
          }
        } else {
          // Approval is not proof of a working box; Flutter still probes HTTP.
          reply("connected")
        }
      }
    }
  }

  static func cancelPending() {
    // Apple provides no cancel-apply API. Suppress late navigation and do not
    // start another apply while the system request is still outstanding.
    let reply = pending
    pending = nil
    reply?("cancelled")
  }
}

// Export exact PHAssetResources as a pair. The plugin's independent image/video
// requests can pick an edited still and an original paired video.
private enum TuantuLivePhoto {
  // Keep the original Apple asset identifier and still-image-time track intact.
  // Rewriting them unnecessarily can move the key photo to the video midpoint.
  static func savePair(still: String, video: String, result: @escaping FlutterResult) {
    var identifier: String?
    PHPhotoLibrary.shared().performChanges({
      let request = PHAssetCreationRequest.forAsset()
      request.addResource(with: .photo, fileURL: URL(fileURLWithPath: still), options: nil)
      request.addResource(with: .pairedVideo, fileURL: URL(fileURLWithPath: video), options: nil)
      identifier = request.placeholderForCreatedAsset?.localIdentifier
    }) { success, error in
      DispatchQueue.main.async {
        guard success, let id = identifier else {
          result(FlutterError(code: "live_pair", message: error?.localizedDescription ?? "实况配对失败", details: nil))
          return
        }
        let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        let isLive = asset?.mediaSubtypes.contains(.photoLive) == true
        if !isLive, let asset = asset {
          PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
          }) { _, _ in
            DispatchQueue.main.async { result(["live": false]) }
          }
          return
        }
        result(["id": id, "live": true])
      }
    }
  }

  private static var exports: [String: TuantuLiveExport] = [:]
  static func finishExport(_ key: String, cancel: Bool) {
    let operation = exports.removeValue(forKey: key)
    if cancel { operation?.cancel() }
  }

  static func exportPair(id: String, key: String, timeout: Double, result: @escaping FlutterResult) {
    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
          asset.mediaSubtypes.contains(.photoLive) else {
      result(FlutterError(code: "live_missing", message: "实况照片不可用", details: nil))
      return
    }
    let resources = PHAssetResource.assetResources(for: asset)
    let editedPhoto = resources.first { $0.type == .fullSizePhoto }
    let editedVideo = resources.first { $0.type == .fullSizePairedVideo }
    let photo: PHAssetResource?
    let video: PHAssetResource?
    if editedPhoto != nil || editedVideo != nil {
      photo = editedPhoto
      video = editedVideo
    } else {
      photo = resources.first { $0.type == .photo }
      video = resources.first { $0.type == .pairedVideo }
    }
    guard let photo = photo, let video = video else {
      result(FlutterError(code: "live_incomplete", message: "找不到同一版本的实况资源", details: nil))
      return
    }
    let operation = TuantuLiveExport(photo: photo, video: video, result: result)
    exports[key] = operation
    operation.start(timeout: min(max(timeout, 1), 120))
    // Also clean up an unacknowledged response if the Flutter engine disappears.
    DispatchQueue.main.asyncAfter(deadline: .now() + min(max(timeout, 1), 120) + 15) {
      finishExport(key, cancel: true)
    }
  }
}

/// Serial disk streaming avoids loading a full Live video into memory. All
/// completion, timeout and cancellation paths are serialized and resolve once.
private final class TuantuLiveExport {
  private let queue = DispatchQueue(label: "dev.tuantu.live-export")
  private let photo: PHAssetResource
  private let video: PHAssetResource
  private var result: FlutterResult?
  private let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("tuantu_live_\(UUID().uuidString)", isDirectory: true)
  private var request: PHAssetResourceDataRequestID?
  private var handle: FileHandle?
  private var cancelled = false
  init(photo: PHAssetResource, video: PHAssetResource, result: @escaping FlutterResult) {
    self.photo = photo; self.video = video; self.result = result
  }
  func start(timeout: Double) {
    queue.async {
      do {
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        self.read(self.photo, name: "still") { still in
          self.read(self.video, name: "paired") { video in
            self.preview(still: still, video: video)
          }
        }
      } catch { self.fail(error.localizedDescription) }
    }
    queue.asyncAfter(deadline: .now() + timeout) {
      if self.result != nil { self.fail("实况导出超时，请确认原片已下载后重试") }
    }
  }
  func cancel() {
    queue.async { self.fail("已取消实况导出") }
  }
  private func read(_ resource: PHAssetResource, name: String, next: @escaping (URL) -> Void) {
    guard !cancelled else { return }
    let ext = (resource.originalFilename as NSString).pathExtension
    let url = directory.appendingPathComponent(name + "." + ext)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    do { handle = try FileHandle(forWritingTo: url) }
    catch { fail(error.localizedDescription); return }
    let options = PHAssetResourceRequestOptions()
    options.isNetworkAccessAllowed = true
    request = PHAssetResourceManager.default().requestData(for: resource, options: options,
      dataReceivedHandler: { data in
        // Photos delivers on a background queue; backpressure bounds buffered data.
        self.queue.sync {
          guard !self.cancelled else { return }
          do { try self.handle?.write(contentsOf: data) }
          catch { self.fail(error.localizedDescription) }
        }
      }, completionHandler: { error in
        self.queue.async {
          guard !self.cancelled else { return }
          self.request = nil
          do { try self.handle?.close(); self.handle = nil }
          catch { self.fail(error.localizedDescription); return }
          if let error = error { self.fail(error.localizedDescription); return }
          next(url)
        }
      })
  }
  private func preview(still: URL, video: URL) {
    guard !cancelled else { return }
    guard let source = CGImageSourceCreateWithURL(still as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
          ] as CFDictionary), let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.9) else {
      fail("无法生成实况封面"); return
    }
    let url = directory.appendingPathComponent("preview.jpg")
    do { try data.write(to: url, options: .atomic) }
    catch { fail(error.localizedDescription); return }
    complete(["still": still.path, "video": video.path, "preview": url.path,
              "name": photo.originalFilename])
  }
  private func fail(_ message: String) {
    guard !cancelled else { return }
    cancelled = true
    if let request = request { PHAssetResourceManager.default().cancelDataRequest(request) }
    request = nil
    try? handle?.close(); handle = nil
    try? FileManager.default.removeItem(at: directory)
    complete(FlutterError(code: "live_export", message: message, details: nil))
  }
  private func complete(_ value: Any) {
    guard let callback = result else { return }
    result = nil
    DispatchQueue.main.async { callback(value) }
  }
}
