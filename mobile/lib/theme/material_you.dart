import 'dart:io';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/config/theme_config.dart';
import 'package:immich_mobile/theme/dynamic_theme.dart';
import 'package:immich_mobile/theme/theme_data.dart';

// Fork feature: Material You theming (experimental setting, Android).
//
// Uses the device's wallpaper color with the tonal spot variant, the one Android itself uses for Material You,
// instead of the fidelity variant of the upstream "dynamic theme" option.

ImmichTheme? _theme;
Color? _seed;

/// The Material You theme when it is enabled and the device provides a palette, otherwise null.
ImmichTheme? materialYouTheme(ThemeConfig config) {
  final seed = DynamicTheme.theme?.light.primary;
  if (!Platform.isAndroid || !config.materialYou || seed == null) {
    return null;
  }
  if (seed != _seed) {
    _seed = seed;
    _theme = ImmichTheme(
      light: ColorScheme.fromSeed(seedColor: seed, dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot),
      dark: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
        dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
      ),
    );
  }
  return _theme;
}
