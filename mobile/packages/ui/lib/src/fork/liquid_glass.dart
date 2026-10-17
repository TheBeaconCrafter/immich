import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// Fork feature: native Liquid Glass components on iOS 26+ (see FORK.md). Native side: ios/Runner/Core/LiquidGlass/.
// Every widget here falls back to the regular Flutter widget elsewhere, so call sites stay platform independent.

/// Whether native Liquid Glass components are used: iOS 26 or newer.
final bool useLiquidGlass = () {
  if (!Platform.isIOS) {
    return false;
  }
  final major = int.tryParse(RegExp(r'(\d+)').firstMatch(Platform.operatingSystemVersion)?.group(1) ?? '');
  return major != null && major >= 26;
}();

/// Native glass material behind [child]. [radius] < 0 makes a capsule; [topOnly] rounds only the top corners.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final double radius;
  final bool topOnly;

  const GlassSurface({super.key, required this.child, this.radius = -1, this.topOnly = false});

  @override
  Widget build(BuildContext context) {
    if (!useLiquidGlass) {
      return child;
    }
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: UiKitView(
              viewType: 'immich/glass_surface',
              creationParams: {'radius': radius, 'topOnly': topOnly},
              creationParamsCodec: const StandardMessageCodec(),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// [Card] on other platforms, a native glass surface on iOS 26+. Takes the same parameters as the [Card]s it
/// replaces; only the top corner radius of [shape] is used for the glass.
class GlassCard extends StatelessWidget {
  final Color? color;
  final double? elevation;
  final ShapeBorder? shape;
  final EdgeInsetsGeometry? margin;
  final Widget? child;

  const GlassCard({super.key, this.color, this.elevation, this.shape, this.margin, this.child});

  @override
  Widget build(BuildContext context) {
    if (!useLiquidGlass) {
      return Card(color: color, elevation: elevation, shape: shape, margin: margin, child: child);
    }
    final border = shape;
    final radii = border is RoundedRectangleBorder ? border.borderRadius.resolve(TextDirection.ltr) : null;
    final radius = radii?.topLeft.x ?? 12.0;
    final topOnly = radii != null && radii.bottomLeft.x == 0;
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      // iOS sheets and cards are rounder than Material's.
      child: GlassSurface(radius: radius < 28 ? 28 : radius, topOnly: topOnly, child: child ?? const SizedBox()),
    );
  }
}

/// Drop-in for [MenuAnchor]: on iOS 26+ the trigger opens a native glass [UIMenu] whose entries are read from the
/// [MenuItemButton]s that [menuChildren] build (label, icon, enabled state and action).
class NativeMenuAnchor extends StatefulWidget {
  final MenuController? controller;
  final MenuStyle? style;
  final Offset? alignmentOffset;
  final bool consumeOutsideTap;
  final List<Widget> menuChildren;
  final MenuAnchorChildBuilder? builder;
  final Widget? child;

  const NativeMenuAnchor({
    super.key,
    this.controller,
    this.style,
    this.alignmentOffset,
    this.consumeOutsideTap = false,
    required this.menuChildren,
    this.builder,
    this.child,
  });

  @override
  State<NativeMenuAnchor> createState() => _NativeMenuAnchorState();
}

const _menuChannel = MethodChannel('immich/liquid_glass_menu');

/// Opens the native menu instead of Flutter's when the trigger calls [open].
class _NativeMenuController extends MenuController {
  final VoidCallback onOpen;

  _NativeMenuController(this.onOpen);

  @override
  void open({Offset? position}) => onOpen();

  @override
  void close() {}

  @override
  bool get isOpen => false;
}

class _NativeMenuAnchorState extends State<NativeMenuAnchor> {
  static _NativeMenuAnchorState? _shown;
  static bool _handlerSet = false;

  final _anchorKey = GlobalKey();
  final _menuKey = GlobalKey();
  late final _nativeController = _NativeMenuController(_showNative);
  List<VoidCallback?> _actions = const [];

  @override
  void dispose() {
    if (_shown == this) {
      _shown = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!useLiquidGlass) {
      return MenuAnchor(
        controller: widget.controller,
        style: widget.style,
        alignmentOffset: widget.alignmentOffset,
        consumeOutsideTap: widget.consumeOutsideTap,
        menuChildren: widget.menuChildren,
        builder: widget.builder,
        child: widget.child,
      );
    }

    final trigger = widget.builder?.call(context, _nativeController, widget.child) ?? widget.child ?? const SizedBox();
    return Stack(
      children: [
        KeyedSubtree(key: _anchorKey, child: trigger),
        // Built but never painted, so the entries can be read when the native menu opens.
        Offstage(
          child: KeyedSubtree(
            key: _menuKey,
            child: Column(mainAxisSize: MainAxisSize.min, children: widget.menuChildren),
          ),
        ),
      ],
    );
  }

  Future<void> _showNative() async {
    final box = _anchorKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      return;
    }
    if (!_handlerSet) {
      _handlerSet = true;
      _menuChannel.setMethodCallHandler((call) async {
        if (call.method == 'menu.select') {
          _shown?._select(call.arguments as int);
        }
        return null;
      });
    }
    final origin = box.localToGlobal(Offset.zero);
    final items = await _items();
    if (!mounted) {
      return;
    }
    _shown = this;
    await _menuChannel.invokeMethod<bool>('menu.show', {
      'x': origin.dx,
      'y': origin.dy,
      'width': box.size.width,
      'height': box.size.height,
      'items': items,
    });
  }

  void _select(int index) {
    if (index >= 0 && index < _actions.length) {
      _actions[index]?.call();
    }
  }

  Future<List<Map<String, Object?>>> _items() async {
    final entries = <(String, IconData?, VoidCallback?)?>[];
    void visit(Element element) {
      final widget = element.widget;
      if (widget is MenuItemButton) {
        final icon = widget.leadingIcon;
        entries.add((_text(element), icon is Icon ? icon.icon : null, widget.onPressed));
        return;
      }
      if (widget is Divider) {
        entries.add(null);
        return;
      }
      element.visitChildren(visit);
    }

    (_menuKey.currentContext as Element?)?.visitChildren(visit);
    _actions = [for (final entry in entries) entry?.$3];
    return [
      for (final (index, entry) in entries.indexed)
        if (entry == null)
          {'divider': true}
        else
          {
            'id': index,
            'title': entry.$1,
            'image': entry.$2 == null ? null : await _iconPng(entry.$2!),
            'disabled': entry.$3 == null,
          },
    ];
  }

  static String _text(Element element) {
    final parts = <String>[];
    void visit(Element e) {
      final widget = e.widget;
      if (widget is RichText) {
        parts.add(widget.text.toPlainText());
        return;
      }
      e.visitChildren(visit);
    }

    visit(element);
    return parts.where((part) => part.trim().isNotEmpty && part.runes.length > 1).join(' ');
  }

  static final _iconCache = <IconData, Uint8List>{};

  /// Renders a font icon (e.g. a Material icon) to a PNG at 3x, used as a template image by the native menu.
  static Future<Uint8List?> _iconPng(IconData icon) async {
    final cached = _iconCache[icon];
    if (cached != null) {
      return cached;
    }
    const size = 24.0 * 3;
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(fontFamily: icon.fontFamily, package: icon.fontPackage, fontSize: size, color: Colors.black),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final recorder = ui.PictureRecorder();
    painter.paint(Canvas(recorder), Offset((size - painter.width) / 2, (size - painter.height) / 2));
    final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) {
      return null;
    }
    return _iconCache[icon] = bytes.buffer.asUint8List();
  }
}

