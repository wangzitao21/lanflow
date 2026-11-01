import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/platform/native_core.dart';
import 'package:lanflow/ui/settings/conversation_recovery_panel.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import '../support/widget_harness.dart';
import 'message_selection_test.dart' show waitForStorage;

void main() {
  final harness = WidgetTestHarness();
  testWidgets(
    'pending recovery opens a destination picker and keeps same-name chats separate',
    (tester) async {
      late Conversation old, target;
      late InboxEntry pending;
      await tester.runAsync(() async {
        old = await harness.inbox.createConversation('工作');
        pending = (await harness.inbox.addText('离线新增内容'))!;
        final result = await NativeCore.run({
          'op': 'apply',
          'root': harness.directory.path,
          'knownRevision': harness.inbox.store.revision,
          'event': {
            'id': 'remote-close-event-123',
            'type': 'conversation',
            'conversation': {
              'id': old.id,
              'name': old.name,
              'revision': 9000000000000000,
              'deleted': true,
            },
          },
        });
        harness.inbox.store.applySnapshot(
          Map<String, dynamic>.from(result as Map),
        );
        target = await harness.inbox.createConversation('工作');
      });
      await harness.mount(tester);
      expect(find.byKey(ValueKey('conversation-${old.id}')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('open-pending-recovery')));
      await waitForStorage(
        tester,
        () => find.text('离线新增内容').evaluate().isNotEmpty,
      );
      await tester.tap(
        find.byKey(ValueKey('recover-message-${pending.item.id}')),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('recovery-target-${old.id}')), findsNothing);
      await tester.tap(find.byKey(ValueKey('recovery-target-${target.id}')));
      await tester.tap(find.byKey(const ValueKey('confirm-recovery-target')));
      await waitForStorage(
        tester,
        () =>
            harness.inbox.store.recoveryCount == 0 &&
            find.text('暂无待恢复内容').evaluate().isNotEmpty,
      );
      expect(harness.inbox.items.single.item.conversationId, target.id);
      expect(
        harness.inbox.conversations.where((c) => c.name == '工作').length,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('recovery panel fits a phone screen and has an empty state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppRoot(
        home: Scaffold(body: ConversationRecoveryPanel(inbox: harness.inbox)),
      ),
    );
    await waitForStorage(
      tester,
      () => find.text('暂无待恢复内容').evaluate().isNotEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}
