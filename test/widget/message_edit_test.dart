import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();
  for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
    testWidgets('messages edit inside their bubble on $platform', (
      tester,
    ) async {
      late InboxEntry entry;
      await tester.runAsync(() async {
        entry = (await harness.inbox.addText('修改前'))!;
      });
      await harness.mount(
        tester,
        platform: platform,
        size: platform == TargetPlatform.windows
            ? const Size(1000, 700)
            : const Size(390, 844),
      );
      final bubble = find.byKey(ValueKey('inbox-item-${entry.item.id}'));
      if (platform == TargetPlatform.windows) {
        await tester.tapAt(
          tester.getCenter(bubble),
          buttons: kSecondaryMouseButton,
        );
      } else {
        await tester.longPress(bubble);
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改'));
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('message-edit-text'));
      expect(find.descendant(of: bubble, matching: editor), findsOneWidget);
      await tester.enterText(editor, '修改后的多行消息\n第二行');
      await tester.tap(find.byKey(const ValueKey('message-edit-save')));
      for (
        var i = 0;
        i < 100 &&
            harness.inbox.store.find(entry.item.id)!.item.text !=
                '修改后的多行消息\n第二行';
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      expect(
        find.descendant(of: bubble, matching: find.text('修改后的多行消息\n第二行')),
        findsOneWidget,
      );
      expect(harness.inbox.items, hasLength(1));
      expect(harness.inbox.items.single.sequence, entry.sequence);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
