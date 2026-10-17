import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/config/theme_config.dart';
import 'package:immich_mobile/theme/theme_data.dart';
import 'package:logging/logging.dart';

// Fork feature: Material You theming (experimental setting, Android).
//
// Uses the device's own Material You scheme, exactly as Android computes it from the wallpaper and the chosen style
// (tonal spot, monochrome, …). Read by android/.../theme/MaterialYouPlugin.kt. When enabled, it replaces the upstream
// "system color" and preset color options.

const _channel = MethodChannel('immich/material_you');
final _log = Logger('MaterialYou');

ImmichTheme? _theme;

/// Whether the device provides a Material You scheme.
bool get materialYouAvailable => _theme != null;

/// Reads the device's Material You scheme; called once at startup.
Future<void> fetchMaterialYouScheme() async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    final scheme = await _channel.invokeMapMethod<String, Object?>('scheme');
    final light = (scheme?['light'] as Map?)?.cast<String, int>();
    final dark = (scheme?['dark'] as Map?)?.cast<String, int>();
    if (light == null || dark == null) {
      return;
    }
    _theme = ImmichTheme(light: _colorScheme(light, Brightness.light), dark: _colorScheme(dark, Brightness.dark));
  } catch (e, stack) {
    _log.warning('Failed to read the Material You scheme', e, stack);
  }
}

/// The Material You theme when it is enabled and the device provides one, otherwise null.
ImmichTheme? materialYouTheme(ThemeConfig config) => config.materialYou ? _theme : null;

ColorScheme _colorScheme(Map<String, int> roles, Brightness brightness) {
  Color? role(String name) => roles[name] == null ? null : Color(roles[name]!);
  // Roles the device doesn't report (fixed colors, inverse colors, …) come from a scheme with the same primary.
  final base = ColorScheme.fromSeed(
    seedColor: role('primary') ?? Colors.grey,
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
  );
  return base.copyWith(
    primary: role('primary'),
    onPrimary: role('onPrimary'),
    primaryContainer: role('primaryContainer'),
    onPrimaryContainer: role('onPrimaryContainer'),
    secondary: role('secondary'),
    onSecondary: role('onSecondary'),
    secondaryContainer: role('secondaryContainer'),
    onSecondaryContainer: role('onSecondaryContainer'),
    tertiary: role('tertiary'),
    onTertiary: role('onTertiary'),
    tertiaryContainer: role('tertiaryContainer'),
    onTertiaryContainer: role('onTertiaryContainer'),
    error: role('error'),
    onError: role('onError'),
    errorContainer: role('errorContainer'),
    onErrorContainer: role('onErrorContainer'),
    surface: role('surface'),
    onSurface: role('onSurface'),
    onSurfaceVariant: role('onSurfaceVariant'),
    surfaceDim: role('surfaceDim'),
    surfaceBright: role('surfaceBright'),
    surfaceContainerLowest: role('surfaceContainerLowest'),
    surfaceContainerLow: role('surfaceContainerLow'),
    surfaceContainer: role('surfaceContainer'),
    surfaceContainerHigh: role('surfaceContainerHigh'),
    surfaceContainerHighest: role('surfaceContainerHighest') ?? role('surfaceVariant'),
    outline: role('outline'),
    outlineVariant: role('outlineVariant'),
  );
}
