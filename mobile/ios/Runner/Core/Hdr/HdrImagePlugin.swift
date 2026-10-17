import Flutter
import ImageIO
import Photos
import UIKit

final class HdrImagePlugin: NSObject, FlutterPlugin {
  static let viewType = "immich/hdr_image_view"
  static let channelName = "immich/hdr_image"

  static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    registrar.register(HdrImageViewFactory(messenger: messenger), withId: viewType)
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        result(isSupported())
      case "preload":
        if isSupported() {
          HdrImageCache.preload(HdrImageCache.Source(params: call.arguments as? [String: Any] ?? [:]))
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  static func isSupported() -> Bool {
    guard #available(iOS 17.0, *) else { return false }
    return UIScreen.main.potentialEDRHeadroom > 1.0
  }
}

private final class HdrImageViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    HdrImageView(frame: frame, viewId: viewId, params: args as? [String: Any] ?? [:], messenger: messenger)
  }
}

/// Creation params: `localId` (PHAsset local identifier) or `url` (remote original), optional `maxSize`.
/// Cached renditions show instantly; ones that had to load fade in over the SDR image below.
private final class HdrImageView: NSObject, FlutterPlatformView {
  private static let fadeDuration: TimeInterval = 0.18
  private static let headroomTimeout: CFTimeInterval = 0.8

  private let imageView: UIImageView
  private let channel: FlutterMethodChannel
  private var lastResult: [String: Any]?

  init(frame: CGRect, viewId: Int64, params: [String: Any], messenger: FlutterBinaryMessenger) {
    imageView = UIImageView(frame: frame)
    imageView.contentMode = .scaleAspectFit
    imageView.backgroundColor = .clear
    imageView.isUserInteractionEnabled = false
    imageView.isAccessibilityElement = false
    if #available(iOS 17.0, *) {
      imageView.preferredImageDynamicRange = .high
    }
    channel = FlutterMethodChannel(name: "\(HdrImagePlugin.viewType)_\(viewId)", binaryMessenger: messenger)
    super.init()

