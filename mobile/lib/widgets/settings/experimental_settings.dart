import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/hdr_image_overlay.widget.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_ui/immich_ui.dart';

/// Fork feature: experimental settings (see FORK.md).
///
/// Strings are hard-coded to keep the upstream i18n files untouched.
class ExperimentalSettings extends StatelessWidget {
  const ExperimentalSettings({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsSubPageScaffold(
      settings: [
        const _ToggleSetting(
          setting: .imageHdr,
          title: 'Display HDR photos',
          subtitle:
              'Show Ultra HDR and other gain map photos with their full brightness range on supported displays. '
              'Downloads the original file of remote photos. On Android, changes apply after restarting the app.',
          onChanged: setHdrEnabled,
        ),
        if (Platform.isAndroid) ...const [
          _ToggleSetting(
            setting: .themeMaterialYou,
            title: 'Material You theming',
            subtitle:
                "Use your device's Material You colors, including its color style such as monochrome. Replaces the "
                'primary color setting.',
          ),
          _ToggleSetting(
            setting: .themeFloatingTabBar,
            title: 'Floating tab bar',
            subtitle: 'Use a floating navigation bar that photos scroll underneath, with a separate search button.',
          ),
        ],
      ],
      showDivider: true,
    );
  }
}

class _ToggleSetting extends HookConsumerWidget {
  final SettingsKey<bool> setting;
  final String title;
  final String subtitle;
  final Future<void> Function(bool value)? onChanged;

  const _ToggleSetting({required this.setting, required this.title, required this.subtitle, this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = useState(ref.watch(appConfigProvider).read(setting));
    useValueChanged<bool, void>(value.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(setting, value.value));
      if (onChanged != null) {
        unawaited(onChanged!(value.value));
      }
    });

    return SettingsSwitchListTile(valueNotifier: value, title: title, subtitle: subtitle);
  }
}
