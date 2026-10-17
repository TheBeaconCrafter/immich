import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart' hide AssetVisibility;
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/extensions/string_extensions.dart';
import 'package:immich_mobile/models/search/search_filter.model.dart';
import 'package:immich_mobile/presentation/pages/search/smart/smart_search_tokens.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/search/search_filter.provider.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' hide SearchFilter;

// Fork feature: the experimental search (see FORK.md). Suggests tokens for typed text, iOS Photos style.

final _log = Logger('SmartSearch');

/// Everything the user's library can be filtered by.
class SmartSearchSources {
  final List<Person> people;
  final List<String> cities;
  final List<String> states;
  final List<String> countries;
  final List<String> makes;
  final List<String> models;
  final List<Tag> tags;

  const SmartSearchSources({
    this.people = const [],
    this.cities = const [],
    this.states = const [],
    this.countries = const [],
    this.makes = const [],
    this.models = const [],
    this.tags = const [],
  });
}

final smartSearchSourcesProvider = FutureProvider.autoDispose<SmartSearchSources>((ref) async {
  Future<List<T>> safe<T>(Future<List<T>> future) => future.catchError((Object e) {
    _log.warning('Failed to load search suggestions', e);
    return <T>[];
  });
  Future<List<String>> suggestions(SearchSuggestionType type) =>
      safe(ref.watch(getSearchSuggestionsProvider(SearchSuggestionArgs(type: type)).future));

  final results = await Future.wait([
    safe(ref.watch(Store.people.all().future)),
    suggestions(SearchSuggestionType.city),
    suggestions(SearchSuggestionType.state),
    suggestions(SearchSuggestionType.country),
    suggestions(SearchSuggestionType.cameraMake),
    suggestions(SearchSuggestionType.cameraModel),
    safe(ref.watch(Store.tags.all().future)),
  ]);
  return SmartSearchSources(
    people: (results[0] as List<Person>).where((p) => p.name.isNotEmpty).toList(),
    cities: results[1] as List<String>,
    states: results[2] as List<String>,
    countries: results[3] as List<String>,
    makes: results[4] as List<String>,
    models: results[5] as List<String>,
    tags: results[6] as List<Tag>,
  );
});

/// Number of assets matching [tokens], or null if the server can't count them (text searches).
final smartSearchCountProvider = FutureProvider.autoDispose.family<int?, SmartTokenSet>((ref, key) async {
  final tokens = key.tokens;
  if (tokens.any((token) => token.kind == SmartTokenKind.smart || token.kind == SmartTokenKind.filename)) {
    return null;
  }
  final filter = filterOf(tokens, null);
  try {
    final response = await ref.read(apiServiceProvider).searchApi.searchAssetStatistics(_statistics(filter));
    return response?.total;
  } catch (e) {
    _log.warning('Failed to count search results', e);
    return null;
  }
});

StatisticsSearchDto _statistics(SearchFilter filter) {
  Optional<T?> opt<T>(T? value) => value == null ? const Optional.absent() : Optional.present(value);
  final type = switch (filter.mediaType) {
    AssetType.image => AssetTypeEnum.IMAGE,
    AssetType.video => AssetTypeEnum.VIDEO,
    _ => null,
  };
  return StatisticsSearchDto(
    city: opt(filter.location.city),
    state: opt(filter.location.state),
    country: opt(filter.location.country),
    make: opt(filter.camera.make),
    model: opt(filter.camera.model),
    takenAfter: opt(filter.date.takenAfter),
    takenBefore: opt(filter.date.takenBefore),
    isFavorite: filter.display.isFavorite ? const Optional.present(true) : const Optional.absent(),
    personIds: filter.people.isEmpty
        ? const Optional.absent()
        : Optional.present(filter.people.map((p) => p.id).toList()),
    tagIds: (filter.tags?.isEmpty ?? true)
        ? const Optional.absent()
        : Optional.present(filter.tags!.map((t) => t.id).toList()),
    type: opt(type),
    ocr: opt(filter.ocr),
    description: opt(filter.description),
    visibility: const Optional.present(AssetVisibility.timeline),
  );
}

/// Categories offered as chips above the search bar, each listing all of its values.
enum SmartSearchCategory {
  people('People', Icons.people_outline),
  places('Places', Icons.location_on_outlined),
  camera('Camera', Icons.photo_camera_outlined),
  date('Date', Icons.calendar_today_outlined),
  type('Media type', Icons.perm_media_outlined),
  favorites('Favorites', Icons.favorite_border),
  tags('Tags', Icons.sell_outlined);

  final String label;
  final IconData icon;

  const SmartSearchCategory(this.label, this.icon);
}

