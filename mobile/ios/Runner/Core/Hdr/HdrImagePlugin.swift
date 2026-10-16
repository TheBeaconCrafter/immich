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
private final class HdrImageView: NSObject, FlutterPlatformView {
  private let imageView: UIImageView
  private let channel: FlutterMethodChannel
  private var loadTask: HdrImageLoader.Task?
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

    let maxSize = (params["maxSize"] as? NSNumber)?.intValue ?? HdrImageLoader.defaultMaxSize
    loadTask = HdrImageLoader.load(
      localId: params["localId"] as? String,
      url: params["url"] as? String,
      maxSize: maxSize
    ) { [weak self] result in
      DispatchQueue.main.async { self?.onLoaded(result) }
    }
  }

  deinit {
    loadTask?.cancel()
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView { imageView }

  private func onLoaded(_ result: Result<UIImage?, Error>) {
    loadTask = nil
    switch result {
    case .success(let image?):
      imageView.image = image
      report(["hdr": true])
    case .success(nil):
      report(["hdr": false])
    case .failure(let error):
      report(["hdr": false, "error": error.localizedDescription])
    }
  }

  private func report(_ result: [String: Any]) {
    lastResult = result
    channel.invokeMethod("onResult", arguments: result)
  }
}

/// Yields `nil` for SDR images.
enum HdrImageLoader {
  static let defaultMaxSize = 4096
  private static let queue = DispatchQueue(label: "immich.hdr.decode", qos: .userInitiated, attributes: .concurrent)

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
    completion: @escaping (Result<UIImage?, Error>) -> Void
  ) -> Task {
    let task = Task()
    let onData: (Data) -> Void = { data in
      queue.async {
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
