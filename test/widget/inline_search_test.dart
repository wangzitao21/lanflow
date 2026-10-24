import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  void history(int count) {
    harness.inbox.store.applySnapshot({
      'revision': harness.inbox.store.revision + 1,
      'profiles': Map.of(harness.inbox.store.profiles),
      'entries': [
        for (var i = 0; i < count; i++)
          {
            'sequence': i + 1,
            'item': InboxItem(
              id: 'inline-search-message-${i.toString().padLeft(5, '0')}',
              originId: harness.lan.identity.id,
              originName: harness.lan.name,
              createdAt: DateTime.utc(2026, 10, 21).add(Duration(seconds: i)),
              kind: MessageKind.text,
              text: '搜索资料 $i',
            ).toJson(),
            'copies': <String>[],
          },
      ],
    });
  }

  testWidgets(
    'inline search coalesces typing and lazily renders 5000 results without rebuilding the chat',
    (tester) async {
      history(5000);
      await harness.mount(tester);
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(editor, '未发送的草稿');
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('global-conversation-search'));
      final inputState = tester.state(
        find.descendant(of: input, matching: find.byType(EditableText)),
      );
      final reads = (harness.inbox as WidgetInbox).statusReads;
      final chat = tester.element(
        find.byKey(const ValueKey('self-chat-history')),
      );
      await tester.tap(input);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      expect(Navigator.of(tester.element(input)).canPop(), isFalse);
      final fieldTop = tester.getTopLeft(input);
      for (final query in ['搜', '搜索', '搜索资', '搜索资料']) {
        await tester.enterText(input, query);
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(const ValueKey('search-result-count')), findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('5000 条匹配消息'), findsOneWidget);
      expect(tester.getTopLeft(input), fieldTop);
      expect(
        tester.state(
          find.descendant(of: input, matching: find.byType(EditableText)),
        ),
        same(inputState),
      );
      expect(
        tester.element(find.byKey(const ValueKey('self-chat-history'))),
        same(chat),
      );
      expect((harness.inbox as WidgetInbox).statusReads, reads);
      final results = find.byKey(const ValueKey('message-search-results'));
      expect(
        find
            .descendant(of: results, matching: find.byType(ListTile))
            .evaluate()
            .length,
        lessThan(30),
      );
      final focus = tester.widget<TextField>(input).focusNode!;
      expect(focus.hasFocus, isTrue);
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('conversation-$defaultConversationId')),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(editor).controller!.text, '未发送的草稿');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Chinese composing candidates do not replace committed search results',
    (tester) async {
      history(3);
      await harness.mount(tester);
      final input = find.byKey(const ValueKey('global-conversation-search'));
      await tester.enterText(input, '资料');
      await tester.pumpAndSettle();
      expect(find.text('3 条匹配消息'), findsOneWidget);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'zi',
          selection: TextSelection.collapsed(offset: 2),
          composing: TextRange(start: 0, end: 2),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('3 条匹配消息'), findsOneWidget);
      expect(find.text('没有找到相关消息'), findsNothing);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: '资料 1',
          selection: TextSelection.collapsed(offset: 4),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('1 条匹配消息'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('search-result-inline-search-message-00001')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('closing current search restores the original reading position', (
    tester,
  ) async {
    history(120);
    await harness.mount(tester);
    final historyView = find.byKey(const ValueKey('self-chat-history'));
    tester.widget<ListView>(historyView).controller!.jumpTo(850);
    await tester.pumpAndSettle();
    final offset = tester.widget<ListView>(historyView).controller!.offset;
    await harness.openGlobalSearch(tester);
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('global-conversation-search'));
    expect(Navigator.of(tester.element(input)).canPop(), isFalse);
    await tester.enterText(input, '资料 10');
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(
      tester.widget<ListView>(historyView).controller!.offset,
      closeTo(offset, 1),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'phone global search stays usable above the keyboard and back clears it first',
    (tester) async {
      history(30);
      await harness.mount(
        tester,
        size: const Size(320, 568),
        platform: TargetPlatform.android,
        openMobileChat: false,
      );
      final input = find.byKey(const ValueKey('global-conversation-search'));
      await tester.enterText(input, '资料 29');
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mobile-navigation')), findsNothing);
      final result = find.byKey(
        const ValueKey('search-result-inline-search-message-00029'),
      );
      expect(tester.getRect(result).center.dy, lessThan(328));
      await tester.tap(result);
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('located-message-highlight')),
        findsOneWidget,
      );
      await tester.tap(find.text('返回搜索结果'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '资料 29');
      expect(result, findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(
        find.byKey(const ValueKey('conversation-$defaultConversationId')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
