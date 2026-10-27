import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();
  testWidgets('deleted source content disappears from its quoted preview', (
    tester,
  ) async {
    late InboxEntry original, reply;
    await tester.runAsync(() async {
      original = (await harness.inbox.addText('source text to remove'))!;
      reply = (await harness.inbox.addText(
        'reply stays',
        quote: MessageQuote.fromItem(original.item),
      ))!;
    });
    await harness.mount(tester);
    await tester.runAsync(() => harness.inbox.deleteItem(original.item));
    await tester.pumpAndSettle();
    final quote = find.byKey(ValueKey('message-quote-${original.item.id}'));
    expect(
      find.descendant(
        of: quote,
        matching: find.textContaining('source text to remove'),
      ),
      findsNothing,
    );
    expect(
      find.descendant(of: quote, matching: find.textContaining('原消息已删除')),
      findsOneWidget,
    );
    expect(harness.inbox.store.find(reply.item.id), isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets(
    'Ctrl Enter replaces the selected text with a newline without sending',
    (tester) async {
      await harness.mount(tester);
      final field = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(field, 'first REPLACE last');
      final controller = tester.widget<TextField>(field).controller!;
      controller.selection = const TextSelection(
        baseOffset: 6,
        extentOffset: 13,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.text, 'first \n last');
      expect(harness.inbox.items, isEmpty);
      expect(controller.selection.baseOffset, 7);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('retrying an offline device keeps the same quiet pending badge', (
    tester,
  ) async {
    late InboxEntry item;
    await tester.runAsync(
      () async => item = (await harness.inbox.addText('quiet message'))!,
    );
    final id = 'a' * 32, key = 'device:${'a' * 32}';
    harness.lan.sessions[id] = PeerSession(
      sendToken: 'b' * 43,
      receiveToken: 'c' * 43,
    );
    final status = harness.inbox.statuses[key] = SyncStatus();
    await harness.mount(tester);
    final label = find.byKey(ValueKey('copy-status-${item.item.id}'));
    for (final busy in [true, false, true, false]) {
      status
        ..busy = busy
        ..online = false
        ..error = '设备离线';
      harness.inbox.activity.value++;
      await tester.pump();
      expect(
        find.descendant(
          of: label,
          matching: find.byIcon(Icons.priority_high_rounded),
        ),
        findsOneWidget,
      );
      expect(find.text('消息详情'), findsNothing);
      expect(find.textContaining('等待设备上线'), findsNothing);
      expect(find.text('同步中'), findsNothing);
      expect(find.text('已绑定 1 台设备'), findsNWidgets(2));
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
