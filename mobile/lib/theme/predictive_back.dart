import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
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