const _months = [
  ['january', 'jan', 'januar', 'jänner'],
  ['february', 'feb', 'februar'],
  ['march', 'mar', 'märz', 'maerz'],
  ['april', 'apr'],
  ['may', 'mai'],
  ['june', 'jun', 'juni'],
  ['july', 'jul', 'juli'],
  ['august', 'aug'],
  ['september', 'sep', 'sept'],
  ['october', 'oct', 'oktober', 'okt'],
  ['november', 'nov'],
  ['december', 'dec', 'dezember', 'dez'],
];
const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June', //
  'July', 'August', 'September', 'October', 'November', 'December',
];

String _norm(String s) => s.toLowerCase().removeDiacritics().trim();

/// How well [name] matches [query]: 0 = prefix, 1 = a word starts with it, 2 = contains it, null = no match.
int? _match(String name, String query) {
  final n = _norm(name);
  if (n.startsWith(query)) {
    return 0;
  }
  if (n.split(RegExp(r'[\s\-_/,.()]+')).any((word) => word.startsWith(query))) {
    return 1;
  }
  return query.length >= 3 && n.contains(query) ? 2 : null;
}

List<T> _best<T>(Iterable<T> items, String query, String Function(T) name, int limit) {
  final scored = <(int, T)>[];
  for (final item in items) {
    final score = _match(name(item), query);
    if (score != null) {
      scored.add((score, item));
    }
  }
  scored.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : name(a.$2).length.compareTo(name(b.$2).length));
  return scored.take(limit).map((e) => e.$2).toList();
}

DateTimeRange _yearRange(int year) =>
    DateTimeRange(start: DateTime(year), end: DateTime(year + 1).subtract(const Duration(milliseconds: 1)));

DateTimeRange _monthRange(int year, int month) => DateTimeRange(
  start: DateTime(year, month),
  end: DateTime(year, month + 1).subtract(const Duration(milliseconds: 1)),
);

SmartToken _date(String label, DateTimeRange range) => SmartToken(SmartTokenKind.date, label, range: range);

List<SmartToken> _dates(String query, DateTime now) {
  final result = <SmartToken>[];
  final today = DateTime(now.year, now.month, now.day);
  final relative = {
    'today': _date('Today', DateTimeRange(start: today, end: now)),
    'yesterday': _date(
      'Yesterday',
      DateTimeRange(
        start: today.subtract(const Duration(days: 1)),
        end: today.subtract(const Duration(milliseconds: 1)),
      ),
    ),
    'this week': _date(
      'This week',
      DateTimeRange(
        start: today.subtract(Duration(days: today.weekday - 1)),
        end: now,
      ),
    ),
    'this month': _date('This month', DateTimeRange(start: DateTime(now.year, now.month), end: now)),
    'last month': _date(
      'Last month',
      _monthRange(now.month == 1 ? now.year - 1 : now.year, now.month == 1 ? 12 : now.month - 1),
    ),
    'this year': _date('This year', DateTimeRange(start: DateTime(now.year), end: now)),
    'last year': _date('Last year', _yearRange(now.year - 1)),
  };
  for (final entry in relative.entries) {
    if (entry.key.startsWith(query) && query.length >= 2) {
      result.add(entry.value);
    }
  }

  final words = query.split(RegExp(r'\s+'));
  final year = words.map(int.tryParse).firstWhere((y) => y != null && y >= 1900 && y <= now.year, orElse: () => null);
  final monthWord = words.firstWhere((w) => int.tryParse(w) == null, orElse: () => '');
  final month = monthWord.length >= 3 ? _months.indexWhere((names) => names.any((n) => n.startsWith(monthWord))) : -1;

  if (month >= 0) {
    if (year != null) {
      result.add(_date('${_monthNames[month]} $year', _monthRange(year, month + 1)));
    } else {
      // The last two occurrences of the month.
      final latest = month + 1 <= now.month ? now.year : now.year - 1;
      result
        ..add(_date('${_monthNames[month]} $latest', _monthRange(latest, month + 1)))
        ..add(_date('${_monthNames[month]} ${latest - 1}', _monthRange(latest - 1, month + 1)));
    }
  } else if (year != null) {
    result.add(_date('$year', _yearRange(year)));
  } else if (RegExp(r'^(19|20)\d{0,2}$').hasMatch(query)) {
    // A partially typed year, e.g. "202".
    for (var y = now.year; y >= 1990 && result.length < 3; y--) {
      if ('$y'.startsWith(query)) {
        result.add(_date('$y', _yearRange(y)));
      }
    }
  }
  return result;
}

const _photoWords = ['photos', 'pictures', 'images', 'fotos', 'bilder'];
const _videoWords = ['videos', 'movies', 'filme'];
const _favoriteWords = ['favorites', 'favourites', 'favoriten', 'liked'];

