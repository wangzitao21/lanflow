import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (done()) break;
    }
    expect(done(), isTrue);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'favorite delete compacts the layout, toast expires, and Undo still restores',
    (tester) async {
      await tester.runAsync(() async {
        final first = (await harness.inbox.addText('第一项收藏'))!;
        final second = (await harness.inbox.addText('第二项收藏'))!;
        await harness.inbox.setFavorites([first.item.id, second.item.id], true);
      });
      await harness.mount(tester);
      await tester.tap(find.byKey(const ValueKey('desktop-nav-favorites')));
      await tester.pumpAndSettle();
      final first = harness.inbox.favoriteEntries.first.id;
      final firstPosition = tester.getTopLeft(
        find.byKey(ValueKey('favorite-$first')),
      );
      await tester.tap(find.byKey(ValueKey('favorite-delete-$first')));
      await settleUntil(
        tester,
        () => harness.inbox.favoriteEntries.length == 1,
      );
      expect(find.text('已删除 1 项收藏'), findsOneWidget);
      expect(harness.inbox.items, hasLength(2));
      final remaining = harness.inbox.favoriteEntries.single.id;
      expect(
        tester.getTopLeft(find.byKey(ValueKey('favorite-$remaining'))),
        firstPosition,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(harness.inbox.favoriteEntries, hasLength(1));

      await tester.tap(find.byKey(ValueKey('favorite-delete-$remaining')));
      await settleUntil(tester, () => harness.inbox.favoriteEntries.isEmpty);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('撤销'));
      await settleUntil(
        tester,
        () => harness.inbox.favoriteEntries.length == 1,
      );
      expect(harness.inbox.favoriteEntries.single.id, remaining);
      expect(harness.inbox.items, hasLength(2));
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
