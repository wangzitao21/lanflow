import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import '../support/widget_harness.dart';

Future<void> waitForStorage(WidgetTester tester, bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Storage operation did not finish');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  final harness = WidgetTestHarness();
  testWidgets(
    'desktop selects several messages, confirms once and deletes silently with recycle bin recovery',
    (tester) async {
      final messages = <InboxEntry>[];
      await tester.runAsync(() async {
        for (var i = 0; i < 3; i++) {
          messages.add((await harness.inbox.addText('选择测试 $i'))!);
        }
      });
      await harness.mount(tester);
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(editor, '未发送草稿');
      await tester.tap(find.byTooltip('多选消息'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('select-message-${messages[0].item.id}')),
      );
      await tester.tap(
        find.byKey(ValueKey('select-message-${messages[1].item.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 2 条'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('delete-selected-messages')));
      await tester.pumpAndSettle();
      expect(find.text('删除 2 条消息？'), findsOneWidget);
      expect(harness.inbox.items.length, 3);
      await tester.tap(find.widgetWithText(FilledButton, '删除'));
      await tester.pumpAndSettle();
      await waitForStorage(tester, () => harness.inbox.items.length == 1);
      expect(harness.inbox.items.single.item.id, messages[2].item.id);
      expect(tester.widget<TextField>(editor).controller!.text, '未发送草稿');
      expect(find.byType(SnackBar), findsNothing);
      await tester.runAsync(() async {
        for (final entry in messages.take(2)) {
          await harness.inbox.restoreItem(entry.item);
        }
      });
      await waitForStorage(tester, () => harness.inbox.items.length == 3);
      expect(harness.inbox.items.map((e) => e.item.text).toSet(), {
        '选择测试 0',
        '选择测试 1',
        '选择测试 2',
      });
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mobile long press starts multi-select; selected messages can be favorited and found',
    (tester) async {
      late InboxEntry a, b;
      await tester.runAsync(() async {
        a = (await harness.inbox.addText('手机收藏第一条'))!;
        b = (await harness.inbox.addText('手机收藏第二条'))!;
      });
      await harness.mount(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.android,
      );
      await tester.longPress(find.byKey(ValueKey('inbox-item-${a.item.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('touch-menu-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('select-message-${b.item.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '收藏'));
      await waitForStorage(
        tester,
        () => harness.inbox.store.favorites.length == 2,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inbox-composer')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mobile-nav-favorites')));
      await tester.pumpAndSettle();
      final favoriteA = harness.inbox.favoriteEntries.firstWhere(
        (entry) => entry.originalMessageId == a.item.id,
      );
      final favoriteB = harness.inbox.favoriteEntries.firstWhere(
        (entry) => entry.originalMessageId == b.item.id,
      );
      expect(find.byKey(ValueKey('favorite-${favoriteA.id}')), findsOneWidget);
      expect(find.byKey(ValueKey('favorite-${favoriteB.id}')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('favorite-${favoriteA.id}')));
      await tester.pumpAndSettle();
      expect(find.text('收藏详情'), findsOneWidget);
      await tester.tap(find.text('定位原消息'));
      await tester.pumpAndSettle();
      expect(find.text('返回收藏'), findsOneWidget);
      expect(find.text('手机收藏第一条'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Ctrl+A selects the conversation and Escape clears selection without deleting',
    (tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 4; i++) {
          await harness.inbox.addText('键盘选择 $i');
        }
      });
      await harness.mount(tester);
      await tester.tap(find.byTooltip('多选消息'));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('已选 4 条'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('delete-selected-messages')),
        findsNothing,
      );
      expect(harness.inbox.items.length, 4);
    },
  );
}
