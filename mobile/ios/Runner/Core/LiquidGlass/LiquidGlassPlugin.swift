import Flutter
import UIKit

/// Fork feature: native Liquid Glass components for the Flutter UI (iOS 26+), see FORK.md.
///
/// - `immich/glass_surface`: a glass material platform view drawn behind Flutter content (sheets, button groups).
/// - `immich/glass_menu`: an invisible native button over a Flutter menu trigger that opens a native UIMenu.
/// - `immich/liquid_glass` channel: drives a native UITabBar laid over the Flutter view.
final class LiquidGlassPlugin: NSObject {
  private static var tabBar: NativeTabBar?

  static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    registrar.register(GlassSurfaceFactory(), withId: "immich/glass_surface")
    registrar.register(GlassMenuFactory(messenger: messenger), withId: "immich/glass_menu")

    let channel = FlutterMethodChannel(name: "immich/liquid_glass", binaryMessenger: messenger)
    let tabBar = NativeTabBar(channel: channel)
    Self.tabBar = tabBar
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "tabBar.update":
        result(tabBar.update(call.arguments as? [String: Any] ?? [:]))
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

// MARK: - Glass surface

private final class GlassSurfaceFactory: NSObject, FlutterPlatformViewFactory {
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    GlassSurfaceView(frame: frame, params: args as? [String: Any] ?? [:])
  }
}

/// Creation params: `radius` (points, negative for a capsule), `topOnly` (round only the top corners).
private final class GlassSurfaceView: NSObject, FlutterPlatformView {
  private let effectView: UIVisualEffectView

  init(frame: CGRect, params: [String: Any]) {
    if #available(iOS 26.0, *) {
      effectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }
    effectView.frame = frame
    effectView.isUserInteractionEnabled = false
    super.init()

    let radius = (params["radius"] as? NSNumber)?.doubleValue ?? 0
    if #available(iOS 26.0, *), radius < 0 {
      effectView.cornerConfiguration = .capsule()
    } else {
      effectView.layer.cornerRadius = radius
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = true
      if params["topOnly"] as? Bool == true {
        effectView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
      }
    }
  }

  func view() -> UIView { effectView }
}

// MARK: - Native menu

private final class GlassMenuFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    GlassMenuView(frame: frame, viewId: viewId, messenger: messenger)
  }
}

/// A transparent button covering the Flutter menu trigger. The menu's items are fetched from Flutter each time it
/// opens (`items` → list of {id, title, image?, destructive, disabled, section}) and a pick is reported via `select`.
private final class GlassMenuView: NSObject, FlutterPlatformView {
  private let button = UIButton(type: .custom)
  private let channel: FlutterMethodChannel

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "immich/glass_menu_\(viewId)", binaryMessenger: messenger)
    super.init()
    button.frame = frame
    button.backgroundColor = .clear
    button.showsMenuAsPrimaryAction = true
    if #available(iOS 16.0, *) { button.preferredMenuElementOrder = .fixed }
    button.menu = UIMenu(children: [
      UIDeferredMenuElement.uncached { [weak self] completion in
        guard let self else { return completion([]) }
        self.channel.invokeMethod("items", arguments: nil) { result in
          completion(self.elements(from: result as? [[String: Any]] ?? []))
        }
      },
    ])
  }

  deinit {
    channel.setMethodCallHandler(nil)
  }

  func view() -> UIView { button }

  private func elements(from items: [[String: Any]]) -> [UIMenuElement] {
    var sections: [[UIMenuElement]] = [[]]
    for item in items {
      if item["divider"] as? Bool == true {
        sections.append([])
        continue
      }
      let id = (item["id"] as? NSNumber)?.intValue ?? 0
      let image = (item["image"] as? FlutterStandardTypedData)
        .flatMap { UIImage(data: $0.data, scale: 3) }?
        .withRenderingMode(.alwaysTemplate)
      let action = UIAction(title: item["title"] as? String ?? "", image: image) { [weak self] _ in
        self?.channel.invokeMethod("select", arguments: id)
      }
      if item["destructive"] as? Bool == true { action.attributes.insert(.destructive) }
      if item["disabled"] as? Bool == true { action.attributes.insert(.disabled) }
      sections[sections.count - 1].append(action)
    }
    let nonEmpty = sections.filter { !$0.isEmpty }
    if nonEmpty.count <= 1 { return nonEmpty.first ?? [] }
    return nonEmpty.map { UIMenu(options: .displayInline, children: $0) }
  }
}

// MARK: - Native tab bar

/// A UITabBar laid over the Flutter view; Flutter reserves its space, keeps it in sync and hides it under other
/// routes. Update args: `items` [{title, symbol, selectedSymbol, enabled}], `selected`, `visible`.
private final class NativeTabBar: NSObject, UITabBarDelegate {
  private let channel: FlutterMethodChannel
  private var tabBar: UITabBar?
  private var itemsKey: [String] = []
  private var visible = false

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  /// Returns the bar's height above the bottom safe area, or 0 if it cannot be shown.
  func update(_ args: [String: Any]) -> Double {
    guard let tabBar = ensureTabBar() else { return 0 }

    let items = args["items"] as? [[String: Any]] ?? []
    let key = items.map { "\($0["title"] ?? "")|\($0["symbol"] ?? "")|\($0["enabled"] ?? true)" }
    if key != itemsKey {
      itemsKey = key
      tabBar.setItems(items.enumerated().map { index, item in
        let tabItem = UITabBarItem(
          title: item["title"] as? String,
          image: UIImage(systemName: item["symbol"] as? String ?? "circle"),
          selectedImage: UIImage(systemName: item["selectedSymbol"] as? String ?? item["symbol"] as? String ?? "circle")
        )
        tabItem.tag = index
        tabItem.isEnabled = item["enabled"] as? Bool ?? true
        return tabItem
      }, animated: false)
    }

    let selected = (args["selected"] as? NSNumber)?.intValue ?? 0
    if let item = tabBar.items?.first(where: { $0.tag == selected }), tabBar.selectedItem !== item {
      tabBar.selectedItem = item
    }

    let shouldShow = args["visible"] as? Bool ?? true
    if shouldShow != visible {
      visible = shouldShow
      if shouldShow { tabBar.isHidden = false }
      UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        tabBar.alpha = shouldShow ? 1 : 0
      } completion: { _ in
        if !self.visible { tabBar.isHidden = true }
      }
    }

    tabBar.superview?.layoutIfNeeded()
    return Double(tabBar.frame.height - (tabBar.superview?.safeAreaInsets.bottom ?? 0))
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    channel.invokeMethod("tabBar.selected", arguments: item.tag)
  }

  private func ensureTabBar() -> UITabBar? {
    if let tabBar { return tabBar }
    guard let host = Self.rootViewController()?.view else { return nil }
    let tabBar = UITabBar()
    tabBar.delegate = self
    tabBar.alpha = 0
    tabBar.isHidden = true
    tabBar.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(tabBar)
    NSLayoutConstraint.activate([
      tabBar.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: host.trailingAnchor),
      tabBar.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    self.tabBar = tabBar
    return tabBar
  }

  private static func rootViewController() -> UIViewController? {
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?
      .rootViewController
  }
}
