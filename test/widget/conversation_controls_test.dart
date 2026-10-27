import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();
  testWidgets('conversation menu preserves pins and unread marks without background colors', (
    tester,
  ) async {
    late Conversation work;
    await tester.runAsync(() async {
      work = await harness.inbox.createConversation('工作');
      await harness.inbox.addText('报销凭证');
      harness.inbox.selectConversation(defaultConversationId);
    });
    await harness.mount(tester);
    final row = find.byKey(ValueKey('conversation-${work.id}'));
    Future<void> menu() async {
      await tester.tapAt(tester.getCenter(row), buttons: kSecondaryMouseButton);
      await tester.pumpAndSettle();
    }

    Future<void> choose(String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pumpAndSettle();
    }

    await menu();
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('标为未读'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    await choose('置顶');
    expect(harness.inbox.conversations.first.id, work.id);
    await menu();
    expect(find.text('取消置顶'), findsOneWidget);
    await choose('标为未读');
    expect(find.byKey(ValueKey('unread-${work.id}')), findsOneWidget);
    await menu();
    expect(find.text('标为已读'), findsOneWidget);
    expect(find.text('会话背景颜色'), findsNothing);
    await tester.tapAt(const Offset(1170,760));
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('unread-${work.id}')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'the top search finds content across conversations and opens matching messages',
    (tester) async {
      late Conversation work;
      late InboxEntry result;
      await tester.runAsync(() async {
        await harness.inbox.addText('周末旅行照片');
        work = await harness.inbox.createConversation('工作');
        result = (await harness.inbox.addText('报销凭证 2026'))!;
        await harness.inbox.addText('无关内容');
        harness.inbox.selectConversation(defaultConversationId);
      });
      await harness.mount(tester);
      expect(find.text('LanFlow'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('global-conversation-search')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('global-conversation-search')),
        '报销',
      );
      await tester.pumpAndSettle();
      expect(find.text('范围：全部会话'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('search-result-${result.item.id}')));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('located-message-history')),
          matching: find.text('报销凭证 2026'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('located-message-history')),
          matching: find.text('无关内容'),
        ),
        findsOneWidget,
      );
      expect(harness.inbox.conversationId, work.id);
      expect(
        find.byKey(const ValueKey('located-message-highlight')),
        findsOneWidget,
      );
      expect(find.byTooltip('新建会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
