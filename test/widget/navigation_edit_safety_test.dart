import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/models.dart';

import '../support/widget_harness.dart';

class _EditableInbox extends WidgetInbox {
  _EditableInbox({required super.lan, required super.store});
  Object? renameFailure;
  Completer<void>? renameGate;
  int renameAttempts = 0;

  void publishIncoming() => notifyListeners();

  @override
  Future<void> renameConversation(String id, String name) async {
    renameAttempts++;
    if (renameFailure != null) throw renameFailure!;
    await renameGate?.future;
    await super.renameConversation(id, name);
  }
}

void main() {
  final harness = WidgetTestHarness();

  Future<_EditableInbox> editableInbox(WidgetTester tester) async {
    late _EditableInbox result;
    await tester.runAsync(() async {
      await harness.inbox.close();
      harness.inbox.dispose();
      result = _EditableInbox(
        lan: harness.lan,
        store: InboxStore(harness.directory),
      );
      harness.inbox = result;
      await result.start();
    });
    return result;
  }

  for (final destination in [
    'favorites',
    'devices',
    'transfers',
    'search',
    'conversation',
  ]) {
    testWidgets(
      'leaving multi-select for $destination keeps newly arrived messages unread',
      (tester) async {
        final inbox = await editableInbox(tester);
        late Conversation other;
        await tester.runAsync(() async {
          await inbox.addText('Existing message');
          other = await inbox.createConversation('Other conversation');
          inbox.selectConversation(defaultConversationId);
        });
        await harness.mount(tester);
        await tester.tap(find.byTooltip('多选消息'));
        await tester.pumpAndSettle();
        expect(inbox.readingConversation, isNull);
        await tester.runAsync(() async {
          await inbox.store.add(
            InboxItem(
              id: randomToken(18),
              originId: 'b' * 32,
              originName: 'Remote',
              createdAt: DateTime.now().toUtc(),
              kind: MessageKind.text,
              text: 'Unread while selecting',
            ),
          );
          inbox.publishIncoming();
        });
        await tester.pumpAndSettle();
        expect(inbox.unreadCount(defaultConversationId), 1);
        if (destination == 'search') {
          await harness.openGlobalSearch(tester);
        } else if (destination == 'conversation') {
          await tester.tap(find.byKey(ValueKey('conversation-${other.id}')));
        } else if (destination == 'devices' || destination == 'transfers') {
          await harness.openSettingsPage(tester, destination);
        } else {
          await tester.tap(find.byKey(ValueKey('desktop-nav-$destination')));
        }
        await tester.pumpAndSettle();
        expect(inbox.unreadCount(defaultConversationId), 1);
        expect(inbox.readingConversation, isNot(defaultConversationId));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'failed inline title remains editable and close waits for a successful retry',
    (tester) async {
      final inbox = await editableInbox(tester);
      late Conversation conversation;
      await tester.runAsync(() async {
        conversation = await inbox.createConversation('Original title');
      });
      await harness.mount(tester);
      await tester.tapAt(
        tester.getCenter(
          find.byKey(ValueKey('conversation-${conversation.id}')),
        ),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-menu-rename')));
      await tester.pumpAndSettle();
      final name = find.byKey(const ValueKey('conversation-name'));
      await tester.enterText(name, 'Keep this pending title');
      inbox.renameFailure = StateError('injected title save failure');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(inbox.conversation.name, 'Original title');
      expect(
        tester.widget<TextField>(name).controller!.text,
        'Keep this pending title',
      );
      await tester.runAsync(() async {
        await expectLater(inbox.close(), throwsStateError);
      });
      await tester.pumpAndSettle();
      expect(inbox.store.loaded, isTrue);
      expect(
        tester.widget<TextField>(name).controller!.text,
        'Keep this pending title',
      );
      inbox.renameFailure = null;
      final gate = inbox.renameGate = Completer<void>();
      var finished = false;
      Object? failure;
      await tester.runAsync(() async {
        unawaited(
          inbox.close().then(
            (_) => finished = true,
            onError: (Object error) {
              failure = error;
              finished = true;
            },
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(finished, isFalse);
      expect(inbox.store.loaded, isTrue);
      gate.complete();
      await tester.runAsync(() => harness.waitFor(() => finished));
      await tester.pumpAndSettle();
      expect(failure, isNull);
      expect(inbox.store.loaded, isFalse);
      await tester.runAsync(() async {
        final reopened = InboxStore(harness.directory);
        await reopened.load();
        expect(
          reopened.conversations[conversation.id]!.name,
          'Keep this pending title',
        );
        await reopened.close();
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
