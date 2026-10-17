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

// Lets hero and page transitions finish before the HDR rendition is loaded.
const _activationDelay = Duration(milliseconds: 400);

const _candidateExtensions = {'jpg', 'jpeg', 'heic', 'heif', 'hif', 'avif'};

final _log = Logger('HdrImageOverlay');

final hdrDisplaySupportedProvider = FutureProvider<bool>((ref) async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    return false;
  }
  try {
    return await _channel.invokeMethod<bool>('isSupported') ?? false;
  } catch (e, stack) {
    _log.warning('Failed to query HDR support', e, stack);
    return false;
  }
});

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

  final bool isActive;

  const HdrImageOverlay({super.key, required this.asset, required this.controller, required this.isActive});

  @override
  ConsumerState<HdrImageOverlay> createState() => _HdrImageOverlayState();
}

class _HdrImageOverlayState extends ConsumerState<HdrImageOverlay> {
  Timer? _activationTimer;
  bool _activated = false;
  bool _isSdr = false;
  StreamSubscription<PhotoViewControllerValue>? _controllerSub;
  PhotoViewControllerValue? _value;

  // iOS: per-view channel of the embedded platform view.
  MethodChannel? _viewChannel;

  // Android: token of the native layer request, and whether the HDR rendition is drawn and can be revealed.
  int? _token;
  bool _ready = false;
  double _devicePixelRatio = 1.0;

  String get _assetKey => widget.asset.heroTag;

  @override
  void initState() {
    super.initState();
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
      _activated = false;
      _release();
    }
    if (oldWidget.isActive != widget.isActive || oldWidget.asset.heroTag != widget.asset.heroTag) {
      _scheduleActivation();
    }
  }

  @override
  void dispose() {
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
    final token = _token = _HdrLayer.instance.show(source, _photoRect, (isHdr) {
      if (!mounted || _token == null) {
        return;
      }
      if (isHdr) {
        setState(() => _ready = true);
      } else {
        _markSdr();
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
          child: CustomPaint(size: boundaries.outerSize, painter: const _ClearPainter()),
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

/// Clears everything Flutter painted below it, revealing the native HDR layer.
class _ClearPainter extends CustomPainter {
  const _ClearPainter();

  @override
  void paint(Canvas canvas, Size size) => canvas.drawRect(Offset.zero & size, Paint()..blendMode = BlendMode.clear);

  @override
  bool shouldRepaint(_ClearPainter oldDelegate) => false;
}

/// Android's native HDR layer. One photo at a time, identified by a token; its on-screen rect is mirrored
/// after every frame (without scheduling frames of its own).
class _HdrLayer {
  static final instance = _HdrLayer._();

  _HdrLayer._();

  int _nextToken = 0;
  int? _token;
  Rect? Function()? _rectSource;
  Rect? _lastRect;
  bool _frameCallbackAdded = false;

  int show(Map<String, Object> source, Rect? Function() rectSource, void Function(bool isHdr) onResult) {
    final token = _token = ++_nextToken;
    _rectSource = rectSource;
    _lastRect = null;
    if (!_frameCallbackAdded) {
      _frameCallbackAdded = true;
      SchedulerBinding.instance.addPersistentFrameCallback((_) => _syncRect());
    }

    unawaited(
      _channel
          .invokeMapMethod<String, Object?>('show', {...source, 'token': token})
          .then((result) {
            if (result?['error'] != null) {
              _log.fine('HDR load failed: ${result!['error']}');
            }
            onResult(result?['hdr'] == true);
          })
          .catchError((Object e, StackTrace stack) {
            _log.warning('HDR show failed', e, stack);
            onResult(false);
          }),
    );
    _syncRect();
    return token;
  }

  void hide(int token) {
    if (_token != token) {
      return;
    }
    _token = null;
    _rectSource = null;
    unawaited(_channel.invokeMethod<void>('hide', {'token': token}).catchError((Object _) {}));
  }

  void _syncRect() {
    final token = _token;
    final rect = _rectSource?.call();
    if (token == null || rect == null || rect == _lastRect) {
      return;
    }
    _lastRect = rect;
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
