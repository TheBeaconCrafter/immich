import 'package:flutter/material.dart';

// Fork feature: floating tab bar (experimental setting, Android), modelled on Google Photos' navigation: a pill with
// the main tabs, where the selected tab shows its icon and label in a tonal capsule, next to a round search button.

const _barHeight = 64.0;
const _gap = 10.0;
const _duration = Duration(milliseconds: 250);

class FloatingTabBar extends StatelessWidget {
  final List<NavigationDestination> destinations;
  final int selectedIndex;

  /// Index of the destination shown as the separate round button.
  final int searchIndex;
  final ValueChanged<int> onDestinationSelected;

  const FloatingTabBar({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.searchIndex,
    required this.onDestinationSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final search = destinations[searchIndex];
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottom + 12),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: _Surface(
              colors: colors,
              child: Padding(
                padding: const EdgeInsets.all(8),
                // Shrinks the tabs on narrow screens or with large text instead of cutting off the last one.
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final (index, destination) in destinations.indexed)
                        if (index != searchIndex)
                          _Tab(
                            destination: destination,
                            selected: index == selectedIndex,
                            colors: colors,
                            onTap: () => onDestinationSelected(index),
                          ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: _gap),
          _Surface(
            colors: colors,
            shape: const CircleBorder(),
            child: _Tappable(
              enabled: search.enabled,
              onTap: () => onDestinationSelected(searchIndex),
              shape: const CircleBorder(),
              child: AnimatedContainer(
                duration: _duration,
                curve: Curves.easeOutCubic,
                width: _barHeight,
                height: _barHeight,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selectedIndex == searchIndex ? colors.secondaryContainer : Colors.transparent,
                ),
                child: IconTheme(
                  data: IconThemeData(
                    color: selectedIndex == searchIndex ? colors.onSecondaryContainer : colors.onSurface,
                    size: 28,
                  ),
                  child: Semantics(
                    label: search.label,
                    selected: selectedIndex == searchIndex,
                    button: true,
                    child: selectedIndex == searchIndex ? (search.selectedIcon ?? search.icon) : search.icon,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Surface extends StatelessWidget {
  final ColorScheme colors;
  final ShapeBorder shape;
  final Widget child;

  const _Surface({required this.colors, required this.child, this.shape = const StadiumBorder()});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: colors.surfaceContainerHighest,
      shape: shape,
      elevation: 6,
      shadowColor: Colors.black54,
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _Tab extends StatelessWidget {
  final NavigationDestination destination;
  final bool selected;
  final ColorScheme colors;
  final VoidCallback onTap;

  const _Tab({required this.destination, required this.selected, required this.colors, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      color: selected ? colors.onSecondaryContainer : colors.onSurfaceVariant,
      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
    );

    return _Tappable(
      enabled: destination.enabled,
      onTap: onTap,
      shape: const StadiumBorder(),
      child: AnimatedContainer(
        duration: _duration,
        curve: Curves.easeOutCubic,
        height: _barHeight - 16,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: ShapeDecoration(
          shape: const StadiumBorder(),
          color: selected ? colors.secondaryContainer : Colors.transparent,
        ),
        child: Semantics(
          selected: selected,
          button: true,
          child: AnimatedSize(
            duration: _duration,
            curve: Curves.easeOutCubic,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  IconTheme(
                    data: IconThemeData(color: colors.onSecondaryContainer, size: 24),
                    child: destination.selectedIcon ?? destination.icon,
                  ),
                  const SizedBox(width: 8),
                ],
                Text(destination.label, style: textStyle, maxLines: 1, overflow: TextOverflow.fade, softWrap: false),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tappable extends StatelessWidget {
  final bool enabled;
  final VoidCallback onTap;
  final ShapeBorder shape;
  final Widget child;

  const _Tappable({required this.enabled, required this.onTap, required this.shape, required this.child});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.38,
      child: InkWell(customBorder: shape, onTap: enabled ? onTap : null, child: child),
    );
  }
}
