import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/models/search/search_filter.model.dart';
import 'package:immich_mobile/presentation/pages/search/paginated_search.provider.dart';
import 'package:immich_mobile/presentation/pages/search/smart/smart_search_suggestions.dart';
import 'package:immich_mobile/presentation/pages/search/smart/smart_search_tokens.dart';
import 'package:immich_mobile/presentation/widgets/bottom_sheet/general_bottom_sheet.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/timeline/timeline.widget.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/utils/image_url_builder.dart';
import 'package:immich_ui/immich_ui.dart' show GlassCircle, GlassSurface, useLiquidGlass;

// Fork feature: the experimental search (see FORK.md). Type to get suggestions for people, places, cameras, media
// types, dates, tags and text; each pick becomes a token in the search bar at the bottom, and tokens combine.

const _barHeight = 52.0;

/// Kept in front of the typed text while there are tokens: deleting it is a backspace on an empty field, which
/// removes the last token. Keyboards don't report that otherwise.
const _sentinel = '\u200B';
const _chipsHeight = 44.0;

class SmartSearchView extends HookConsumerWidget {
  const SmartSearchView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = useTextEditingController();
    final focus = useFocusNode();
    final text = useValueListenable(controller).text.replaceAll(_sentinel, '');
    final suppress = useRef(false);
    final chipsScroll = useScrollController();
    final focused = useListenableSelector(focus, () => focus.hasFocus);
    final tokens = useState<List<SmartToken>>(const []);
    final category = useState<SmartSearchCategory?>(null);
    final smartSearch = ref.watch(serverInfoProvider.select((v) => v.serverFeatures.smartSearch));
    final language = '${context.locale.languageCode}-${context.locale.countryCode}';

    final filter = useMemoized(() => filterOf(tokens.value, language), [tokens.value, language]);
    useEffect(() {
      final notifier = ref.read(paginatedSearchProvider.notifier);
      unawaited(
        Future.microtask(() {
          notifier.clear();
          if (tokens.value.isNotEmpty) {
            unawaited(notifier.search(filter));
          }
        }),
      );
      return null;
    }, [filter]);
    useEffect(
      () =>
          () => ref.read(paginatedSearchProvider.notifier).clear(),
      const [],
    );

    void setField(String typed) {
      suppress.value = true;
      final value = (tokens.value.isEmpty ? '' : _sentinel) + typed;
      controller.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      suppress.value = false;
    }

    useEffect(() {
      void listener() {
        if (suppress.value || tokens.value.isEmpty || controller.text.startsWith(_sentinel)) {
          return;
        }
        final typed = controller.text.replaceAll(_sentinel, '');
        tokens.value = tokens.value.sublist(0, tokens.value.length - 1);
        setField(typed);
      }

      controller.addListener(listener);
      return () => controller.removeListener(listener);
    }, [controller]);

