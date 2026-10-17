import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PredictiveBackEvent, SwipeEdge;
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';

// Fork feature: Android predictive back (experimental setting, Android only; see FORK.md).
//
// The manifest opts into the system's predictive back gestures. With the setting on, pages also follow the gesture
// with Android's predictive back transition; iOS keeps its own transitions either way.

/// Page transitions for the app theme, or null for Flutter's defaults.
PageTransitionsTheme? predictiveBackTransitions() {
  if (!Platform.isAndroid || !SettingsRepository.instance.appConfig.theme.predictiveBack) {
    return null;
  }
  return const PageTransitionsTheme(
    builders: {
      TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    },
  );
}

/// Lets a route without a predictive back page transition (the photo viewer, dialogs) follow Android's back
/// gesture: the route's own transition runs backwards with the finger, and [child] shrinks slightly towards the edge
/// the gesture started from. Does nothing on iOS or with the setting off.
class PredictiveBackGesture extends StatefulWidget {
  final Widget child;

  const PredictiveBackGesture({super.key, required this.child});

  @override
  State<PredictiveBackGesture> createState() => _PredictiveBackGestureState();
}

class _PredictiveBackGestureState extends State<PredictiveBackGesture> with WidgetsBindingObserver {
  double _progress = 0;
  SwipeEdge _edge = SwipeEdge.left;
  bool _active = false;

  TransitionRoute<dynamic>? get _route {
    final route = ModalRoute.of(context);
    return route is TransitionRoute ? route : null;
  }

  bool get _enabled {
    final route = _route;
    return Platform.isAndroid &&
        SettingsRepository.instance.appConfig.theme.predictiveBack &&
        route != null &&
        route.isCurrent &&
        route.popGestureEnabled;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent backEvent) {
    if (backEvent.isButtonEvent || !_enabled) {
      return false;
    }
    _route!.handleStartBackGesture(progress: 1 - backEvent.progress);
    setState(() {
      _active = true;
      _edge = backEvent.swipeEdge;
      _progress = backEvent.progress;
    });
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent backEvent) {
    if (!_active) {
      return;
    }
    _route?.handleUpdateBackGestureProgress(progress: 1 - backEvent.progress);
    setState(() => _progress = backEvent.progress);
  }

  @override
  void handleCancelBackGesture() {
    if (!_active) {
      return;
    }
    _route?.handleCancelBackGesture();
    setState(() {
      _active = false;
      _progress = 0;
    });
  }

  @override
  void handleCommitBackGesture() {
    if (!_active) {
      return;
    }
    _route?.handleCommitBackGesture();
    setState(() => _active = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_active && _progress == 0) {
      return widget.child;
    }
    final eased = Curves.easeOut.transform(_progress.clamp(0.0, 1.0));
    final direction = _edge == SwipeEdge.left ? 1.0 : -1.0;
    return Transform.translate(
      offset: Offset(direction * 24 * eased, 0),
      child: Transform.scale(scale: 1 - 0.1 * eased, child: widget.child),
    );
  }
}
