import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/platform/title_order.dart';

List<FavoriteEntry> favoriteResults(
  List<FavoriteEntry> favorites,
  FavoritePreferences preferences,
  String query, {
  Map<String, int>? titleRanks,
  List<FavoriteEntry> previous = const [],
}) {
  final byTitle =
      preferences.sort == 'titleAsc' || preferences.sort == 'titleDesc';
  final oldOrder = byTitle && titleRanks == null
      ? {
          for (var index = 0; index < previous.length; index++)
            previous[index].id: index,
        }
      : const <String, int>{};
  final result = favorites.where((entry) {
    final item = entry.item;
    return (preferences.filter == 'all' ||
            item.kind.name == preferences.filter) &&
        (!preferences.onlyPinned || preferences.pinned.containsKey(entry.id)) &&
        (query.isEmpty ||
            (item.isFile ? item.name : item.text).toLowerCase().contains(
              query,
            ));
  }).toList();
  final ranked = byTitle && titleRanks != null
      ? {
          for (final entry in result)
            entry.id:
                titleRanks[TitleOrder.label(
                  entry.item.isFile ? entry.item.name : entry.item.text,
                )] ??
                0,
        }
      : const <String, int>{};
  result.sort((a, b) {
    final aPinned = preferences.pinned.containsKey(a.id);
    final bPinned = preferences.pinned.containsKey(b.id);
    if (aPinned != bPinned) return aPinned ? -1 : 1;
    var order = 0;
    switch (preferences.sort) {
      case 'oldest':
        order = a.savedAt.compareTo(b.savedAt);
      case 'type':
        order = a.item.kind.index.compareTo(b.item.kind.index);
      case 'titleAsc' || 'titleDesc':
        if (titleRanks == null) {
          order = (oldOrder[a.id] ?? previous.length).compareTo(
            oldOrder[b.id] ?? previous.length,
          );
        } else {
          order = ranked[a.id]!.compareTo(ranked[b.id]!);
          if (preferences.sort == 'titleDesc') order = -order;
        }
      default:
        order = b.savedAt.compareTo(a.savedAt);
    }
    if (order != 0) return order;
    order = b.savedAt.compareTo(a.savedAt);
    return order != 0 ? order : b.id.compareTo(a.id);
  });
  return result;
}
