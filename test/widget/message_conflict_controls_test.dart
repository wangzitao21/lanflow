import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/sync_feedback.dart';
import 'package:lanflow/ui/devices/sync_connection_editor.dart';
import 'package:lanflow/ui/settings/transfer_dialog.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();
  Future<MessageConflict> conflict(WidgetTester tester) async {
    late MessageConflict value;
    await tester.runAsync(() async {
      final entry = (await harness.inbox.addText('original'))!;
      for (final choice in ['A', 'B']) {
        await harness.inbox.store.applyChange({
          'id': 'conflict-version-$choice',
          'type': 'edit',
          'target': entry.item.id,
          'revision': 100,
          'parents': <String>[],
          'text': 'Version $choice',
          'name': '',
          'editorId': choice == 'A' ? 'a' * 32 : 'b' * 32,
          'editorName': 'Device $choice',
          'editedAt': '2026-10-26T00:00:00Z',
        });
      }
      value = harness.inbox.syncProblems.single;
    });
    return value;
  }

  Future<void> openIssues(WidgetTester tester, {bool mobile = false}) async {
    await harness.mount(
      tester,
      size: mobile ? const Size(360, 740) : const Size(1180, 780),
      platform: mobile ? TargetPlatform.android : TargetPlatform.windows,
    );
    expect(find.byKey(const ValueKey('sync-attention-notice')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('open-sync-problems')));
    await tester.pumpAndSettle();
    expect(find.byType(SyncIssuesPanel), findsOneWidget);
  }

  testWidgets('a user can inspect both versions and keep either one', (
    tester,
  ) async {
    final value = await conflict(tester);
    await openIssues(tester);
    expect(
      find.descendant(
        of: find.byType(SyncIssuesPanel),
        matching: find.text('Version A'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(SyncIssuesPanel),
        matching: find.text('Version B'),
      ),
      findsOneWidget,
    );
    final use = find.byKey(const ValueKey('use-version-conflict-version-A'));
    await tester.ensureVisible(use);
    await tester.tap(use);
    await tester.runAsync(
      () => harness.waitFor(() => harness.inbox.syncProblems.isEmpty),
    );
    await tester.pumpAndSettle();
    expect(harness.inbox.store.find(value.id)!.item.text, 'Version A');
    expect(find.text('暂无消息版本冲突'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'editing a version saves the user result on a narrow phone screen',
    (tester) async {
      final value = await conflict(tester);
      await openIssues(tester, mobile: true);
      final edit = find.byKey(
        const ValueKey('edit-version-conflict-version-B'),
      );
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('conflict-edit-text')),
        'User combined version',
      );
      await tester.tap(find.byKey(const ValueKey('save-conflict-edit')));
      await tester.runAsync(
        () => harness.waitFor(() => harness.inbox.syncProblems.isEmpty),
      );
      await tester.pumpAndSettle();
      expect(
        harness.inbox.store.find(value.id)!.item.text,
        'User combined version',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a new remote version rejects a stale choice without losing edited text',
    (tester) async {
      final value = await conflict(tester);
      await openIssues(tester);
      final edit = find.byKey(
        const ValueKey('edit-version-conflict-version-B'),
      );
      await tester.ensureVisible(edit);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('conflict-edit-text'));
      await tester.enterText(input, 'Uncommitted user text');
      await tester.runAsync(
        () => harness.inbox.store.applyChange({
          'id': 'conflict-version-C',
          'type': 'edit',
          'target': value.id,
          'revision': 101,
          'parents': <String>[],
          'text': 'Version C',
          'name': '',
        }),
      );
      await tester.tap(find.byKey(const ValueKey('save-conflict-edit')));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('冲突版本已更新，请重新查看后选择'), findsOneWidget);
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Uncommitted user text',
      );
      expect(harness.inbox.syncProblems.single.versions, hasLength(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'deleting all versions requires confirmation and clears the issue',
    (tester) async {
      final value = await conflict(tester);
      await openIssues(tester);
      final remove = find.byKey(ValueKey('delete-conflict-${value.id}'));
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(harness.inbox.syncProblems, hasLength(1));
      await tester.tap(remove);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '删除所有版本'));
      await tester.runAsync(
        () => harness.waitFor(() => harness.inbox.syncProblems.isEmpty),
      );
      await tester.pumpAndSettle();
      expect(harness.inbox.store.find(value.id), isNull);
      expect(find.text('暂无消息版本冲突'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'NAS settings are editable offline and removable without deleting messages',
    (tester) async {
      final hub = SyncEndpoint(
        id: 'nas-widget-settings',
        name: 'Old NAS',
        url: Uri.parse('https://192.168.8.10:53320'),
        fingerprint: 'a' * 64,
        token: 'b' * 43,
        isHub: true,
      );
      harness.inbox.store.hubs.add(hub);
      await tester.runAsync(() => harness.inbox.addText('Keep local content'));
      await harness.mount(tester);
      final context = tester.element(find.byType(Scaffold).first);
      showSyncConnectionEditor(
        context,
        harness.inbox,
        SyncTarget(hub.key, hub.name, isHub: true),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('sync-connection-name')),
        'New NAS',
      );
      await tester.enterText(
        find.byKey(const ValueKey('sync-connection-address')),
        '192.168.8.20:53320',
      );
      await tester.runAsync(() async {
        await Function.apply(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('save-sync-connection')),
              )
              .onPressed!,
          [],
        );
      });
      await tester.pumpAndSettle();
      expect(harness.inbox.store.hubs.single.url.host, '192.168.8.20');
      showSyncConnectionEditor(
        context,
        harness.inbox,
        SyncTarget(hub.key, 'New NAS', isHub: true),
      );
      await tester.pumpAndSettle();
      final remove = find.byKey(const ValueKey('remove-sync-connection'));
      await tester.ensureVisible(remove);
      await tester.runAsync(() => tester.tap(remove));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '移除连接'));
        await harness.waitFor(() => harness.inbox.store.hubs.isEmpty);
      });
      await tester.pumpAndSettle();
      expect(harness.inbox.items.single.item.text, 'Keep local content');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'transfer removal has an explicit confirmation and retains the message',
    (tester) async {
      late InboxEntry entry;
      await tester.runAsync(() async {
        final file = File('${harness.directory.path}/kept.bin');
        await file.writeAsBytes([1, 2, 3]);
        entry = await harness.inbox.addFile(file.path);
        final port = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final unusedPort = port.port;
        await port.close();
        final id = 'd' * 32;
        harness.lan.peers[id] = Peer(
          id: id,
          name: 'Offline device',
          platform: 'windows',
          address: '127.0.0.1',
          port: unusedPort,
          fingerprint: 'd' * 64,
          inboxVersion: 3,
        );
        harness.lan.sessions[id] = PeerSession(
          sendToken: 'a' * 43,
          receiveToken: 'b' * 43,
        );
        await harness.inbox.syncNow();
      });
      final task = harness.inbox.transferTasks.single;
      await tester.pumpWidget(
        AppRoot(
          home: Scaffold(body: TransferDialog(inbox: harness.inbox)),
        ),
      );
      await tester.pumpAndSettle();
      final remove = find.byKey(ValueKey('delete-transfer-${task.key}'));
      await tester.ensureVisible(remove);
      await tester.runAsync(() => tester.tap(remove));
      await tester.pumpAndSettle();
      expect(find.text('删除传输任务？'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '删除任务'));
        await harness.waitFor(() => harness.inbox.transferTasks.isEmpty);
      });
      await tester.pumpAndSettle();
      expect(harness.inbox.store.find(entry.item.id), isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
