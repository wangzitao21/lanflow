import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/sync_feedback.dart';
import 'package:lanflow/ui/settings/transfer_dialog.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets(
    'file actions keep the same order on desktop and large-text phones',
    (tester) async {
      final file = File('${harness.directory.path}/shared-actions.zip');
      await tester.runAsync(() async {
        await file.writeAsString('file');
        await harness.inbox.addFile(file.path);
      });
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
        tester.platformDispatcher.textScaleFactorTestValue =
            platform == TargetPlatform.android ? 2 : 1;
        await harness.mount(
          tester,
          size: platform == TargetPlatform.android
              ? const Size(320, 640)
              : const Size(1180, 780),
          platform: platform,
        );
        final message = find.byKey(
          ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
        );
        await tester.longPress(message);
        await tester.pumpAndSettle();
        final labels = ['打开', '在文件夹中显示', '另存为', '删除'];
        for (var i = 0; i < labels.length - 1; i++) {
          expect(
            tester.getTopLeft(find.text(labels[i])).dy,
            lessThan(tester.getTopLeft(find.text(labels[i + 1])).dy),
          );
        }
        if (platform == TargetPlatform.android) {
          final menu = tester.getRect(
            find.byKey(const ValueKey('message-action-palette')),
          );
          expect(menu.left, greaterThanOrEqualTo(0));
          expect(menu.right, lessThanOrEqualTo(320));
          expect(menu.bottom, lessThanOrEqualTo(640));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  testWidgets(
    'a failed attachment does not mark unrelated or completed messages as failed',
    (tester) async {
      late InboxEntry text;
      late InboxEntry file;
      await tester.runAsync(() async {
        text = (await harness.inbox.addText('正常等待的文字'))!;
        final source = File('${harness.directory.path}/failed.zip');
        await source.writeAsString('failed file');
        file = await harness.inbox.addFile(source.path);
      });
      final id = 'f' * 32;
      final endpoint = 'device:$id';
      harness.lan.sessions[id] = PeerSession(
        receiveToken: 'a' * 43,
        sendToken: 'b' * 43,
      );
      harness.inbox.statuses[endpoint] = SyncStatus()
        ..online = true
        ..needsAttention = true
        ..error = '附件同步失败';
      harness.inbox.transferTasks = [
        TransferTask.fromJson({
          'endpoint': endpoint,
          'direction': 'upload',
          'eventId': 'failed-file-event',
          'item': file.item.toJson(),
          'transferred': 0,
          'state': 'failed',
        }),
      ];
      expect(harness.inbox.copyStatus(text), '已同步 0/1 · 等待同步');
      expect(harness.inbox.copyStatus(file), '已同步 0/1 · 同步失败，需处理');
      text.copies.add(endpoint);
      expect(harness.inbox.copyStatus(text), '已同步 1/1');
      await harness.mount(tester);
      expect(
        find.byKey(const ValueKey('sync-attention-notice')),
        findsOneWidget,
      );
      harness.lan.sessions.remove(id);
      harness.inbox.activity.value++;
      await tester.pump();
      expect(find.byKey(const ValueKey('sync-attention-notice')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('phone home and settings preserve chat drafts across navigation', (tester) async {
    await harness.mount(tester, size: const Size(320, 640), platform: TargetPlatform.android, openMobileChat: false);
    expect(find.byType(NavigationDestination), findsNWidgets(3));
    await harness.openSettingsPage(tester, 'devices');
    expect(find.textContaining('暂无附近设备'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    await harness.closeSettings(tester);
    await tester.tap(find.byKey(const ValueKey('conversation-$defaultConversationId')));
    await tester.pumpAndSettle();
    final editor = find.byKey(const ValueKey('inbox-composer'));
    await tester.tap(editor);
    await tester.pump();
    await tester.enterText(editor, '导航切换时保留的草稿');
    final file = File('${harness.directory.path}/draft.txt');
    await tester.runAsync(() async { await file.writeAsString('attachment'); await harness.inbox.stageFile(file.path); });
    await tester.pumpAndSettle();
    await harness.openSettingsPage(tester, 'transfers');
    expect(find.byType(TransferDialog), findsOneWidget);
    await harness.closeSettings(tester);
    expect(tester.widget<TextField>(editor).controller!.text, '导航切换时保留的草稿');
    expect(harness.inbox.store.draftAttachments.single.name, 'draft.txt');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'phone menus share touch targets and Back only closes the current layer',
    (tester) async {
      await tester.runAsync(() => harness.inbox.addText('统一菜单行为'));
      await harness.mount(
        tester,
        size: const Size(320, 640),
        platform: TargetPlatform.android,
        openMobileChat: false,
      );
      final row = find.byKey(
        const ValueKey('conversation-$defaultConversationId'),
      );
      final hold = await tester.startGesture(tester.getCenter(row));
      await tester.pump(const Duration(milliseconds: 351));
      expect(
        find.byKey(const ValueKey('conversation-action-palette')),
        findsOneWidget,
      );
      await hold.up();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desktop-context-menu')), findsNothing);
      expect(
        tester.getSize(find.byKey(const ValueKey('touch-menu-pin'))).height,
        greaterThanOrEqualTo(48),
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      expect(
        find.byKey(const ValueKey('conversation-action-palette')),
        findsNothing,
      );
      await tester.longPress(row);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('touch-menu-deleteConversation')),
      );
      await tester.pumpAndSettle();
      final delete = find.widgetWithText(FilledButton, '删除');
      expect(
        tester.widget<FilledButton>(delete).style!.backgroundColor!.resolve({}),
        Theme.of(tester.element(delete)).colorScheme.error,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(row, findsOneWidget);
      expect(harness.inbox.items, hasLength(1));
      await tester.tap(row);
      await tester.pumpAndSettle();
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.tap(editor);
      await tester.pump();
      await tester.enterText(editor, '仍在这里');
      final message = find.byKey(
        ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
      );
      await tester.longPress(message);
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byKey(const ValueKey('touch-menu-copy'))).height,
        greaterThanOrEqualTo(48),
      );
      expect(find.text('复制文字'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(editor, findsOneWidget);
      expect(tester.widget<TextField>(editor).controller!.text, '仍在这里');
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'selection remains distinct from a pinned custom conversation color',
    (tester) async {
      late Conversation work;
      await tester.runAsync(() async {
        work = await harness.inbox.createConversation('工作');
        await harness.inbox.setConversationPinned(work.id, true);
        await harness.inbox.setConversationBackground(work.id, 0xFFE6E0F0);
        harness.inbox.selectConversation(defaultConversationId);
      });
      for (final appearance in ['light', 'dark']) {
        harness.inbox.appearance.value = appearance;
        await harness.mount(tester);
        expect(
          find.byKey(
            const ValueKey('selected-conversation-$defaultConversationId'),
          ),
          findsOneWidget,
        );
        final row = find.byKey(ValueKey('conversation-${work.id}'));
        await tester.tap(row);
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey('selected-conversation-${work.id}')),
          findsOneWidget,
        );
        expect(
          find.byKey(
            const ValueKey('selected-conversation-$defaultConversationId'),
          ),
          findsNothing,
        );
        expect(harness.inbox.store.preference(work.id).background, 0xFFE6E0F0);
        expect(harness.inbox.store.preference(work.id).pinnedAt, isNotNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        harness.inbox.selectConversation(defaultConversationId);
      }
    },
  );

  testWidgets(
    'online failures stay visible without changing connection labels or leaking errors',
    (tester) async {
      late InboxEntry entry;
      await tester.runAsync(() async {
        entry = (await harness.inbox.addText('本机内容仍然可用'))!;
      });
      final id = 'e' * 32;
      final endpoint = 'device:$id';
      harness.lan.sessions[id] = PeerSession(
        receiveToken: 'a' * 43,
        sendToken: 'b' * 43,
      );
      final status = harness.inbox.statuses[endpoint] = SyncStatus()
        ..online = true
        ..needsAttention = true
        ..error = 'FileSystemException: /private/device/store.sqlite';
      await harness.mount(tester);
      expect(find.text('1/1 台在线'), findsOneWidget);
      expect(find.text('已同步 0/1 · 同步失败，需处理'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('sync-attention-notice')),
        findsOneWidget,
      );
      final editor = tester.widget<TextField>(
        find.byKey(const ValueKey('inbox-composer')),
      );
      for (final busy in [true, false]) {
        status.busy = busy;
        harness.inbox.activity.value++;
        await tester.pump();
        expect(
          find.byKey(const ValueKey('sync-attention-notice')),
          findsOneWidget,
        );
        expect(
          tester.widget<TextField>(
            find.byKey(const ValueKey('inbox-composer')),
          ),
          same(editor),
        );
      }
      await tester.tap(find.byKey(const ValueKey('open-sync-problems')));
      await tester.pumpAndSettle();
      expect(find.byType(SyncIssuesPanel), findsOneWidget);
      expect(find.textContaining('/private/device'), findsNothing);
      // A binding without a reachable address must not claim that retry succeeded.
      await tester.tap(find.byKey(ValueKey('retry-sync-$endpoint')));
      await tester.pumpAndSettle();
      expect(find.text('设备离线'), findsOneWidget);
      expect(status.needsAttention, isTrue);
      expect(harness.inbox.store.find(entry.item.id), isNotNull);
      status.needsAttention = false;
      status.error = null;
      entry.copies.add(endpoint);
      harness.inbox.activity.value++;
      await tester.pumpAndSettle();
      expect(find.text('暂无需要处理的同步异常'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('sync-attention-notice')), findsNothing);
      expect(find.text('已同步 1/1'), findsOneWidget);
      status.online = false;
      status.error = '设备离线';
      harness.inbox.activity.value++;
      await tester.pump();
      expect(find.byKey(const ValueKey('sync-attention-notice')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