/// Suggestions for the typed [text], best matches first, leaving out what [tokens] already contain.
List<SmartToken> suggest(
  String text,
  SmartSearchSources sources,
  Set<SmartToken> tokens, {
  required bool smartSearch,
  DateTime? now,
}) {
  final query = _norm(text);
  if (query.isEmpty) {
    return const [];
  }
  final result = <SmartToken>[
    for (final person in _best(sources.people, query, (p) => p.name, 3))
      SmartToken(SmartTokenKind.person, person.name, detail: 'Person', person: person),
    for (final city in _best(sources.cities, query, (c) => c, 3))
      SmartToken(SmartTokenKind.city, city, detail: 'City', value: city),
    for (final state in _best(sources.states, query, (s) => s, 1))
      SmartToken(SmartTokenKind.state, state, detail: 'Region', value: state),
    for (final country in _best(sources.countries, query, (c) => c, 1))
      SmartToken(SmartTokenKind.country, country, detail: 'Country', value: country),
    for (final make in _best(sources.makes, query, (m) => m, 1))
      SmartToken(SmartTokenKind.make, make, detail: 'Camera brand', value: make),
    for (final model in _best(sources.models, query, (m) => m, 2))
      SmartToken(SmartTokenKind.model, model, detail: 'Camera', value: model),
    if (_photoWords.any((w) => w.startsWith(query) && query.length >= 2))
      const SmartToken(SmartTokenKind.mediaType, 'Photos', detail: 'Media type', mediaType: AssetType.image),
    if (_videoWords.any((w) => w.startsWith(query) && query.length >= 2))
      const SmartToken(SmartTokenKind.mediaType, 'Videos', detail: 'Media type', mediaType: AssetType.video),
    if (_favoriteWords.any((w) => w.startsWith(query) && query.length >= 3))
      const SmartToken(SmartTokenKind.favorite, 'Favorites', detail: 'Favorites'),
    ..._dates(query, now ?? DateTime.now()),
    for (final tag in _best(sources.tags, query, (t) => t.value, 2))
      SmartToken(SmartTokenKind.tag, tag.value, detail: 'Tag', tag: tag),
  ].where((token) => !tokens.contains(token)).toList();

  final value = text.trim();
  result.addAll([
    if (value.length >= 2) SmartToken(SmartTokenKind.ocr, value, detail: 'Text in photos', value: value),
    if (value.length >= 2) SmartToken(SmartTokenKind.description, value, detail: 'Description', value: value),
    if (value.length >= 2) SmartToken(SmartTokenKind.filename, value, detail: 'File name', value: value),
    if (smartSearch) SmartToken(SmartTokenKind.smart, value, detail: 'Search by content', value: value),
  ]);
  return result;
}

/// Every value of [category], filtered by [text].
List<SmartToken> browse(
  SmartSearchCategory category,
  String text,
  SmartSearchSources sources,
  Set<SmartToken> tokens, {
  DateTime? now,
}) {
  final query = _norm(text);
  bool matches(String name) => query.isEmpty || _match(name, query) != null;
  final date = now ?? DateTime.now();
  final result = switch (category) {
    SmartSearchCategory.people => [
      for (final person in sources.people)
        if (matches(person.name)) SmartToken(SmartTokenKind.person, person.name, detail: 'Person', person: person),
    ],
    SmartSearchCategory.places => [
      for (final city in sources.cities)
        if (matches(city)) SmartToken(SmartTokenKind.city, city, detail: 'City', value: city),
      for (final country in sources.countries)
        if (matches(country)) SmartToken(SmartTokenKind.country, country, detail: 'Country', value: country),
    ],
    SmartSearchCategory.camera => [
      for (final model in sources.models)
        if (matches(model)) SmartToken(SmartTokenKind.model, model, detail: 'Camera', value: model),
      for (final make in sources.makes)
        if (matches(make)) SmartToken(SmartTokenKind.make, make, detail: 'Camera brand', value: make),
    ],
    SmartSearchCategory.date => [
      ...query.isEmpty ? _dates('this', date) + _dates('last', date) : _dates(query, date),
      if (query.isEmpty)
        for (var year = date.year; year > date.year - 25; year--) _date('$year', _yearRange(year)),
    ],
    SmartSearchCategory.type => const [
      SmartToken(SmartTokenKind.mediaType, 'Photos', detail: 'Media type', mediaType: AssetType.image),
      SmartToken(SmartTokenKind.mediaType, 'Videos', detail: 'Media type', mediaType: AssetType.video),
    ],
    SmartSearchCategory.favorites => const [SmartToken(SmartTokenKind.favorite, 'Favorites', detail: 'Favorites')],
    SmartSearchCategory.tags => [
      for (final tag in sources.tags)
        if (matches(tag.value)) SmartToken(SmartTokenKind.tag, tag.value, detail: 'Tag', tag: tag),
    ],
  };
  return result.where((token) => !tokens.contains(token)).toList();
}
