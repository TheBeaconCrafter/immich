import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:logging/logging.dart';

const _viewType = 'immich/hdr_image_view';
const _channel = MethodChannel('immich/hdr_image');

const _maxDecodeSize = 4096;

// Lets hero and page transitions finish before the native view is created.
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

/// Draws the HDR rendition of [asset] on top of the SDR image shown by the PhotoView driven by [controller].
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
  MethodChannel? _viewChannel;

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
      _disposeChannel();
    }
    if (oldWidget.isActive != widget.isActive || oldWidget.asset.heroTag != widget.asset.heroTag) {
      _scheduleActivation();
    }
  }

  @override
  void dispose() {
    _activationTimer?.cancel();
    unawaited(_controllerSub?.cancel());
    _disposeChannel();
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
        _disposeChannel();
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

  void _disposeChannel() {
    _viewChannel?.setMethodCallHandler(null);
    _viewChannel = null;
  }

  void _onPlatformViewCreated(int id) {
    final channel = _viewChannel = MethodChannel('${_viewType}_$id');
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onResult') {
        _onResult(channel, call.arguments as Map?);
      }
    });
    // The result may have been pushed before the handler above was registered.
    unawaited(
      channel
          .invokeMapMethod<String, Object?>('getResult')
          .then((result) => _onResult(channel, result))
          .catchError((Object e) => _log.fine('getResult failed', e)),
    );
  }

  void _onResult(MethodChannel channel, Map? result) {
    if (result == null || !mounted || _viewChannel != channel) {
      return;
    }
    if (result['error'] != null) {
      _log.fine('HDR load failed for ${widget.asset.name}: ${result['error']}');
    }
    if (result['hdr'] != true) {
      _rememberSdr(_assetKey);
      setState(() => _isSdr = true);
      _disposeChannel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = ref.watch(appConfigProvider.select((c) => c.image.hdr));
    final supported = ref.watch(hdrDisplaySupportedProvider).valueOrNull ?? false;
    final boundaries = widget.controller?.scaleBoundaries;
    final value = _value;
    if (!enabled ||
        !supported ||
        !_activated ||
        _isSdr ||
        _knownSdr.contains(_assetKey) ||
        boundaries == null ||
        value == null ||
        value.scale == null) {
      return const SizedBox.shrink();
    }

    final source = _hdrSource(widget.asset);
    if (source == null) {
      return const SizedBox.shrink();
    }

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
                child: _NativeHdrView(
                  key: ValueKey(_assetKey),
                  creationParams: source,
                  onCreated: _onPlatformViewCreated,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NativeHdrView extends StatelessWidget {
  final Map<String, Object> creationParams;
  final void Function(int id) onCreated;

  const _NativeHdrView({super.key, required this.creationParams, required this.onCreated});

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return UiKitView(
        viewType: _viewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        onPlatformViewCreated: onCreated,
      );
    }

    // Hybrid composition keeps the view in the window hierarchy so it inherits the HDR color mode;
    // texture composition would flatten it to 8-bit SDR.
    return PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
      ),
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
        );
        controller
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..addOnPlatformViewCreatedListener(onCreated);
        unawaited(controller.create());
        return controller;
      },
    );
  }
}
