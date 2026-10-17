import 'dart:async';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:immich_mobile/widgets/photo_view/src/utils/photo_view_utils.dart';
import 'package:logging/logging.dart';

const _viewType = 'immich/hdr_image_view';
const _channel = MethodChannel('immich/hdr_image');

const _maxDecodeSize = 4096;

// Crossfade from the SDR image to an HDR rendition that had to be loaded first; cached ones appear instantly.
const _revealDuration = Duration(milliseconds: 180);

// iOS: lets hero and page transitions finish before the native view is created.
const _activationDelay = Duration(milliseconds: 400);

const _candidateExtensions = {'jpg', 'jpeg', 'heic', 'heif', 'hif', 'avif'};

final _log = Logger('HdrImageOverlay');

bool _supported = false;

final hdrDisplaySupportedProvider = FutureProvider<bool>((ref) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    return false;
  }
  try {
    return _supported = await _channel.invokeMethod<bool>('isSupported') ?? false;
  } catch (e, stack) {
    _log.warning('Failed to query HDR support', e, stack);
    return false;
  }
});

/// Decodes the HDR rendition of [asset] in the background, so swiping to it shows HDR right away (Android).
void preloadHdrRendition(BaseAsset? asset) {
  if (asset == null || !Platform.isAndroid || !_supported || !SettingsRepository.instance.appConfig.image.hdr) {
    return;
  }
  final source = _hdrSource(asset);
  if (source == null || _knownSdr.contains(asset.heroTag)) {
    return;
  }
  unawaited(_channel.invokeMethod<void>('preload', source).catchError((Object _) {}));
}

/// Android only applies this on the next app start, as it decides how Flutter's surface is composited.
Future<void> setHdrEnabled(bool enabled) async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    await _channel.invokeMethod<void>('setEnabled', enabled);
  } catch (e, stack) {
    _log.warning('Failed to store HDR preference', e, stack);
  }
}

final _knownSdr = <String>{};
const _knownSdrLimit = 2000;

void _rememberSdr(String key) {
  _knownSdr.add(key);
  if (_knownSdr.length > _knownSdrLimit) {
    _knownSdr.remove(_knownSdr.first);
  }
}

Map<String, Object>? _hdrSource(BaseAsset asset) {
  if (!asset.isImage || asset.isAnimatedImage) {
    return null;
  }
  final dot = asset.name.lastIndexOf('.');
  final extension = dot < 0 ? '' : asset.name.substring(dot + 1).toLowerCase();
  if (!_candidateExtensions.contains(extension)) {
    return null;
  }

  // Mirrors _shouldUseLocalAsset in images/image_provider.dart.
  final useLocal =
      asset.hasLocal &&
      (!asset.hasRemote || !SettingsRepository.instance.appConfig.image.preferRemote) &&
      !asset.isEdited;
  final localId = asset.localId;
  if (useLocal && localId != null) {
    return {'localId': localId, 'maxSize': _maxDecodeSize};
  }

  final remoteId = asset is RemoteAsset ? asset.id : (asset as LocalAsset).remoteId;
  if (remoteId == null) {
    return null;
  }
  return {'url': getOriginalUrlForRemoteId(remoteId), 'maxSize': _maxDecodeSize};
}

/// Shows the HDR rendition of [asset] in place of the SDR image of the PhotoView driven by [controller].
///
/// Android draws it in a native layer below the (transparent) Flutter surface and this widget clears the
/// photo area, while iOS embeds a native view directly.
class HdrImageOverlay extends ConsumerStatefulWidget {
  final BaseAsset asset;
  final PhotoViewControllerBase? controller;

  /// iOS only embeds a native view for the page in view; Android shows every visible page in HDR.
  final bool isActive;

  const HdrImageOverlay({super.key, required this.asset, required this.controller, required this.isActive});

  @override
  ConsumerState<HdrImageOverlay> createState() => _HdrImageOverlayState();
}

