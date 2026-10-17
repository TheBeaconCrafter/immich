import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

// Fork feature: native Liquid Glass tab bar on iOS 26+ (see FORK.md). The UITabBar itself is laid over the Flutter
// view by ios/Runner/Core/LiquidGlass/LiquidGlassPlugin.swift; this widget reserves its space and keeps it in sync.

const _channel = MethodChannel('immich/liquid_glass');
final _log = Logger('NativeTabBar');

/// SF Symbols for the tab shell's destinations, in order.
const _symbols = [
  ('photo.on.rectangle', 'photo.fill.on.rectangle.fill'),
  ('magnifyingglass', 'magnifyingglass'),
  ('rectangle.stack', 'rectangle.stack.fill'),
  ('square.grid.2x2', 'square.grid.2x2.fill'),
];

class NativeTabBar extends StatefulWidget {
  final List<NavigationDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  const NativeTabBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onDestinationSelected,
  });

  @override
  State<NativeTabBar> createState() => _NativeTabBarState();
}

class _NativeTabBarState extends State<NativeTabBar> {
  static _NativeTabBarState? _active;

  /// Height of the native bar above the bottom safe area; 49 is UIKit's standard until it reports its own.
  double _height = 49;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _active = this;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'tabBar.selected') {
        _active?.widget.onDestinationSelected(call.arguments as int);
      }
    });
  }

  @override
  void dispose() {
    if (_active == this) {
      _active = null;
      unawaited(_update(visible: false));
    }
    super.dispose();
  }

  Future<void> _update({required bool visible}) async {
    try {
      final height = await _channel.invokeMethod<double>('tabBar.update', {
        'items': [
          for (final (index, destination) in widget.destinations.indexed)
            {
              'title': destination.label,
              'symbol': _symbols[index % _symbols.length].$1,
              'selectedSymbol': _symbols[index % _symbols.length].$2,
              'enabled': destination.enabled,
            },
        ],
        'selected': widget.selectedIndex,
        'visible': visible,
      });
      if (mounted && height != null && height > 0 && height != _height) {
        setState(() => _height = height);
      }
    } catch (e, stack) {
      _log.warning('Failed to update native tab bar', e, stack);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Hidden whenever another route (viewer, dialog, sheet, page) covers the tab shell.
    _visible = ModalRoute.isCurrentOf(context) ?? true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_update(visible: _visible));
      }
    });

    // Reserves the bar's space; with Scaffold.extendBody the content still scrolls underneath the glass.
    return SizedBox(height: _height + MediaQuery.paddingOf(context).bottom);
  }
}
