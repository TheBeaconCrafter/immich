import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_ui/immich_ui.dart';

// Strings are hard-coded to keep the upstream i18n files untouched.
class ImageViewerHdrSetting extends HookConsumerWidget {
  const ImageViewerHdrSetting({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hdr = useState(ref.watch(appConfigProvider).image.hdr);
    useValueChanged<bool, void>(hdr.value, (_, _) {
      unawaited(ref.read(settingsProvider).write(.imageHdr, hdr.value));
    });

    return SettingsSwitchListTile(
      valueNotifier: hdr,
      title: 'Display HDR photos',
      subtitle:
          'Show Ultra HDR and other gain map photos with their full brightness range on supported displays. Downloads the original file of remote photos.',
    );
  }
}