    // Keeps the text field in view after the tokens.
    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (chipsScroll.hasClients) {
          chipsScroll.jumpTo(chipsScroll.position.maxScrollExtent);
        }
      });
      return null;
    }, [tokens.value, text]);

    void add(SmartToken token) {
      tokens.value = [...tokens.value.where((t) => !token.replaces(t) && t != token), token];
      setField('');
      category.value = null;
    }

    void remove(SmartToken token) {
      tokens.value = tokens.value.where((t) => t != token).toList();
      setField(text);
    }

    void submit(String value) {
      final query = value.replaceAll(_sentinel, '').trim();
      if (query.isNotEmpty) {
        add(
          smartSearch
              ? SmartToken(SmartTokenKind.smart, query, value: query)
              : SmartToken(SmartTokenKind.filename, query, value: query),
        );
      }
      focus.unfocus();
    }

    void reset() {
      tokens.value = const [];
      setField('');
      category.value = null;
      focus.unfocus();
    }

    final showPanel = category.value != null || (focused && text.trim().isNotEmpty);
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final keyboardOpen = View.of(context).viewInsets.bottom > 0;
    const overlayHeight = _barHeight + _chipsHeight + 24;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: () {
                focus.unfocus();
                category.value = null;
              },
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(padding: MediaQuery.paddingOf(context).copyWith(bottom: bottomInset + overlayHeight)),
                child: tokens.value.isEmpty ? const _Intro() : SafeArea(bottom: false, child: _Results(filter: filter)),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            // With the keyboard up the body already ends above it; the tab bar's reserved space is hidden behind it.
            child: Padding(
              padding: EdgeInsets.only(bottom: keyboardOpen ? 8 : bottomInset + 8),
              child: Padding(
                padding: EdgeInsets.zero,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showPanel)
                      _SuggestionPanel(
                        text: text,
                        tokens: tokens.value,
                        category: category.value,
                        smartSearch: smartSearch,
                        onSelect: add,
                      ),
                    _CategoryChips(
                      selected: category.value,
                      onSelect: (value) {
                        if (value == SmartSearchCategory.favorites) {
                          add(const SmartToken(SmartTokenKind.favorite, 'Favorites'));
                          return;
                        }
                        category.value = category.value == value ? null : value;
                      },
                    ),
                    _SearchBar(
                      controller: controller,
                      scroll: chipsScroll,
                      onClearText: () => setField(''),
                      focus: focus,
                      tokens: tokens.value,
                      active: focused || tokens.value.isNotEmpty || category.value != null,
                      hint: smartSearch ? 'People, places, things…' : 'People, places, file names…',
                      onRemove: remove,
                      onSubmit: submit,
                      onClose: reset,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Glass on iOS 26+, a tonal Material surface elsewhere.
class _Surface extends StatelessWidget {
  final Widget child;
  final double radius;

  const _Surface({required this.child, this.radius = -1});

  @override
  Widget build(BuildContext context) {
    if (useLiquidGlass) {
      return GlassSurface(radius: radius, child: child);
    }
    return Material(
      color: context.colorScheme.surfaceContainerHigh,
      elevation: 3,
      shadowColor: Colors.black45,
      shape: radius < 0
          ? const StadiumBorder()
          : RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(radius))),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ScrollController scroll;
  final VoidCallback onClearText;
  final FocusNode focus;
  final List<SmartToken> tokens;
  final bool active;
  final String hint;
  final ValueChanged<SmartToken> onRemove;
  final ValueChanged<String> onSubmit;
  final VoidCallback onClose;

  const _SearchBar({
    required this.controller,
    required this.scroll,
    required this.onClearText,
    required this.focus,
    required this.tokens,
    required this.active,
    required this.hint,
    required this.onRemove,
    required this.onSubmit,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final field = TextField(
      controller: controller,
      focusNode: focus,
      textInputAction: TextInputAction.search,
      onSubmitted: onSubmit,
      style: context.textTheme.bodyLarge,
      decoration: InputDecoration(
        isDense: true,
        border: InputBorder.none,
        hintText: tokens.isEmpty ? hint : null,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: _barHeight,
              child: _Surface(
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Icon(Icons.search, color: colors.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: tokens.isEmpty
                          ? field
                          : SingleChildScrollView(
                              controller: scroll,
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                children: [
                                  for (final token in tokens) _TokenChip(token: token, onTap: () => onRemove(token)),
                                  SizedBox(width: 140, child: field),
                                ],
                              ),
                            ),
                    ),
                    ListenableBuilder(
                      listenable: controller,
                      builder: (context, _) => controller.text.replaceAll(_sentinel, '').isEmpty
                          ? const SizedBox(width: 12)
                          : IconButton(
                              icon: Icon(Icons.cancel, color: colors.onSurfaceVariant, size: 20),
                              onPressed: onClearText,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: active
                ? Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: useLiquidGlass
                        ? GlassCircle(
                            diameter: _barHeight,
                            child: IconButton(icon: const Icon(Icons.close), onPressed: onClose),
                          )
                        : SizedBox.square(
                            dimension: _barHeight,
                            child: _Surface(
                              child: IconButton(icon: const Icon(Icons.close), onPressed: onClose),
                            ),
                          ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _TokenChip extends StatelessWidget {
  final SmartToken token;
  final VoidCallback onTap;

  const _TokenChip({required this.token, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    final label = switch (token.kind) {
      SmartTokenKind.ocr => 'Text: ${token.label}',
      SmartTokenKind.filename => 'File: ${token.label}',
      SmartTokenKind.description => 'Description: ${token.label}',
      _ => token.label,
    };
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: colors.onSurface.withValues(alpha: 0.12),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8))),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(8)),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(label, style: context.textTheme.bodyLarge, maxLines: 1),
          ),
        ),
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  final SmartSearchCategory? selected;
  final ValueChanged<SmartSearchCategory> onSelect;

  const _CategoryChips({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return SizedBox(
      height: _chipsHeight,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        children: [
          for (final category in SmartSearchCategory.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _Surface(
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => onSelect(category),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    decoration: ShapeDecoration(
                      shape: const StadiumBorder(),
                      color: category == selected ? colors.primary.withValues(alpha: 0.25) : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(category.icon, size: 18, color: colors.onSurface),
                        const SizedBox(width: 6),
                        Text(category.label, style: context.textTheme.labelLarge),
                      ],
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

class _SuggestionPanel extends ConsumerWidget {
  final String text;
  final List<SmartToken> tokens;
  final SmartSearchCategory? category;
  final bool smartSearch;
  final ValueChanged<SmartToken> onSelect;

  const _SuggestionPanel({
    required this.text,
    required this.tokens,
    required this.category,
    required this.smartSearch,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sources = ref.watch(smartSearchSourcesProvider).valueOrNull ?? const SmartSearchSources();
    final current = tokens.toSet();
    final items = category == null
        ? suggest(text, sources, current, smartSearch: smartSearch)
        : browse(category!, text, sources, current);
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.4),
        child: _Surface(
          radius: 28,
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            children: [
              for (final item in items)
                _SuggestionTile(token: item, query: text, tokens: current, onTap: () => onSelect(item)),
            ],
          ),
        ),
      ),
    );
  }
}

class _SuggestionTile extends ConsumerWidget {
  final SmartToken token;
  final String query;
  final Set<SmartToken> tokens;
  final VoidCallback onTap;

  const _SuggestionTile({required this.token, required this.query, required this.tokens, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colorScheme;
    final combined = SmartTokenSet({...tokens.where((t) => !token.replaces(t)), token});
    final count = ref.watch(smartSearchCountProvider(combined));
    // Like iOS Photos, suggestions without results disappear once counted.
    if (count.valueOrNull == 0) {
      return const SizedBox.shrink();
    }

    final person = token.person;
    final leading = person != null
        ? CircleAvatar(
            radius: 14,
            backgroundImage: RemoteImageProvider(url: getFaceThumbnailUrl(person.id, updatedAt: person.updatedAt)),
          )
        : Icon(token.kind.icon, color: colors.onSurface);

    final title = token.kind == SmartTokenKind.smart ? 'Search for “${token.label}”' : token.label;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            SizedBox(width: 28, child: Center(child: leading)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _Highlighted(text: title, query: query, style: context.textTheme.titleMedium),
                  if (token.detail != null)
                    Text(token.detail!, style: context.textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant)),
                ],
              ),
            ),
            if (count.valueOrNull != null)
              Text(
                NumberFormat.decimalPattern(context.locale.toLanguageTag()).format(count.valueOrNull),
                style: context.textTheme.titleMedium?.copyWith(color: colors.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// [text] with the part matching [query] at full strength and the rest dimmed, like iOS Photos.
class _Highlighted extends StatelessWidget {
  final String text;
  final String query;
  final TextStyle? style;

  const _Highlighted({required this.text, required this.query, this.style});

  @override
  Widget build(BuildContext context) {
    final dim = style?.copyWith(color: style?.color?.withValues(alpha: 0.55) ?? Colors.grey);
    final q = query.trim().toLowerCase();
    final start = q.isEmpty ? -1 : text.toLowerCase().indexOf(q);
    if (start < 0) {
      return Text(text, style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    }
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: text.substring(0, start), style: dim),
          TextSpan(text: text.substring(start, start + q.length), style: style),
          TextSpan(text: text.substring(start + q.length), style: dim),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final colors = context.colorScheme;
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.manage_search_rounded, size: 64, color: colors.primary),
              const SizedBox(height: 16),
              Text('Search your library', style: context.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'Type a name, place, camera, date or anything in your photos, and combine as many as you like.',
                textAlign: TextAlign.center,
                style: context.textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  final SearchFilter filter;

  const _Results({required this.filter});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasAssets = ref.watch(paginatedSearchProvider.select((s) => s.assets.isNotEmpty));
    final isLoading = ref.watch(paginatedSearchProvider.select((s) => s.isLoading));

    if (!hasAssets) {
      return SafeArea(
        minimum: const EdgeInsets.symmetric(horizontal: 32),
        child: Center(
          child: isLoading
              ? const CircularProgressIndicator()
              : Text(
                  context.tr('search_no_result'),
                  textAlign: TextAlign.center,
                  style: context.textTheme.bodyLarge?.copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
        ),
      );
    }

    return NotificationListener<ScrollUpdateNotification>(
      onNotification: (notification) {
        final metrics = notification.metrics;
        if (metrics.axis == Axis.vertical && metrics.maxScrollExtent - metrics.pixels < metrics.viewportDimension) {
          unawaited(ref.read(paginatedSearchProvider.notifier).search(filter));
        }
        return false;
      },
      child: ProviderScope(
        overrides: [
          timelineServiceProvider.overrideWith((ref) {
            final notifier = ref.read(paginatedSearchProvider.notifier);
            final service = ref
                .watch(timelineFactoryProvider)
                .fromAssetStream(
                  () => ref.read(paginatedSearchProvider).assets,
                  notifier.assetCount,
                  TimelineOrigin.search,
                );
            ref.onDispose(service.dispose);
            return service;
          }),
        ],
        child: const Timeline(
          groupBy: GroupAssetsBy.none,
          appBar: null,
          bottomSheet: GeneralBottomSheet(minChildSize: 0.20),
          snapToMonth: false,
          loadingWidget: SizedBox.shrink(),
        ),
      ),
    );
  }
}
