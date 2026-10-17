import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/models/search/search_filter.model.dart';

// Fork feature: the experimental search (see FORK.md). A search is a list of tokens, each narrowing it down.

enum SmartTokenKind {
  person(Icons.account_circle_outlined),
  city(Icons.location_on_outlined),
  state(Icons.map_outlined),
  country(Icons.public),
  make(Icons.photo_camera_outlined),
  model(Icons.camera_outlined),
  mediaType(Icons.perm_media_outlined),
  date(Icons.calendar_today_outlined),
  favorite(Icons.favorite_border),
  tag(Icons.sell_outlined),
  ocr(Icons.document_scanner_outlined),
  filename(Icons.insert_drive_file_outlined),
  description(Icons.notes),
  smart(Icons.search);

  final IconData icon;

  const SmartTokenKind(this.icon);

  /// Text searches: shown as such in the bar and not counted against the server's statistics.
  bool get isText => this == ocr || this == filename || this == description || this == smart;
}

@immutable
class SmartToken {
  final SmartTokenKind kind;

  /// Shown in the bar and the suggestion list.
  final String label;

  /// Extra line for the suggestion list, e.g. "Text in photos".
  final String? detail;

  final String? value;
  final Person? person;
  final Tag? tag;
  final AssetType? mediaType;
  final DateTimeRange? range;

  const SmartToken(this.kind, this.label, {this.detail, this.value, this.person, this.tag, this.mediaType, this.range});

  String get _key => '${kind.name}:${person?.id ?? tag?.id ?? mediaType?.name ?? range?.toString() ?? value ?? label}';

  @override
  bool operator ==(Object other) => other is SmartToken && other._key == _key;

  @override
  int get hashCode => _key.hashCode;

  /// Tokens that can't be combined with this one, as the server takes one value for them (e.g. one city).
  bool replaces(SmartToken other) => switch (kind) {
    SmartTokenKind.person || SmartTokenKind.tag => false,
    SmartTokenKind.mediaType ||
    SmartTokenKind.date ||
    SmartTokenKind.favorite ||
    SmartTokenKind.city ||
    SmartTokenKind.state ||
    SmartTokenKind.country ||
    SmartTokenKind.make ||
    SmartTokenKind.model => other.kind == kind,
    // One text query: the server searches either by meaning, text in photos, file name or description.
    _ => other.kind.isText,
  };

  SearchFilter apply(SearchFilter filter) => switch (kind) {
    SmartTokenKind.person => filter.copyWith(people: {...filter.people, person!}),
    SmartTokenKind.tag => filter.copyWith(tags: {...?filter.tags, tag!}),
    SmartTokenKind.city => filter.copyWith(location: filter.location.copyWith(city: value)),
    SmartTokenKind.state => filter.copyWith(location: filter.location.copyWith(state: value)),
    SmartTokenKind.country => filter.copyWith(location: filter.location.copyWith(country: value)),
    SmartTokenKind.make => filter.copyWith(camera: filter.camera.copyWith(make: value)),
    SmartTokenKind.model => filter.copyWith(camera: filter.camera.copyWith(model: value)),
    SmartTokenKind.mediaType => filter.copyWith(mediaType: mediaType!),
    SmartTokenKind.date => filter.copyWith(
      date: SearchDateFilter(takenAfter: range!.start, takenBefore: range!.end),
    ),
    SmartTokenKind.favorite => filter.copyWith(display: filter.display.copyWith(isFavorite: true)),
    SmartTokenKind.ocr => filter.copyWith(ocr: value),
    SmartTokenKind.filename => filter.copyWith(filename: value),
    SmartTokenKind.description => filter.copyWith(description: value),
    SmartTokenKind.smart => filter.copyWith(context: value),
  };
}

SearchFilter emptySearchFilter(String? language) => SearchFilter(
  people: {},
  location: const SearchLocationFilter(),
  camera: const SearchCameraFilter(),
  date: const SearchDateFilter(),
  display: const SearchDisplayFilters(isNotInAlbum: false, isArchive: false, isFavorite: false),
  rating: const SearchRatingFilter(),
  mediaType: AssetType.other,
  language: language,
  tags: {},
);

SearchFilter filterOf(Iterable<SmartToken> tokens, String? language) =>
    tokens.fold(emptySearchFilter(language), (filter, token) => token.apply(filter));

/// A set of tokens with value equality, for provider keys.
@immutable
class SmartTokenSet {
  static const _equality = SetEquality<SmartToken>();

  final Set<SmartToken> tokens;

  const SmartTokenSet(this.tokens);

  @override
  bool operator ==(Object other) => other is SmartTokenSet && _equality.equals(tokens, other.tokens);

  @override
  int get hashCode => _equality.hash(tokens);
}
