/// Local presentation and pin preferences; these never enter sync events.
final class FavoritePreferences {
  FavoritePreferences({
    String layout = 'masonry',
    String filter = 'all',
    String sort = 'newest',
    this.onlyPinned = false,
    Map<String, int> pinned = const {},
  }) : layout = layouts.contains(layout) ? layout : 'masonry',
       filter = filters.contains(filter) ? filter : 'all',
       sort = sorts.contains(sort) ? sort : 'newest',
       pinned = Map.unmodifiable({
         for (final entry in pinned.entries)
           if (entry.key.isNotEmpty && entry.value > 0) entry.key: entry.value,
       });

  factory FavoritePreferences.fromJson(Object? value) {
    final data = value is Map ? value : const {};
    final pins = data['pinned'];
    return FavoritePreferences(
      layout: data['layout'] is String ? data['layout'] as String : 'masonry',
      filter: data['filter'] is String ? data['filter'] as String : 'all',
      sort: data['sort'] is String ? data['sort'] as String : 'newest',
      onlyPinned: data['onlyPinned'] == true,
      pinned: {
        if (pins is Map)
          for (final entry in pins.entries)
            if (entry.key is String && entry.value is int)
              entry.key as String: entry.value as int,
      },
    );
  }

  static const layouts = {'masonry', 'list'};
  static const filters = {'all', 'text', 'image', 'video', 'file'};
  static const sorts = {'newest', 'oldest', 'type', 'titleAsc', 'titleDesc'};

  final String layout, filter, sort;
  final bool onlyPinned;

  /// Favorite snapshot ID to the local pin time, in milliseconds since epoch.
  final Map<String, int> pinned;

  FavoritePreferences copyWith({
    String? layout,
    String? filter,
    String? sort,
    bool? onlyPinned,
    Map<String, int>? pinned,
  }) => FavoritePreferences(
    layout: layout ?? this.layout,
    filter: filter ?? this.filter,
    sort: sort ?? this.sort,
    onlyPinned: onlyPinned ?? this.onlyPinned,
    pinned: pinned ?? this.pinned,
  );

  Map<String, Object> toJson() => {
    'layout': layout,
    'filter': filter,
    'sort': sort,
    'onlyPinned': onlyPinned,
    'pinned': pinned,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FavoritePreferences &&
          layout == other.layout &&
          filter == other.filter &&
          sort == other.sort &&
          onlyPinned == other.onlyPinned &&
          pinned.length == other.pinned.length &&
          pinned.entries.every(
            (entry) => other.pinned[entry.key] == entry.value,
          );

  @override
  int get hashCode => Object.hash(
    layout,
    filter,
    sort,
    onlyPinned,
    Object.hashAllUnordered(
      pinned.entries.map((entry) => Object.hash(entry.key, entry.value)),
    ),
  );
}
