import Flutter
import UIKit

/// Fork feature: native Liquid Glass components for the Flutter UI (iOS 26+), see FORK.md.
///
/// - `immich/glass_surface`: a glass material platform view drawn behind Flutter content (sheets, button groups).
/// - `immich/liquid_glass` channel: drives a native UITabBar laid over the Flutter view.
/// - `immich/liquid_glass_menu` channel: presents native UIMenus for Flutter menu triggers.
final class LiquidGlassPlugin: NSObject {
  private static var tabBar: NativeTabBar?
  private static var menu: NativeMenuPresenter?

  static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    registrar.register(GlassSurfaceFactory(), withId: "immich/glass_surface")

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

    let menuChannel = FlutterMethodChannel(name: "immich/liquid_glass_menu", binaryMessenger: messenger)
    let menu = NativeMenuPresenter(channel: menuChannel)
    Self.menu = menu
    menuChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "menu.show":
        result(menu.show(call.arguments as? [String: Any] ?? [:]))
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

/// A view that never takes part in hit testing, and stops Flutter's touch-intercepting wrapper around it from doing
/// so too. Glass surfaces are pure decoration under Flutter content; if their wrappers intercepted touches, taps on
/// the Flutter buttons drawn on top could get stuck, e.g. next to the video player's platform view.
private final class TouchTransparentView: UIView {
  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    superview?.isUserInteractionEnabled = false
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

/// Creation params: `radius` (points, negative for a capsule), `topOnly` (round only the top corners), `clear` (no
/// material at all, only a layer break for Flutter content drawn on top).
private final class GlassSurfaceView: NSObject, FlutterPlatformView {
  private let container = TouchTransparentView()
  private let effectView: UIVisualEffectView

  init(frame: CGRect, params: [String: Any]) {
    if #available(iOS 26.0, *) {
      effectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    } else {
      effectView = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }
    container.frame = frame
    effectView.frame = container.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.isUserInteractionEnabled = false
    super.init()
    if params["clear"] as? Bool == true { return }
    container.addSubview(effectView)

    let radius = (params["radius"] as? NSNumber)?.doubleValue ?? 0
    let topOnly = params["topOnly"] as? Bool == true
    if #available(iOS 26.0, *) {
      if radius < 0 {
        effectView.cornerConfiguration = .capsule()
      } else if topOnly {
        effectView.cornerConfiguration = .corners(
          topLeftRadius: .fixed(radius),
          topRightRadius: .fixed(radius),
          bottomLeftRadius: .fixed(0),
          bottomRightRadius: .fixed(0)
        )
      } else {
        effectView.cornerConfiguration = .uniformCorners(radius: .fixed(radius))
      }
    } else {
      effectView.layer.cornerRadius = radius
      effectView.layer.cornerCurve = .continuous
      effectView.clipsToBounds = true
      if topOnly {
        effectView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
      }
    }
  }

  func view() -> UIView { container }
}

// MARK: - Native menu

/// Presents a native UIMenu at a rect of the Flutter view (`menu.show` → {x, y, width, height, items}), reporting a
/// pick through `menu.select`. It uses a hidden UIKit button outside Flutter's view tree: a platform view in Flutter's
/// touch path can deadlock all touches when it shares the screen with other platform views, such as the video player.
/// Items: {id, title, image?, destructive, disabled}, {divider: true} or {header: title}.
private final class NativeMenuPresenter: NSObject {
  /// Reports when its menu closes, with or without a pick.
  private final class MenuButton: UIButton {
    var onMenuEnd: (() -> Void)?

    override func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      willEndFor configuration: UIContextMenuConfiguration,
      animator: (any UIContextMenuInteractionAnimating)?
    ) {
      super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
      if let animator {
        animator.addCompletion { [weak self] in self?.onMenuEnd?() }
      } else {
        onMenuEnd?()
      }
    }
  }

  private let channel: FlutterMethodChannel
  private var button: MenuButton?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  func show(_ args: [String: Any]) -> Bool {
    guard #available(iOS 17.4, *), let host = rootViewController()?.view else { return false }
    let button = self.button ?? {
      let button = MenuButton(type: .custom)
      button.isUserInteractionEnabled = false
      button.showsMenuAsPrimaryAction = true
      button.preferredMenuElementOrder = .fixed
      button.onMenuEnd = { [weak host] in
        // Presenting a menu cancels every gesture recognizer in the window, and the recognizers Flutter puts around
        // platform views (e.g. the video player) don't recover from that: all touches would stop reaching Flutter.
        DispatchQueue.main.async { if let host { Self.resetTouchInterceptors(in: host) } }
      }
      host.addSubview(button)
      self.button = button
      return button
    }()
    func value(_ key: String) -> CGFloat { CGFloat((args[key] as? NSNumber)?.doubleValue ?? 0) }
    button.frame = CGRect(x: value("x"), y: value("y"), width: value("width"), height: value("height"))
    button.menu = UIMenu(children: elements(from: args["items"] as? [[String: Any]] ?? []))
    button.performPrimaryAction()
    return true
  }

  /// Resets the gesture recognizers of Flutter's platform view touch interceptors by toggling them.
  private static func resetTouchInterceptors(in view: UIView) {
    if String(describing: type(of: view)).contains("TouchInterceptingView") {
      for recognizer in view.gestureRecognizers ?? [] {
        recognizer.isEnabled = false
        recognizer.isEnabled = true
      }
    }
    view.subviews.forEach(resetTouchInterceptors)
  }

  private func elements(from items: [[String: Any]]) -> [UIMenuElement] {
    var sections: [(title: String, elements: [UIMenuElement])] = [("", [])]
    for item in items {
      if item["divider"] as? Bool == true {
        sections.append(("", []))
        continue
      }
      if let header = item["header"] as? String {
        if sections[sections.count - 1].elements.isEmpty {
          sections[sections.count - 1].title = header
        } else {
          sections.append((header, []))
        }
        continue
      }
      let id = (item["id"] as? NSNumber)?.intValue ?? 0
      let image = (item["image"] as? FlutterStandardTypedData)
        .flatMap { UIImage(data: $0.data, scale: 3) }?
        .withRenderingMode(.alwaysTemplate)
      let action = UIAction(title: item["title"] as? String ?? "", image: image) { [weak self] _ in
        self?.channel.invokeMethod("menu.select", arguments: id)
      }
      if item["destructive"] as? Bool == true { action.attributes.insert(.destructive) }
      if item["disabled"] as? Bool == true { action.attributes.insert(.disabled) }
      sections[sections.count - 1].elements.append(action)
    }
    let nonEmpty = sections.filter { !$0.elements.isEmpty }
    if nonEmpty.count == 1, nonEmpty[0].title.isEmpty { return nonEmpty[0].elements }
    return nonEmpty.map { UIMenu(title: $0.title, options: .displayInline, children: $0.elements) }
  }
}

private func rootViewController() -> UIViewController? {
  UIApplication.shared.connectedScenes
    .compactMap { $0 as? UIWindowScene }
    .flatMap(\.windows)
    .first(where: \.isKeyWindow)?
    .rootViewController
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
    // In the window rather than the Flutter view: Flutter adds platform views to its view as they are created, which
    // would stack them above the bar.
    guard let host = rootViewController()?.view?.window else { return nil }
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
}