class _HdrImageOverlayState extends ConsumerState<HdrImageOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _reveal;
  Timer? _activationTimer;
  bool _activated = false;
  bool _isSdr = false;
  StreamSubscription<PhotoViewControllerValue>? _controllerSub;
  PhotoViewControllerValue? _value;

  // iOS: per-view channel of the embedded platform view.
  MethodChannel? _viewChannel;

  // Android: activation follows the route animation; the token identifies this page's native layer slot, and
  // _ready says its HDR rendition is drawn and can be revealed.
  Animation<double>? _routeAnimation;
  int? _token;
  bool _ready = false;
  double _devicePixelRatio = 1.0;

  String get _assetKey => widget.asset.heroTag;

  @override
  void initState() {
    super.initState();
    _reveal = AnimationController(vsync: this, duration: _revealDuration);
    _attachController();
    _scheduleActivation();
  }

  @override
  void didUpdateWidget(HdrImageOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _attachController();
    }
    if (oldWidget.asset.heroTag != widget.asset.heroTag) {
      _isSdr = false;
      if (!Platform.isAndroid) {
        _activated = false;
      }
      _release();
    }
    if (oldWidget.isActive != widget.isActive || oldWidget.asset.heroTag != widget.asset.heroTag) {
      _scheduleActivation();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!Platform.isAndroid) {
      return;
    }
    final animation = ModalRoute.of(context)?.animation;
    if (animation != _routeAnimation) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = animation?..addStatusListener(_onRouteStatus);
      _activated = (animation?.status ?? AnimationStatus.completed) == AnimationStatus.completed;
    }
  }

  /// Android pages show HDR once the viewer finished opening (the hero flight) and until it starts closing.
  void _onRouteStatus(AnimationStatus status) {
    final active = status == AnimationStatus.completed;
    if (active == _activated || !mounted) {
      return;
    }
    setState(() => _activated = active);
    if (!active) {
      _release();
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _activationTimer?.cancel();
    unawaited(_controllerSub?.cancel());
    _release();
    super.dispose();
  }

  void _attachController() {
    unawaited(_controllerSub?.cancel());
    final controller = widget.controller;
    _value = controller?.value;
    _controllerSub = controller?.outputStateStream.listen((value) {
      if (mounted) {
        setState(() => _value = value);
      }
    });
  }

  void _scheduleActivation() {
    if (Platform.isAndroid) {
      return;
    }
    _activationTimer?.cancel();
    if (!widget.isActive) {
      if (_activated) {
        setState(() => _activated = false);
        _release();
      }
      return;
    }
    if (_activated) {
      return;
    }
    _activationTimer = Timer(_activationDelay, () {
      if (mounted && widget.isActive) {
        setState(() => _activated = true);
      }
    });
  }

  void _release() {
    _viewChannel?.setMethodCallHandler(null);
    _viewChannel = null;

    final token = _token;
    _token = null;
    _ready = false;
    if (token != null && token >= 0) {
      _HdrLayer.instance.hide(token);
    }
  }

  void _markSdr() {
    _rememberSdr(_assetKey);
    if (mounted) {
      setState(() => _isSdr = true);
    }
    _release();
  }

  /// The photo's rect in physical pixels relative to the Flutter view, or null if it is not laid out.
  Rect? _photoRect() {
    final boundaries = widget.controller?.scaleBoundaries;
    final value = widget.controller?.value;
    final box = context.findRenderObject();
    if (boundaries == null || value == null || value.scale == null || box is! RenderBox || !box.hasSize) {
      return null;
    }
    final size = boundaries.childSize * value.scale!;
    final center = boundaries.outerSize.center(Offset.zero) + value.position;
    final origin = box.localToGlobal(center - size.center(Offset.zero));
    final dpr = _devicePixelRatio;
    return Rect.fromLTWH(origin.dx * dpr, origin.dy * dpr, size.width * dpr, size.height * dpr);
  }

  void _showOnNativeLayer(Map<String, Object> source) {
    final token = _token = _HdrLayer.instance.show(source, _photoRect, (isHdr, cached) {
      if (!mounted || _token == null) {
        return;
      }
      if (!isHdr) {
        _markSdr();
        return;
      }
      _reveal.value = cached ? 1.0 : 0.0;
      setState(() => _ready = true);
      if (!cached) {
        unawaited(_reveal.forward());
      }
    });
    _log.fine('Requested HDR rendition $token for ${widget.asset.name}');
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(appConfigProvider.select((c) => c.image.hdr));
    final supported = ref.watch(hdrDisplaySupportedProvider).valueOrNull ?? false;
    // The page fades out while being dismissed; the SDR image has to take over for that.
    final dismissing = ref.watch(assetViewerProvider.select((s) => s.backgroundOpacity < 1.0));
    final boundaries = widget.controller?.scaleBoundaries;
    final value = _value;
    final source = _hdrSource(widget.asset);
    _devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
    if (!enabled ||
        !supported ||
        !_activated ||
        _isSdr ||
        _knownSdr.contains(_assetKey) ||
        source == null ||
        boundaries == null ||
        value == null ||
        value.scale == null) {
      return const SizedBox.shrink();
    }

    if (Platform.isAndroid) {
      if (_token == null) {
        _token = -1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _token == -1) {
            _showOnNativeLayer(source);
          }
        });
      }
      if (!_ready || dismissing) {
        return const SizedBox.shrink();
      }
      return IgnorePointer(
        child: Align(
          alignment: Alignment.topLeft,
          child: CustomPaint(size: boundaries.outerSize, painter: _RevealPainter(_reveal)),
        ),
      );
    }

    return _buildUiKitView(source, boundaries, value);
  }

  Widget _buildUiKitView(Map<String, Object> source, ScaleBoundaries boundaries, PhotoViewControllerValue value) {
    // Mirrors PhotoViewCore's geometry. The native view keeps its initial size and is only transformed,
    // so zooming never triggers a native relayout.
    final outer = boundaries.outerSize;
    final baseSize = boundaries.childSize * boundaries.initialScale;
    final relativeScale = value.scale! / boundaries.initialScale;
    final transform = Matrix4.identity()
      ..translateByDouble(
        (outer.width - baseSize.width) / 2 + value.position.dx,
        (outer.height - baseSize.height) / 2 + value.position.dy,
        0,
        1,
      )
      ..translateByDouble(baseSize.width / 2, baseSize.height / 2, 0, 1)
      ..scaleByDouble(relativeScale, relativeScale, 1, 1)
      ..rotateZ(value.rotation)
      ..translateByDouble(-baseSize.width / 2, -baseSize.height / 2, 0, 1);

    return IgnorePointer(
      child: SizedBox.fromSize(
        size: outer,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              top: 0,
              width: baseSize.width,
              height: baseSize.height,
              child: Transform(
                transform: transform,
                child: UiKitView(
                  key: ValueKey(_assetKey),
                  viewType: _viewType,
                  creationParams: source,
                  creationParamsCodec: const StandardMessageCodec(),
                  hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                  onPlatformViewCreated: _onPlatformViewCreated,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _onPlatformViewCreated(int id) {
    final channel = _viewChannel = MethodChannel('${_viewType}_$id');
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onResult') {
        _onViewResult(channel, call.arguments as Map?);
      }
    });
    // The result may have been pushed before the handler above was registered.
    unawaited(
      channel
          .invokeMapMethod<String, Object?>('getResult')
          .then((result) => _onViewResult(channel, result))
          .catchError((Object e) => _log.fine('getResult failed', e)),
    );
  }

  void _onViewResult(MethodChannel channel, Map? result) {
    if (result == null || !mounted || _viewChannel != channel) {
      return;
    }
    if (result['error'] != null) {
      _log.fine('HDR load failed for ${widget.asset.name}: ${result['error']}');
    }
    if (result['hdr'] != true) {
      _markSdr();
    }
  }
}

/// Makes everything Flutter painted below it transparent by [progress], revealing the native HDR layer.
class _RevealPainter extends CustomPainter {
  final Animation<double> progress;

  _RevealPainter(this.progress) : super(repaint: progress);

  @override
  void paint(Canvas canvas, Size size) {
    // dstOut scales the destination's alpha by (1 - source alpha); at 1.0 it equals BlendMode.clear.
    final paint = Paint()
      ..color = Color.fromRGBO(0, 0, 0, progress.value)
      ..blendMode = BlendMode.dstOut;
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_RevealPainter oldDelegate) => oldDelegate.progress != progress;
}

/// Android's native HDR layer. Each visible page owns a slot identified by a token; slot rects are mirrored
/// after every frame (without scheduling frames of their own).
class _HdrLayer {
  static final instance = _HdrLayer._();

  _HdrLayer._();

  int _nextToken = 0;
  final _slots = <int, _Slot>{};
  bool _frameCallbackAdded = false;

  int show(Map<String, Object> source, Rect? Function() rectSource, void Function(bool isHdr, bool cached) onResult) {
    final token = ++_nextToken;
    final slot = _slots[token] = _Slot(rectSource);
    if (!_frameCallbackAdded) {
      _frameCallbackAdded = true;
      SchedulerBinding.instance.addPersistentFrameCallback((_) => _syncRects());
    }

    unawaited(
      _channel
          .invokeMapMethod<String, Object?>('show', {...source, 'token': token})
          .then((result) {
            if (result?['error'] != null) {
              _log.fine('HDR load failed: ${result!['error']}');
            }
            onResult(result?['hdr'] == true, result?['cached'] == true);
          })
          .catchError((Object e, StackTrace stack) {
            _log.warning('HDR show failed', e, stack);
            onResult(false, false);
          }),
    );
    _syncRect(token, slot);
    return token;
  }

  void hide(int token) {
    if (_slots.remove(token) == null) {
      return;
    }
    unawaited(_channel.invokeMethod<void>('hide', {'token': token}).catchError((Object _) {}));
  }

  void _syncRects() {
    for (final MapEntry(key: token, value: slot) in _slots.entries) {
      _syncRect(token, slot);
    }
  }

  void _syncRect(int token, _Slot slot) {
    final rect = slot.rectSource();
    if (rect == null || rect == slot.lastRect) {
      return;
    }
    slot.lastRect = rect;
    unawaited(
      _channel
          .invokeMethod<void>('update', {
            'token': token,
            'left': rect.left,
            'top': rect.top,
            'width': rect.width,
            'height': rect.height,
          })
          .catchError((Object _) {}),
    );
  }
}

class _Slot {
  final Rect? Function() rectSource;
  Rect? lastRect;

  _Slot(this.rectSource);
}
