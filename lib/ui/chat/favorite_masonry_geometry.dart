import 'dart:math' as math;

import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';

class FavoriteMasonryGeometry {
  static const gap = 12.0;
  Object? _key, _geometryKey, _token;
  final _measured = <String, double>{};
  final _locations = <String, (int, int)>{};
  Map<String, int> globalIndices = {};
  List<FavoriteMasonryColumn> columns = [];

  bool arrange(
    List<FavoriteEntry> entries,
    int count,
    double width,
    double scale,
    Object? token,
  ) {
    final key = (entries, count, width, scale, token);
    if (_key == key) return false;
    _key = key;
    final geometry = (count, width, scale);
    final sameOrder =
        entries.length == globalIndices.length &&
        entries.asMap().entries.every(
          (entry) => globalIndices[entry.value.id] == entry.key,
        );
    if (_geometryKey == geometry && _token == token && sameOrder) {
      // Metadata can change without changing the ordered identities. Refresh
      // the values used by builders while retaining the measured height trees.
      for (final column in columns) {
        for (var row = 0; row < column.entries.length; row++) {
          final index = globalIndices[column.entries[row].id]!;
          column.entries[row] = entries[index];
        }
      }
      return false;
    }
    if (_geometryKey != geometry) _measured.clear();
    _geometryKey = geometry;
    _token = token;
    _locations.clear();
    globalIndices = {
      for (var index = 0; index < entries.length; index++)
        entries[index].id: index,
    };
    final ordered = List.generate(count, (_) => <FavoriteEntry>[]);
    final estimates = List.generate(count, (_) => <double>[]);
    final totals = List.filled(count, 0.0);
    for (final entry in entries) {
      // Repack structural changes in the current sort order. Keeping a removed
      // card's old column assignment leaves holes in short collections.
      var column = 0;
      for (var next = 1; next < count; next++) {
        if (totals[next] < totals[column]) column = next;
      }
      final extent = _measured[entry.id] ?? _estimate(entry.item, width, scale);
      _locations[entry.id] = (column, ordered[column].length);
      ordered[column].add(entry);
      estimates[column].add(extent);
      totals[column] += extent;
    }
    _measured.removeWhere((id, _) => !_locations.containsKey(id));
    columns = List.generate(
      count,
      (index) => FavoriteMasonryColumn(ordered[index], estimates[index]),
    );
    return true;
  }

  void measure(String id, double extent) {
    final location = _locations[id];
    if (location == null || !extent.isFinite || extent <= 0) return;
    _measured[id] = extent;
    columns[location.$1].update(location.$2, extent);
  }

  double? offsetOf(String id) {
    final location = _locations[id];
    return location == null ? null : columns[location.$1].prefix(location.$2);
  }

  double _estimate(InboxItem item, double width, double scale) {
    if (item.kind == MessageKind.image) return width + 124 * scale + gap;
    if (item.isFile) return 152 * scale + gap;
    final sample = item.text.substring(0, math.min(item.text.length, 400));
    final charsPerLine = math.max(1.0, (width - 24) / (9 * scale));
    final lines = sample
        .split('\n')
        .fold<int>(
          0,
          (sum, line) => sum + math.max(1, (line.length / charsPerLine).ceil()),
        );
    return 104 * scale + lines.clamp(1, 5) * 22 * scale + gap;
  }
}

class FavoriteMasonryColumn {
  FavoriteMasonryColumn(this.entries, List<double> estimates)
    : _extents = List.of(estimates),
      _tree = List.filled(estimates.length + 1, 0),
      indices = {
        for (var row = 0; row < entries.length; row++) entries[row].id: row,
      } {
    for (var row = 0; row < estimates.length; row++) {
      _add(row, estimates[row]);
    }
  }

  final List<FavoriteEntry> entries;
  final Map<String, int> indices;
  final List<double> _extents, _tree;

  void _add(int row, double delta) {
    for (var i = row + 1; i < _tree.length; i += i & -i) {
      _tree[i] += delta;
    }
  }

  void update(int row, double extent) {
    final delta = extent - _extents[row];
    if (delta.abs() < .01) return;
    _extents[row] = extent;
    _add(row, delta);
  }

  double prefix(int count) {
    var sum = 0.0;
    for (var i = count; i > 0; i -= i & -i) {
      sum += _tree[i];
    }
    return sum;
  }

  double remainingAfter(int row) => prefix(entries.length) - prefix(row + 1);
}