    channel.setMethodCallHandler { [weak self] call, result in
      if call.method == "getResult" {
        result(self?.lastResult)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    HdrImageCache.get(HdrImageCache.Source(params: params)) { [weak self] result, cached in
      self?.onLoaded(result, cached: cached)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView { imageView }

  private func onLoaded(_ result: Result<UIImage?, Error>, cached: Bool) {
    switch result {
    case .success(let image?):
      imageView.image = image
      if !cached {
        fadeInWhenHeadroomAvailable()
      }
      report(["hdr": true, "cached": cached])
    case .success(nil):
      report(["hdr": false])
    case .failure(let error):
      report(["hdr": false, "error": error.localizedDescription])
    }
  }

  /// The display only raises its HDR headroom once HDR content is on screen. Fading in before that plays the fade
  /// at SDR brightness and then jumps, so show the image almost invisibly first and fade once headroom is there.
  private func fadeInWhenHeadroomAvailable() {
    imageView.alpha = 0.01
    let deadline = CACurrentMediaTime() + Self.headroomTimeout
    let fade = { [weak self] in
      guard let self else { return }
      UIView.animate(withDuration: Self.fadeDuration, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
        self.imageView.alpha = 1
      }
    }
    guard #available(iOS 17.0, *) else { return fade() }

    func poll() {
      if UIScreen.main.currentEDRHeadroom > 1.05 || CACurrentMediaTime() > deadline {
        return fade()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
        if self != nil { poll() }
      }
    }
    poll()
  }

  private func report(_ result: [String: Any]) {
    lastResult = result
    channel.invokeMethod("onResult", arguments: result)
  }
}

/// Decoded HDR renditions by source, so neighbours can be preloaded and revisited photos show instantly.
/// SDR results are remembered as `nil`. Callbacks run on the main thread.
enum HdrImageCache {
  struct Source {
    let localId: String?
    let url: String?
    let maxSize: Int

    init(params: [String: Any]) {
      localId = params["localId"] as? String
      url = params["url"] as? String
      maxSize = (params["maxSize"] as? NSNumber)?.intValue ?? HdrImageLoader.defaultMaxSize
    }

    var key: String { localId.map { "local:\($0)" } ?? "remote:\(url ?? "")" }
  }

  private final class Entry {
    let image: UIImage?
    init(_ image: UIImage?) { self.image = image }
  }

  private static let cache: NSCache<NSString, Entry> = {
    let cache = NSCache<NSString, Entry>()
    // HDR renditions are decoded to 16-bit floats; cost is in bytes.
    cache.totalCostLimit = Int(min(512 * 1024 * 1024, ProcessInfo.processInfo.physicalMemory / 10))
    return cache
  }()
  private static var pending: [String: [(Result<UIImage?, Error>, Bool) -> Void]] = [:]

  /// Calls [completion] with the rendition (nil for SDR) and whether it was already cached.
  static func get(_ source: Source, completion: @escaping (Result<UIImage?, Error>, Bool) -> Void) {
    if let entry = cache.object(forKey: source.key as NSString) {
      return completion(.success(entry.image), true)
    }
    load(source, background: false) { completion($0, false) }
  }

  static func preload(_ source: Source) {
    if cache.object(forKey: source.key as NSString) != nil || pending[source.key] != nil { return }
    load(source, background: true) { _ in }
  }

  private static func load(_ source: Source, background: Bool, completion: @escaping (Result<UIImage?, Error>) -> Void) {
    let key = source.key
    if pending[key] != nil {
      pending[key]?.append { result, _ in completion(result) }
      return
    }
    pending[key] = [{ result, _ in completion(result) }]

    _ = HdrImageLoader.load(localId: source.localId, url: source.url, maxSize: source.maxSize, background: background) {
      result in
      DispatchQueue.main.async {
        if case .success(let image) = result {
          cache.setObject(Entry(image), forKey: key as NSString, cost: cost(of: image))
        }
        pending.removeValue(forKey: key)?.forEach { $0(result, false) }
      }
    }
  }

  private static func cost(of image: UIImage?) -> Int {
    guard let image else { return 1 }
    if let cgImage = image.cgImage { return cgImage.bytesPerRow * cgImage.height }
    return Int(image.size.width * image.scale * image.size.height * image.scale) * 8
  }
}

/// Fetches originals and decodes them with gain maps applied. Yields `nil` for SDR images.
enum HdrImageLoader {
  static let defaultMaxSize = 4096
  private static let queue = DispatchQueue(label: "immich.hdr.decode", qos: .userInitiated, attributes: .concurrent)
  // Preloads queue separately so they never delay the photo on screen.
  private static let backgroundQueue = DispatchQueue(label: "immich.hdr.preload", qos: .utility)

  final class Task {
    fileprivate var dataTask: URLSessionDataTask?
    fileprivate var imageRequestId: PHImageRequestID?
    private(set) var isCancelled = false

    func cancel() {
      isCancelled = true
      dataTask?.cancel()
      if let imageRequestId { PHImageManager.default().cancelImageRequest(imageRequestId) }
    }
  }

  struct LoadError: LocalizedError {
    let errorDescription: String?
  }

  static func load(
    localId: String?,
    url: String?,
    maxSize: Int,
    background: Bool = false,
    completion: @escaping (Result<UIImage?, Error>) -> Void
  ) -> Task {
    let task = Task()
    let onData: (Data) -> Void = { data in
      (background ? backgroundQueue : queue).async {
        guard !task.isCancelled else { return }
        completion(.success(decode(data: data, maxSize: maxSize)))
      }
    }

    if let localId {
      guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localId], options: nil).firstObject else {
        completion(.failure(LoadError(errorDescription: "Asset not found")))
        return task
      }
      let options = PHImageRequestOptions()
      options.isNetworkAccessAllowed = true
      options.deliveryMode = .highQualityFormat
      options.version = .current
      task.imageRequestId = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) {
        data, _, _, info in
        guard let data else {
          let error = info?[PHImageErrorKey] as? Error
          return completion(.failure(error ?? LoadError(errorDescription: "No image data")))
        }
        onData(data)
      }
    } else if let url, let requestUrl = URL(string: url) {
      var request = URLRequest(url: requestUrl)
      request.cachePolicy = .returnCacheDataElseLoad
      let dataTask = URLSessionManager.shared.session.dataTask(with: request) { data, response, error in
        if let error { return completion(.failure(error)) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
          return completion(.failure(LoadError(errorDescription: "HTTP \(http.statusCode) for original")))
        }
        guard let data else { return completion(.failure(LoadError(errorDescription: "No data received"))) }
        onData(data)
      }
      if background { dataTask.priority = URLSessionTask.lowPriority }
      task.dataTask = dataTask
      dataTask.resume()
    } else {
      completion(.failure(LoadError(errorDescription: "Either localId or url is required")))
    }
    return task
  }

  private static func decode(data: Data, maxSize: Int) -> UIImage? {
    guard #available(iOS 17.0, *) else { return nil }

    // iOS 18 ImageIO also decodes ISO 21496-1 gain maps (Android-made Ultra HDR).
    if #available(iOS 18.0, *),
       let source = CGImageSourceCreateWithData(data as CFData, nil) {
      let options: [CFString: Any] = [
        kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSize,
        kCGImageSourceShouldCacheImmediately: true,
      ]
      if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
        let image = UIImage(cgImage: cgImage)
        if image.isHighDynamicRange { return image }
      }
    }

    var config = UIImageReader.Configuration()
    config.prefersHighDynamicRange = true
    config.preferredThumbnailSize = CGSize(width: maxSize, height: maxSize)
    guard let image = UIImageReader(configuration: config).image(data: data), image.isHighDynamicRange else {
      return nil
    }
    return image
  }
}
