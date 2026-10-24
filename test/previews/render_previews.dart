import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/app.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/settings/storage_dialog.dart';
import 'package:lanflow/ui/settings/transfer_dialog.dart';
import 'package:lanflow/ui/settings/recently_deleted_panel.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import 'package:lanflow/ui/shared/runtime_feedback.dart';

import '../support/widget_harness.dart';

Future<void> savePreview(
  WidgetTester tester,
  GlobalKey key,
  String name, {
  double pixelRatio = 1,
}) => tester.runAsync(() async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
  await Directory('build/previews').create(recursive: true);
  await File(
    'build/previews/$name.png',
  ).writeAsBytes(bytes!.buffer.asUint8List());
  image.dispose();
});

void main() {
  final harness = WidgetTestHarness();

  testWidgets('render desktop and phone inbox previews', (tester) async {
    (harness.inbox as WidgetInbox).freezeTransfers = true;
    late Conversation work;
    await tester.runAsync(() async {
      for (final entry in [
        ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
        ('Microsoft YaHei UI', r'C:\Windows\Fonts\msyh.ttc'),
        ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
        ('Roboto', r'C:\Windows\Fonts\msyh.ttc'),
        ('Segoe UI Emoji', r'C:\Windows\Fonts\seguiemj.ttf'),
        (
          'MaterialIcons',
          Platform.environment['LANFLOW_PREVIEW_ICON_FONT'] ??
              'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
        ),
      ]) {
        final file = File(entry.$2);
        if (await file.exists()) {
          final loader = FontLoader(entry.$1)
            ..addFont(file.readAsBytes().then(ByteData.sublistView));
          await loader.load();
        }
      }
      await harness.inbox.store.add(
        InboxItem(
          id: 'preview-phone-note-0001',
          originId: 'b' * 32,
          originName: '我的 Android',
          createdAt: DateTime.now().subtract(const Duration(minutes: 3)),
          kind: MessageKind.text,
          text: '刚才刷到一个好玩的视频，先发过来，晚上在电脑上处理。',
        ),
      );
      await harness.inbox.addText('拿好资料再出发。想到了一个新 idea，先记下来。');
      final file = File('${harness.directory.path}/项目参考资料.zip');
      await file.writeAsString('preview');
      await harness.inbox.addFile(file.path);
      await harness.inbox.addText(
        '周末想去的地方，先记下来。\nhttps://example.com/my-notes',
      );
      work = await harness.inbox.createConversation('工作');
      await harness.inbox.addText('本周项目资料，回到办公室继续处理。');
      await harness.inbox.setConversationPinned(work.id, true);
      await harness.inbox.setConversationBackground(work.id, 0xFFDCE7F3);
      final ideas = await harness.inbox.createConversation('灵感');
      await harness.inbox.addText('把随手想到的事情放在这里。');
      await harness.inbox.setConversationBackground(ideas.id, 0xFFE6E0F0);
      await harness.inbox.setConversationUnread(ideas.id, true);
      harness.inbox.relocateStorage = (_, _) async {};
      harness.inbox.selectConversation(defaultConversationId);
    });
    final key = GlobalKey();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    for (final spec in [
      ('windows-chat', const Size(1180, 780), false, 1.0),
      ('windows-dark', const Size(1180, 780), true, 1.0),
      ('windows-sync-error', const Size(1180, 780), false, 1.0),
      ('windows-text-125', const Size(1180, 780), false, 1.25),
      ('windows-text-150', const Size(1180, 780), true, 1.5),
      ('android-wide', const Size(1180, 780), false, 1.0),
      ('android-list', const Size(390, 844), false, 1.0),
      ('android-sync-error', const Size(390, 844), true, 1.0),
      ('android-chat', const Size(390, 844), false, 1.0),
      ('android-dark', const Size(390, 844), true, 1.0),
    ]) {
      final issueDevice = 'c' * 32;
      if (spec.$1.endsWith('sync-error')) {
        harness.lan.sessions[issueDevice] = PeerSession(
          receiveToken: 'a' * 43,
          sendToken: 'b' * 43,
        );
        harness.inbox.statuses['device:$issueDevice'] = SyncStatus()
          ..online = true
          ..needsAttention = true
          ..error = '连接已失效，请重新配对';
      }
      harness.inbox.appearance.value = spec.$3 ? 'dark' : 'light';
      tester.platformDispatcher.textScaleFactorTestValue =
          spec.$1.startsWith('windows-text-') ? spec.$4 : 1;
      tester.view.devicePixelRatio = spec.$4;
      tester.view.physicalSize = spec.$2 * spec.$4;
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: LanFlowApp(
            controller: harness.lan,
            inbox: harness.inbox,
            platform: spec.$1.startsWith('android')
                ? TargetPlatform.android
                : TargetPlatform.windows,
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (spec.$2.width < 840 && spec.$1 != 'android-list') {
        await tester.tap(
          find.byKey(const ValueKey('conversation-$defaultConversationId')),
        );
        await tester.pumpAndSettle();
      }
      expect(tester.takeException(), isNull);
      Future<void> capture(String name) =>
          savePreview(tester, key, name, pixelRatio: spec.$4);
      await capture(spec.$1);
      if (spec.$1 == 'android-list') {
        await tester.longPress(find.byKey(ValueKey('conversation-${work.id}')));
        await tester.pumpAndSettle();
        await capture('android-conversation-menu');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('mobile-nav-devices')));
        await tester.pumpAndSettle();
        await capture('android-devices');
        await tester.tap(find.byKey(const ValueKey('mobile-nav-transfers')));
        await tester.pumpAndSettle();
        await capture('android-transfers');
      }
      if (spec.$1.endsWith('sync-error')) {
        await tester.tap(find.byKey(const ValueKey('open-sync-problems')));
        await tester.pumpAndSettle();
        await capture('${spec.$1}-details');
      }
      if (spec.$1 == 'windows-chat') {
        await tester.tapAt(
          tester.getCenter(find.byKey(ValueKey('conversation-${work.id}'))),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await capture('windows-conversation-menu');
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('global-conversation-search')),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('global-conversation-search')),
          '项目',
        );
        await tester.pumpAndSettle();
        await capture('windows-global-search');
        final file = harness.inbox.items.firstWhere(
          (entry) => entry.item.name == '项目参考资料.zip',
        );
        await tester.tap(find.byKey(ValueKey('search-result-${file.item.id}')));
        await tester.pumpAndSettle();
        await capture('windows-message-location');
        await tester.tap(find.text('回到最新'));
        await tester.pumpAndSettle();
      }
      if (spec.$1 == 'android-chat') {
        await tester.tap(find.byTooltip('搜索消息'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('message-search-input')),
          '资料',
        );
        await tester.pumpAndSettle();
        await capture('android-search');
        final file = harness.inbox.items.firstWhere(
          (entry) => entry.item.name == '项目参考资料.zip',
        );
        await tester.tap(find.byKey(ValueKey('search-result-${file.item.id}')));
        await tester.pumpAndSettle();
        await capture('android-message-location');
        await tester.tap(find.text('回到最新'));
        await tester.pumpAndSettle();
      }
      if (spec.$1 == 'windows-chat' || spec.$1 == 'android-chat') {
        await tester.runAsync(
          () => harness.inbox.stageFile('${harness.directory.path}/项目参考资料.zip'),
        );
        await tester.pumpAndSettle();
        await capture(
          spec.$1 == 'windows-chat' ? 'windows-drafts' : 'android-drafts',
        );
        await tester.runAsync(
          () => harness.inbox.removeDraftAttachment(
            harness.inbox.store.draftAttachments.single,
          ),
        );
        await tester.pumpAndSettle();
      }
      if (spec.$1 == 'windows-dark' || spec.$1 == 'android-dark') {
        final item = harness.inbox.itemsIn(defaultConversationId).first.item;
        final bubble = find.byKey(ValueKey('inbox-item-${item.id}'));
        if (spec.$1 == 'windows-dark') {
          await tester.tapAt(
            tester.getCenter(bubble),
            buttons: kSecondaryMouseButton,
          );
        } else {
          await tester.longPressAt(tester.getCenter(bubble));
        }
        await tester.pumpAndSettle();
        await capture(
          spec.$1 == 'windows-dark' ? 'windows-menu' : 'android-menu',
        );
        await tester.tapAt(Offset(spec.$2.width - 5, 550));
        await tester.pumpAndSettle();
        if (spec.$1 == 'windows-dark') {
          final rich = find
              .descendant(of: bubble, matching: find.byType(RichText))
              .first;
          final start = tester.getTopLeft(rich) + const Offset(2, 10);
          final drag = await tester.startGesture(
            start,
            kind: PointerDeviceKind.mouse,
          );
          await drag.moveTo(start + const Offset(96, 0));
          await drag.up();
          await tester.pump();
          await tester.tapAt(
            start + const Offset(20, 0),
            buttons: kSecondaryMouseButton,
          );
          await tester.pumpAndSettle();
          await capture('windows-selected-menu');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
        }
      }
      if (spec.$1 == 'windows-dark' || spec.$1 == 'android-dark') {
        await tester.tap(find.byTooltip('设置'));
        await tester.pumpAndSettle();
        final prefix = spec.$1 == 'windows-dark' ? 'windows' : 'android';
        await capture('$prefix-settings');
        await tester.tap(find.text('编辑设备名称与头像'));
        await tester.pumpAndSettle();
        await capture('$prefix-profile');
        await tester.tap(find.byTooltip('关闭'));
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
      harness.lan.sessions.remove(issueDevice);
      harness.inbox.statuses.remove('device:$issueDevice');
    }
    await tester.runAsync(() async {
      final note = await harness.inbox.addText('需要恢复的重要记录');
      await harness.inbox.deleteItem(note!.item);
    });
    (harness.inbox as WidgetInbox).freezeTransfers = true;
    harness.inbox.transferTasks = [
      TransferTask.fromJson({
        'endpoint': 'device:preview',
        'direction': 'upload',
        'eventId': 'preview-transfer-0001',
        'item': InboxItem(
          id: 'preview-file-0001',
          originId: harness.lan.identity.id,
          originName: harness.lan.name,
          createdAt: DateTime.now(),
          kind: MessageKind.file,
          name: '项目资料.zip',
          size: 96 * 1024 * 1024,
          digest: 'a' * 64,
        ).toJson(),
        'transferred': 36 * 1024 * 1024,
        'state': 'paused',
      }),
    ];
    for (final size in [
      const Size(1180, 780),
      const Size(390, 844),
      const Size(320, 600),
    ]) {
      tester.view.physicalSize = size;
      harness.inbox.appearance.value = 'light';
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: LanFlowApp(
            controller: harness.lan,
            inbox: harness.inbox,
            platform: size.width < 840
                ? TargetPlatform.android
                : TargetPlatform.windows,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['传输任务', '存储管理', '回收站']) {
        if (label == '传输任务') {
          await tester.tap(find.byTooltip('传输任务'));
        } else if (label == '回收站') {
          await tester.tap(find.byTooltip('回收站'));
        } else {
          await tester.tap(find.byTooltip('设置'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text(label).last);
          await tester.tap(find.text(label).last);
        }
        await tester.pump();
        for (
          var i = 0;
          i < 100 &&
              find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
          i++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(switch (label) {
          '传输任务' => find.byType(TransferDialog),
          '存储管理' => find.byType(StorageDialog),
          _ => find.byType(RecentlyDeletedPanel),
        }, findsOneWidget);
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final name = switch (label) {
            '传输任务' => 'transfers',
            '存储管理' => 'storage',
            _ => 'deleted',
          };
          await File(
            'build/previews/${size.width.toInt()}-$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        if (label == '传输任务') {
          await tester.tap(
            find.byKey(
              ValueKey(
                size.width < 840
                    ? 'mobile-nav-conversations'
                    : 'desktop-nav-conversations',
              ),
            ),
          );
        } else if (label == '回收站') {
          await tester.tap(
            size.width < 840
                ? find.byTooltip('返回会话')
                : find.byKey(const ValueKey('desktop-nav-conversations')),
          );
        } else {
          await tester.tap(find.byTooltip('关闭'));
        }
        await tester.pumpAndSettle();
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    for (final mobile in [false, true]) {
      tester.view.physicalSize = mobile
          ? const Size(390, 844)
          : const Size(1180, 780);
      for (final dark in [false, true]) {
        final prefix = mobile ? 'android' : 'windows';
        final tone = dark ? 'dark' : 'light';
        final platform = mobile
            ? TargetPlatform.android
            : TargetPlatform.windows;
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: AppRoot(
              platform: platform,
              themeMode: dark ? ThemeMode.dark : ThemeMode.light,
              home: StartupFailure(onRetry: () async {}),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await savePreview(tester, key, '$prefix-startup-$tone');
        await tester.pumpWidget(const SizedBox.shrink());
        harness.inbox.appearance.value = dark ? 'dark' : 'light';
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: LanFlowApp(
              controller: harness.lan,
              inbox: harness.inbox,
              platform: platform,
              interactionsBlocked: true,
              builder: (_, child) => RuntimeFeedback(
                changing: true,
                progress: '正在迁移并校验 65%',
                onDismiss: () {},
                child: child!,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        expect(tester.takeException(), isNull);
        await savePreview(tester, key, '$prefix-migration-$tone');
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
  });
}
