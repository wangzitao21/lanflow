import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  for (final section in ['favorites', 'trash']) {
    testWidgets('hidden Android chat stays unread after rotating $section', (
      tester,
    ) async {
      await harness.mount(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.android,
        openMobileChat: false,
      );
      await tester.tap(find.byKey(ValueKey('mobile-nav-$section')));
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pumpAndSettle();
      expect(harness.inbox.readingConversation, isNull);
      tester.view.physicalSize = const Size(1000, 780);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inbox-composer')), findsNothing);
      expect(harness.inbox.readingConversation, isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(harness.inbox.readingConversation, defaultConversationId);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('text editing shortcuts do not act on selected messages', (
    tester,
  ) async {
    late InboxEntry entry;
    await tester.runAsync(() async {
      entry = (await harness.inbox.addText('Message to keep'))!;
      await harness.inbox.addText('Another message');
    });
    await harness.mount(tester);
    await tester.tap(find.byTooltip('多选消息'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('select-message-${entry.item.id}')));
    final search = find.byKey(const ValueKey('global-conversation-search'));
    await tester.enterText(search, 'query');
    await tester.pumpAndSettle();
    final input = tester.widget<TextField>(search);
    expect(input.focusNode!.hasFocus, isTrue);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(input.controller!.selection.start, 0);
    expect(input.controller!.selection.end, 5);
    expect(find.text('已选 1 条'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pumpAndSettle();
    expect(find.text('删除 1 条消息？'), findsNothing);
    expect(harness.inbox.items, hasLength(2));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
