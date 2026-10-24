import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/devices/device_dialogs.dart';
import 'package:lanflow/ui/settings/storage_dialog.dart';
import 'package:lanflow/ui/settings/recently_deleted_panel.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets('raw errors stay out of banners, devices and transfer tasks', (
    tester,
  ) async {
    const raw = 'FileSystemException: /private/device/store.sqlite (errno 13)';
    await tester.runAsync(() => harness.inbox.addText('保留聊天内容'));
    final hub = SyncEndpoint(
      id: 'a' * 32,
      name: '家里 NAS',
      url: Uri.parse('https://127.0.0.1:53320'),
      fingerprint: 'a' * 64,
      token: 'a' * 43,
      isHub: true,
    );
    harness.inbox.store.hubs.add(hub);
    harness.inbox.statuses[hub.key] = SyncStatus()
      ..needsAttention = true
      ..error = raw;
    harness.inbox.error = '草稿保存失败：$raw';
    await harness.mount(tester);
    expect(find.text('草稿未保存，请重试'), findsOneWidget);
    expect(find.textContaining('/private/device'), findsNothing);

    await tester.tap(find.byTooltip('我的设备').last);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(DevicePanel),
        matching: find.textContaining('同步失败'),
      ),
      findsNothing,
    );
    expect(find.textContaining('离线'), findsOneWidget);
    expect(find.textContaining('/private/device'), findsNothing);
    await harness.closeSettings(tester);

    (harness.inbox as WidgetInbox).freezeTransfers = true;
    harness.inbox.transferTasks = [
      TransferTask.fromJson({
        'endpoint': hub.key,
        'direction': 'upload',
        'eventId': 'failed-transfer',
        'item': harness.inbox.items.single.item.toJson(),
        'transferred': 0,
        'state': 'failed',
        'error': raw,
      }),
    ];
    await harness.openSettingsPage(tester, 'transfers');
    await tester.pumpAndSettle();
    expect(find.text('传输失败，请重试'), findsOneWidget);
    expect(find.textContaining('/private/device'), findsNothing);
    expect(find.text('重试').last, findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'transfer activity updates its controls without rebuilding the editor',
    (tester) async {
      await tester.runAsync(() => harness.inbox.addText('进度不影响正在编辑的内容'));
      await harness.mount(tester);
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(editor, '尚未发送的草稿');
      await tester.pump();
      final editorWidget = tester.widget<TextField>(editor);
      final history = tester.widget(
        find.byKey(const ValueKey('self-chat-history')),
      );
      harness.inbox.transferTasks = [
        TransferTask.fromJson({
          'endpoint': 'device:local-test',
          'direction': 'upload',
          'eventId': 'activity-test-event',
          'item': harness.inbox.items.single.item.toJson(),
          'transferred': 20,
          'state': 'queued',
        }),
      ];
      harness.inbox.activity.value++;
      await tester.pump();
      expect(tester.widget<TextField>(editor), same(editorWidget));
      expect(
        tester.widget(find.byKey(const ValueKey('self-chat-history'))),
        same(history),
      );
      expect(find.byKey(const ValueKey('desktop-nav-transfers')), findsNothing);
      expect(editorWidget.controller!.text, '尚未发送的草稿');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'desktop settings keeps one fixed frame and preserves edits across sections',
    (tester) async {
      await harness.mount(tester);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final frame = tester.getRect(find.byType(AlertDialog));
      await tester.tap(find.text('编辑设备名称与头像'));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(AlertDialog)), frame);
      final name = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '设备名称',
      );
      await tester.enterText(name, '尚未保存的设备名称');
      await tester.tap(find.text('偏好设置').first);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(const ValueKey('appearance-system')), findsOneWidget);
      expect(tester.getRect(find.byType(AlertDialog)), frame);
      await tester.tap(find.text('设备资料').first);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(tester.widget<TextField>(name).controller!.text, '尚未保存的设备名称');
      expect(harness.lan.name, '我的 Windows');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('appearance-system')), findsOneWidget);
      expect(tester.getRect(find.byType(AlertDialog)), frame);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'linked deletion is configurable and the main recycle bin restores each copy independently',
    (tester) async {
      late String messageId, favoriteId;
      await tester.runAsync(() async {
        final entry = await harness.inbox.addText('两份内容分别恢复');
        messageId = entry!.item.id;
        await harness.inbox.setFavorites([messageId], true);
        favoriteId = harness.inbox.favoriteEntries.single.id;
      });
      expect(harness.inbox.linkFavoriteDeletion, isFalse);
      await harness.mount(tester);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(const ValueKey('link-favorite-deletion'));
      await tester.scrollUntilVisible(
        toggle,
        120,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey('preferences-form')),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.tap(toggle);
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        if (harness.inbox.linkFavoriteDeletion) break;
      }
      await tester.pumpAndSettle();
      expect(harness.inbox.linkFavoriteDeletion, isTrue);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => harness.inbox.deleteFavorites([favoriteId]));
      expect(harness.inbox.items, isEmpty);
      expect(harness.inbox.favoriteEntries, isEmpty);
      await tester.tap(find.byKey(const ValueKey('desktop-nav-trash')));
      Future<void> waitForRestore(String id) async {
        for (var i = 0; i < 100; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
          if (find.byKey(ValueKey('restore-$id')).evaluate().isNotEmpty) break;
        }
        await tester.pumpAndSettle();
      }

      await waitForRestore(favoriteId);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(ValueKey('restore-$messageId')), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('restore-$favoriteId')));
      for (var i = 0; i < 100 && harness.inbox.favoriteEntries.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(harness.inbox.favoriteEntries, hasLength(1));
      expect(harness.inbox.items, isEmpty);
      expect(find.text('已恢复到收藏'), findsOneWidget);
      await waitForRestore(messageId);
      await tester.tap(find.byKey(ValueKey('restore-$messageId')));
      for (var i = 0; i < 100 && harness.inbox.items.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(harness.inbox.items.single.item.text, '两份内容分别恢复');
      expect(harness.inbox.favoriteEntries, hasLength(1));
      expect(find.text('已恢复到原会话'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'storage controls restore deleted content and preserve original attachments',
    (tester) async {
      late InboxItem item;
      await tester.runAsync(() async {
        final file = File('${harness.directory.path}/keep.bin');
        await file.writeAsBytes([1, 2, 3, 4, 5]);
        item = (await harness.inbox.addFile(file.path)).item;
        await harness.inbox.store.fileForOpening(item);
        await harness.inbox.deleteItem(item);
      });
      await harness.mount(tester);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('存储管理'));
      await tester.tap(find.text('存储管理'));
      await tester.pump();
      for (
        var i = 0;
        i < 100 && find.textContaining('本机占用').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byType(StorageDialog), findsOneWidget);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('清理缓存'),
        160,
        scrollable: find
            .descendant(
              of: find.byType(StorageDialog),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('清理缓存'));
      for (var i = 0; i < 150 && find.text('缓存已清理').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(
        find.text('缓存已清理'),
        findsOneWidget,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join(' | '),
      );
      expect(find.byKey(ValueKey('restore-${item.id}')), findsNothing);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-nav-trash')));
      for (
        var i = 0;
        i < 100 &&
            find.byKey(ValueKey('restore-${item.id}')).evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.byType(RecentlyDeletedPanel), findsOneWidget);
      expect(find.byType(StorageDialog), findsNothing);
      await tester.ensureVisible(find.byKey(ValueKey('restore-${item.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('restore-${item.id}')));
      for (var i = 0; i < 150 && find.text('已恢复到原会话').evaluate().isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(harness.inbox.items.single.item.id, isNot(item.id));
      await tester.runAsync(() async {
        expect(await harness.inbox.store.blob(item.digest).readAsBytes(), [
          1,
          2,
          3,
          4,
          5,
        ]);
        expect((await harness.inbox.store.storageStats())['cache'], 0);
      });
      expect(tester.takeException(), isNull);
    },
  );
}
