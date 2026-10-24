import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/chat/favorite_masonry.dart';

FavoriteEntry _entry(int index) => FavoriteEntry.fromJson({
  'id': 'original-item-${index.toString().padLeft(8, '0')}',
  'snapshotId': 'favorite-item-${index.toString().padLeft(8, '0')}',
  'savedAt': '2026-10-01T00:00:00Z',
  'revision': 1,
  'item': {
    'id': 'favorite-item-${index.toString().padLeft(8, '0')}',
    'originId': 'test-device-00000001',
    'originName': 'Desktop',
    'createdAt': '2026-10-01T00:00:00Z',
    'kind': 'text',
    'text': 'Saved reference $index ${'word ' * (index % 7 * 15)}',
    'name': '',
    'sha256': '',
    'size': 0,
  },
});

void main() {
  Future<void> mount(
    WidgetTester tester,
    List<FavoriteEntry> entries,
    ScrollController scroll, {
    required Widget Function(BuildContext, FavoriteEntry) builder,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1100, 700);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FavoriteMasonry(
            entries: entries,
            controller: scroll,
            itemBuilder: builder,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('heterogeneous columns keep extent estimates bounded and lazy', (
    tester,
  ) async {
    final entries = List.generate(2000, _entry);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final built = <String>{};
    var builds = 0;
    await mount(
      tester,
      entries,
      scroll,
      builder: (_, entry) {
        builds++;
        built.add(entry.id);
        final index = int.parse(entry.id.substring(entry.id.length - 8));
        return SizedBox(
          key: ValueKey('tile-${entry.id}'),
          height: 100 + (index % 7) * 33,
          child: Text(entry.item.text),
        );
      },
    );
    final initialBuilt = built.length;
    final extents = <double>[scroll.position.maxScrollExtent];
    for (final offset in [1000.0, 2000.0, 3500.0, 5000.0]) {
      scroll.jumpTo(offset);
      await tester.pumpAndSettle();
      extents.add(scroll.position.maxScrollExtent);
    }
    final spread = extents.reduce(math.max) - extents.reduce(math.min);
    debugPrint(
      'MASONRY_METRIC initialBuilt=$initialBuilt totalBuilt=${built.length} builds=$builds extentSpread=$spread extents=$extents',
    );
    expect(initialBuilt, lessThan(40));
    expect(built.length, lessThan(150));
    expect(
      spread,
      lessThan(500),
      reason:
          'Newly measured items must not be extrapolated over the whole collection.',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'same ordered IDs refresh their metadata without moving columns',
    (tester) async {
      final entries = List.generate(8, _entry);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget tile(BuildContext _, FavoriteEntry entry) => SizedBox(
        key: ValueKey('tile-${entry.id}'),
        height: 150,
        child: Text('${entry.item.text} | ${entry.savedAt.toIso8601String()}'),
      );
      await mount(tester, entries, scroll, builder: tile);
      final reference = find.byKey(ValueKey('tile-${entries.first.id}'));
      final before = tester.getRect(reference);
      final updated = FavoriteEntry.fromJson({
        'id': entries.first.originalMessageId,
        'snapshotId': entries.first.id,
        'savedAt': '2026-10-25T08:00:00Z',
        'revision': 2,
        'item': {
          ...entries.first.item.toJson(),
          'text': 'Updated saved reference',
        },
      });
      await mount(tester, [updated, ...entries.skip(1)], scroll, builder: tile);
      expect(
        find.text('Updated saved reference | 2026-10-25T08:00:00.000Z'),
        findsOneWidget,
      );
      expect(tester.getRect(reference), before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'front row deletion compacts remaining cards into the first columns',
    (tester) async {
      var entries = List.generate(6, _entry);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget tile(BuildContext _, FavoriteEntry entry) => SizedBox(
        key: ValueKey('tile-${entry.id}'),
        height: 110 + int.parse(entry.id.substring(entry.id.length - 1)) * 24,
        child: Text(entry.item.text),
      );
      await mount(tester, entries, scroll, builder: tile);
      while (entries.length > 1) {
        entries = entries.sublist(1);
        await mount(tester, entries, scroll, builder: tile);
        for (var index = 0; index < math.min(4, entries.length); index++) {
          final rect = tester.getRect(
            find.byKey(ValueKey('tile-${entries[index].id}')),
          );
          expect(rect.top, closeTo(0, .1));
          expect(
            rect.left,
            closeTo(index * 278.0, .1),
            reason:
                'The remaining sorted sequence must fill the leading row without an empty column.',
          );
        }
        expect(scroll.offset, 0);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('prepending and deleting entries retains the visible reference', (
    tester,
  ) async {
    final entries = List.generate(300, _entry);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Widget tile(BuildContext _, FavoriteEntry entry) {
      final index = int.parse(entry.id.substring(entry.id.length - 8));
      return SizedBox(
        key: ValueKey('tile-${entry.id}'),
        height: 100 + (index % 7) * 33,
        child: Text(entry.item.text),
      );
    }

    await mount(tester, entries, scroll, builder: tile);
    scroll.jumpTo(1800);
    await tester.pumpAndSettle();
    final visible =
        entries.where((entry) {
          final finder = find.byKey(ValueKey('tile-${entry.id}'));
          return finder.evaluate().isNotEmpty &&
              tester.getTopLeft(finder).dy >= 0;
        }).toList()..sort(
          (a, b) => tester
              .getTopLeft(find.byKey(ValueKey('tile-${a.id}')))
              .dy
              .compareTo(
                tester.getTopLeft(find.byKey(ValueKey('tile-${b.id}'))).dy,
              ),
        );
    final anchor = visible.first;
    final finder = find.byKey(ValueKey('tile-${anchor.id}'));
    final originalTop = tester.getTopLeft(finder).dy;
    final updated = [_entry(9990), _entry(9991), _entry(9992), ...entries];
    await mount(tester, updated, scroll, builder: tile);
    final moved = tester.getTopLeft(finder).dy - originalTop;
    debugPrint('MASONRY_ANCHOR prependDrift=$moved');
    expect(moved.abs(), lessThan(.5));
    await mount(tester, updated.sublist(2), scroll, builder: tile);
    expect(tester.getTopLeft(finder).dy, closeTo(originalTop, .5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'deleting a visible card preserves the next surviving reading reference',
    (tester) async {
      final entries = List.generate(300, _entry);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget tile(BuildContext _, FavoriteEntry entry) {
        final index = int.parse(entry.id.substring(entry.id.length - 8));
        return SizedBox(
          key: ValueKey('tile-${entry.id}'),
          height: 100 + (index % 7) * 33,
          child: Text(entry.item.text),
        );
      }

      await mount(tester, entries, scroll, builder: tile);
      scroll.jumpTo(1800);
      await tester.pumpAndSettle();
      final visible =
          <(FavoriteEntry, double)>[
            for (final entry in entries)
              if (find
                      .byKey(ValueKey('tile-${entry.id}'))
                      .evaluate()
                      .isNotEmpty &&
                  tester
                          .getTopLeft(find.byKey(ValueKey('tile-${entry.id}')))
                          .dy >=
                      0)
                (
                  entry,
                  tester
                      .getTopLeft(find.byKey(ValueKey('tile-${entry.id}')))
                      .dy,
                ),
          ]..sort((a, b) {
            final top = a.$2.compareTo(b.$2);
            return top != 0 ? top : a.$1.id.compareTo(b.$1.id);
          });
      final removed = visible.first.$1.id;
      final surviving = visible[1];
      final updated = entries.where((entry) => entry.id != removed).toList();
      await mount(tester, updated, scroll, builder: tile);
      expect(find.byKey(ValueKey('tile-$removed')), findsNothing);
      expect(scroll.offset, greaterThan(1000));
      expect(
        tester.getTopLeft(find.byKey(ValueKey('tile-${surviving.$1.id}'))).dy,
        closeTo(surviving.$2, .5),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late image growth above the viewport keeps reading in place', (
    tester,
  ) async {
    final entries = List.generate(300, _entry);
    final scroll = ScrollController();
    final heightChanges = ValueNotifier(<String, double>{});
    addTearDown(scroll.dispose);
    addTearDown(heightChanges.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(
      tester,
      entries,
      scroll,
      builder: (_, entry) => ValueListenableBuilder<Map<String, double>>(
        valueListenable: heightChanges,
        builder: (_, heights, _) => SizedBox(
          key: ValueKey('tile-${entry.id}'),
          height: heights[entry.id] ?? 170,
          child: Text(entry.item.text),
        ),
      ),
    );
    scroll.jumpTo(1800);
    await tester.pumpAndSettle();
    final boxes = <String, Rect>{
      for (final entry in entries)
        if (find.byKey(ValueKey('tile-${entry.id}')).evaluate().isNotEmpty)
          entry.id: tester.getRect(find.byKey(ValueKey('tile-${entry.id}'))),
    };
    final anchors = boxes.entries.where((e) => e.value.top >= 0).toList()
      ..sort((a, b) {
        final order = a.value.top.compareTo(b.value.top);
        return order != 0 ? order : a.key.compareTo(b.key);
      });
    final anchor = anchors.first;
    final preceding = boxes.entries
        .where((e) => e.value.left == anchor.value.left && e.value.top < 0)
        .last;
    heightChanges.value = {preceding.key: 320};
    await tester.pumpAndSettle();
    final after = tester.getRect(find.byKey(ValueKey('tile-${anchor.key}')));
    debugPrint('MASONRY_IMAGE lateGrowthDrift=${after.top - anchor.value.top}');
    expect(after.top, closeTo(anchor.value.top, .5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('late image sizing does not cancel an active drag', (
    tester,
  ) async {
    final entries = List.generate(300, _entry);
    final scroll = ScrollController();
    final expanded = ValueNotifier(false);
    addTearDown(scroll.dispose);
    addTearDown(expanded.dispose);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(
      tester,
      entries,
      scroll,
      builder: (_, entry) => ValueListenableBuilder<bool>(
        valueListenable: expanded,
        builder: (_, larger, _) => SizedBox(
          height: larger && entry.id == entries[12].id ? 280 : 170,
          child: Text(entry.item.text),
        ),
      ),
    );
    scroll.jumpTo(600);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(800, 500));
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    expanded.value = true;
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.position.isScrollingNotifier.value, isTrue);
    final before = scroll.offset;
    await gesture.moveBy(const Offset(0, -90));
    await tester.pump(const Duration(milliseconds: 16));
    expect(scroll.offset, greaterThan(before + 50));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
