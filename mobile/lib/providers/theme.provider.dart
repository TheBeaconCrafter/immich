import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/theme/color_scheme.dart';
import 'package:immich_mobile/theme/dynamic_theme.dart';
import 'package:immich_mobile/theme/material_you.dart';
import 'package:immich_mobile/theme/theme_data.dart';

// Provider for current selected theme
final immichThemeProvider = StateProvider<ImmichTheme>((ref) {
  final themeConfig = ref.watch(appConfigProvider.select((config) => config.theme));

  final ImmichTheme? dynamicTheme = DynamicTheme.theme;
  final currentTheme =
      materialYouTheme(themeConfig) ?? // fork: experimental Material You theming
      ((themeConfig.dynamicTheme && dynamicTheme != null) ? dynamicTheme : themeConfig.primaryColor.themeOfPreset);

  return themeConfig.colorfulInterface ? currentTheme : decolorizeSurfaces(theme: currentTheme);
});