/// A row of buttons sharing one glass capsule on iOS 26+, like UIKit toolbar groups; a plain [Row] elsewhere.
class GlassGroup extends StatelessWidget {
  final List<Widget> children;

  /// Outer spacing, only applied when the glass is shown.
  final EdgeInsetsGeometry margin;

  const GlassGroup({super.key, required this.children, this.margin = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) {
    final row = Row(mainAxisSize: MainAxisSize.min, children: children);
    if (!useLiquidGlass || children.isEmpty) {
      return row;
    }
    return Padding(
      padding: margin,
      child: GlassSurface(
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: row),
      ),
    );
  }
}

/// A round glass disc of [diameter] centered behind [child] on iOS 26+, e.g. for a single icon button.
class GlassCircle extends StatelessWidget {
  final Widget child;
  final double diameter;

  const GlassCircle({super.key, required this.child, this.diameter = 44});

  @override
  Widget build(BuildContext context) {
    if (!useLiquidGlass) {
      return child;
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        SizedBox.square(
          dimension: diameter,
          child: const GlassSurface(child: SizedBox.expand()),
        ),
        child,
      ],
    );
  }
}

/// App bar actions grouped on one glass capsule on iOS 26+; a trailing [SizedBox] spacer stays outside it.
List<Widget> glassActions(List<Widget> actions) {
  if (!useLiquidGlass) {
    return actions;
  }
  final spacer = actions.isNotEmpty && actions.last is SizedBox ? actions.last : null;
  final buttons = spacer == null ? actions : actions.sublist(0, actions.length - 1);
  return [Center(child: GlassGroup(children: buttons)), ?spacer];
}

/// A full-width toolbar on a glass capsule inset from the screen edges on iOS 26+; just [child] elsewhere.
class GlassBar extends StatelessWidget {
  final Widget child;

  const GlassBar({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!useLiquidGlass) {
      return child;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: GlassSurface(
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: child),
      ),
    );
  }
}
