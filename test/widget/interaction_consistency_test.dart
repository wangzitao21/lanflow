import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/sync_details.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets(
    'Windows resize preserves conversation, selection, menu and Enter behavior',
    (tester) async {
      await tester.runAsync(() => harness.inbox.addText('可选择的消息文字'));
      await harness.mount(tester);
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(editor, '缩窄窗口后继续编辑');
      tester.view.physicalSize = const Size(760, 700);
      await tester.pumpAndSettle();
      expect(editor, findsOneWidget);
      expect(tester.widget<TextField>(editor).controller!.text, '缩窄窗口后继续编辑');
      expect(find.byType(SelectionArea), findsOneWidget);
      final bubble = find.byKey(
        ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
      );
      await tester.tapAt(
        tester.getCenter(bubble),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-context-menu')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('message-action-palette')),
        findsNothing,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.tap(editor);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(tester.widget<TextField>(editor).controller!.text, contains('\n'));
      expect(harness.inbox.items, hasLength(1));
      await tester.runAsync(() async {
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await harness.waitFor(() => harness.inbox.items.length == 2);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'appearance applies immediately; profile cancel discards only profile edits',
    (tester) async {
      await harness.mount(tester);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, '取消'), findsNothing);
      await tester.runAsync(() async {
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('appearance-dark')))
            .onSelected!(true);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑设备名称与头像'));
      await tester.pumpAndSettle();
      final name = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '设备名称',
      );
      await tester.enterText(name, '不应保存的名称');
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(harness.lan.name, '我的 Windows');
      expect(harness.inbox.appearance.value, 'dark');
      await tester.tap(find.text('编辑设备名称与头像'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(name).controller!.text, '我的 Windows');
      await tester.enterText(name, '已保存的设备');
      await tester.runAsync(() async {
        await Function.apply(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
              .onPressed!,
          [],
        );
      });
      await tester.pumpAndSettle();
      expect(harness.lan.name, '已保存的设备');
      await tester.tap(find.text('偏好设置').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-panel')), findsNothing);
      await tester.runAsync(() async {
        final reopened = InboxStore(harness.inbox.store.directory);
        await reopened.load();
        expect(reopened.appearance, 'dark');
        expect(reopened.profiles[harness.lan.identity.id]?['name'], '已保存的设备');
        await reopened.close();
      });
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'picked files stay local drafts, can be removed and send only on Send',
    (tester) async {
      final first = File('${harness.directory.path}/first.txt');
      final second = File('${harness.directory.path}/second.mp4');
      await tester.runAsync(() async {
        await first.writeAsString('text attachment');
        await second.writeAsBytes([1, 2, 3, 4]);
      });
      const channel = MethodChannel('plugins.flutter.io/file_selector');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => [first.path, second.path],
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await harness.mount(tester);
      await tester.runAsync(() async {
        await Function.apply(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (w) => w is IconButton && w.tooltip == '添加文件',
                ),
              )
              .onPressed!,
          [],
        );
      });
      await tester.pumpAndSettle();
      expect(harness.inbox.items, isEmpty);
      expect(harness.inbox.store.draftAttachments, hasLength(2));
      expect(find.text('待发送 · 2 个附件'), findsOneWidget);
      final draft = harness.inbox.store.draftAttachments.first;
      await tester.runAsync(() async {
        await Function.apply(
          tester
              .widget<IconButton>(
                find.byKey(ValueKey('draft-remove-${draft.id}')),
              )
              .onPressed!,
          [],
        );
        await first.delete();
        await second.delete();
      });
      await tester.pumpAndSettle();
      expect(harness.inbox.items, isEmpty);
      expect(harness.inbox.store.draftAttachments.single.name, 'second.mp4');
      await tester.runAsync(() async {
        await Function.apply(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
              .onPressed!,
          [],
        );
      });
      await tester.pumpAndSettle();
      expect(harness.inbox.items.single.item.name, 'second.mp4');
      expect(harness.inbox.store.draftAttachments, isEmpty);
      await tester.runAsync(() async {
        expect(
          await harness.inbox.store
              .blob(harness.inbox.items.single.item.digest)
              .readAsBytes(),
          [1, 2, 3, 4],
        );
      });
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'attachment drafts survive restart and retry after a partially committed send',
    () async {
      final conversation = await harness.inbox.createConversation('待整理');
      final source = File('${harness.directory.path}/durable.bin');
      await source.writeAsBytes([4, 5, 6]);
      await harness.inbox.stageFile(source.path);
      await source.delete();
      expect(harness.inbox.items, isEmpty);
      final reopened = InboxStore(harness.inbox.store.directory);
      await reopened.load();
      expect(reopened.draftAttachments.single.conversationId, conversation.id);
      expect(
        await reopened
            .blob(reopened.draftAttachments.single.digest)
            .readAsBytes(),
        [4, 5, 6],
      );
      // Simulate a successful message commit before the draft removal was saved.
      final draft = harness.inbox.store.draftAttachments.single;
      await harness.inbox.store.add(draft);
      await harness.inbox.sendDraftAttachments();
      await harness.inbox.sendDraftAttachments();
      expect(harness.inbox.items, hasLength(1));
      expect(harness.inbox.store.draftAttachments, isEmpty);
      await reopened.close();
    },
  );

  testWidgets('sync status counts every bound target and details remain live', (
    tester,
  ) async {
    late InboxEntry entry;
    await tester.runAsync(() async {
      entry = (await harness.inbox.addText('查看每台设备的状态'))!;
    });
    expect(harness.inbox.copyStatus(entry), '已保存到本机');
    final hub = SyncEndpoint(
      id: 'a' * 32,
      name: '家里 NAS',
      url: Uri.parse('https://127.0.0.1:53320'),
      fingerprint: 'a' * 64,
      token: 'a' * 43,
      isHub: true,
    );
    final peerId = 'b' * 32;
    harness.inbox.store.hubs.add(hub);
    harness.lan.sessions[peerId] = PeerSession(
      receiveToken: 'b' * 43,
      sendToken: 'c' * 43,
    );
    entry.copies.add(hub.key);
    expect(harness.inbox.copyStatus(entry), '已同步 1/2 · 等待设备上线');
    harness.inbox.statuses['device:$peerId'] = SyncStatus()
      ..online = true
      ..needsAttention = true
      ..error = '同步元数据失败';
    expect(harness.inbox.copyStatus(entry), '已同步 1/2 · 同步失败，需处理');
    harness.inbox.statuses['device:$peerId'] = SyncStatus()
      ..online = true
      ..busy = true;
    await harness.mount(tester);
    expect(find.text('已同步 1/2 · 同步中'), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('copy-status-${entry.item.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(SyncDetails), findsOneWidget);
    expect(find.text('家里 NAS'), findsOneWidget);
    expect(find.text('已绑定设备'), findsOneWidget);
    expect(find.text('已同步'), findsOneWidget);
    harness.inbox.statuses['device:$peerId']!
      ..busy = false
      ..online = false
      ..needsAttention = true
      ..error = '连接已失效，请重新配对';
    harness.inbox.activity.value++;
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(SyncDetails),
        matching: find.text('等待处理'),
      ),
      findsOneWidget,
    );
    expect(find.text('连接已失效，请重新绑定'), findsOneWidget);
    harness.inbox.statuses['device:$peerId']!.error =
        'Bad state: database error at /private/device/store.sqlite';
    harness.inbox.activity.value++;
    await tester.pumpAndSettle();
    expect(find.text('同步未完成，可在此重试'), findsOneWidget);
    expect(find.textContaining('/private/device'), findsNothing);
    entry.copies.add('device:$peerId');
    harness.inbox.activity.value++;
    await tester.pumpAndSettle();
    expect(find.text('已同步'), findsNWidgets(2));
    expect(harness.inbox.copyStatus(entry), '已同步 2/2');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'phone panels use the screen and keep profile actions above the keyboard',
    (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await harness.mount(
        tester,
        size: const Size(320, 568),
        platform: TargetPlatform.android,
      );
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byType(Dialog)), const Size(320, 568));
      await tester.tap(find.text('编辑设备名称与头像'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final name = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '设备名称',
      );
      await tester.ensureVisible(name);
      await tester.enterText(name, '手机资料草稿');
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.widgetWithText(FilledButton, '保存')).bottom,
        lessThanOrEqualTo(308),
      );
      expect(tester.takeException(), isNull);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(harness.lan.name, '我的 Windows');
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const ValueKey('appearance-system')), 100,
        scrollable: find.descendant(of: find.byKey(const PageStorageKey('preferences-form')), matching: find.byType(Scrollable)));
      expect(find.byKey(const ValueKey('appearance-system')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
