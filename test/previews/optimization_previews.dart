import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/app.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';

import '../support/widget_harness.dart';

Future<void> _fonts() async {
  for (final font in [
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
    final file = File(font.$2);
    if (await file.exists()) {
      await (FontLoader(
        font.$1,
      )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
    }
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey boundary, String name) =>
    tester.runAsync(() async {
      final image =
          await (boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage();
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Directory('build/previews/optimization');
        await output.create(recursive: true);
        await File(
          '${output.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
      } finally {
        image.dispose();
      }
    });

void main() {
  final harness = WidgetTestHarness();

  testWidgets(
    'render bilingual desktop destinations inline naming selection and recovery actions',
    (tester) async {
      (harness.inbox as WidgetInbox).freezeTransfers = true;
      await tester.runAsync(() async {
        await _fonts();
        await harness.inbox.updateProfile('My Windows');
        await harness.inbox.addText(
          '先收好资料，晚上继续。\nKeep the original text when switching languages.',
        );
        await harness.inbox.addText(
          'UI ideas: organize messages, select several, and keep favorites close.',
        );
        final file = File('${harness.directory.path}/项目资料.txt');
        await file.writeAsString('Preview attachment');
        await harness.inbox.addFile(file.path);
        await harness.inbox.setFavorites(
          harness.inbox.items.map((entry) => entry.item.id).toList(),
          true,
        );
      });
      final boundary = GlobalKey();
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      for (final spec in [
        ('en-desktop', const Size(1180, 780), 'en', 1.0),
        ('zh-desktop', const Size(1180, 780), 'zh', 1.0),
        ('zh-desktop-dark', const Size(1180, 780), 'zh', 1.0),
        ('en-phone-390', const Size(390, 844), 'en', 1.0),
        ('en-phone-320-large', const Size(320, 640), 'en', 1.5),
        ('zh-phone-390', const Size(390, 844), 'zh', 1.0),
      ]) {
        final english = spec.$3 == 'en';
        final mobile = spec.$2.width < 840;
        await tester.runAsync(() => harness.inbox.setLanguage(spec.$3));
        await tester.runAsync(
          () => harness.inbox.setAppearance(
            spec.$1.endsWith('-dark') ? 'dark' : 'light',
          ),
        );
        harness.inbox.selectConversation(defaultConversationId);
        tester.view.physicalSize = spec.$2;
        tester.platformDispatcher.textScaleFactorTestValue = spec.$4;
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: LanFlowApp(
              controller: harness.lan,
              inbox: harness.inbox,
              platform: mobile
                  ? TargetPlatform.android
                  : TargetPlatform.windows,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (mobile) {
          await tester.tap(
            find.byKey(const ValueKey('conversation-$defaultConversationId')),
          );
          await tester.pumpAndSettle();
        }
        await _capture(tester, boundary, '${spec.$1}-chat');
        final editor = find.byKey(const ValueKey('inbox-composer'));
        final draft = english
            ? 'Keep this draft while selecting messages.'
            : '多选消息时继续保留这份草稿。';
        await tester.enterText(editor, draft);
        await tester.tap(find.byTooltip(english ? 'Select messages' : '多选消息'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(english ? 'Select all' : '全选'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(editor).controller!.text, draft);
        await _capture(tester, boundary, '${spec.$1}-selection');
        final cancelSelection = find.byTooltip(
          english ? 'Cancel selection' : '取消多选',
        );
        await tester.ensureVisible(cancelSelection);
        await tester.tap(cancelSelection);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(editor).controller!.text, draft);
        await tester.enterText(editor, '');
        await tester.tap(find.byTooltip(english ? 'Search messages' : '搜索消息'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('search-filters')), findsNothing);
        await _capture(tester, boundary, '${spec.$1}-search');
        await tester.tap(find.byTooltip(english ? 'Close search' : '关闭搜索'));
        await tester.pumpAndSettle();
        if (mobile) {
          await tester.tap(find.byTooltip(english ? 'Back to chats' : '返回会话'));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const ValueKey('mobile-nav-favorites')));
        } else {
          await tester.tap(find.byTooltip(english ? 'Favorites' : '收藏'));
        }
        await tester.pumpAndSettle();
        await _capture(tester, boundary, '${spec.$1}-favorites');
        if (mobile) {
          await tester.tap(
            find.byKey(const ValueKey('mobile-nav-conversations')),
          );
        } else {
          await tester.tap(
            find.byKey(const ValueKey('desktop-nav-conversations')),
          );
        }
        await tester.pumpAndSettle();
        if (!mobile) {
          final rail = tester.getRect(
            find.byKey(const ValueKey('desktop-navigation-rail')),
          );
          for (final section in ['devices', 'transfers']) {
            await tester.tap(find.byKey(ValueKey('desktop-nav-$section')));
            await tester.pumpAndSettle();
            expect(find.byType(Dialog), findsNothing);
            expect(
              tester.getRect(
                find.byKey(const ValueKey('desktop-navigation-rail')),
              ),
              rail,
            );
            await _capture(tester, boundary, '${spec.$1}-$section');
          }
          await tester.tap(
            find.byKey(const ValueKey('desktop-nav-conversations')),
          );
          await tester.pumpAndSettle();
          final count = harness.inbox.conversations.length;
          await tester.tap(
            find.byTooltip(english ? 'New conversation' : '新建会话'),
          );
          await tester.runAsync(
            () => harness.waitFor(
              () => harness.inbox.conversations.length == count + 1,
            ),
          );
          await tester.pumpAndSettle();
          final name = tester
              .widget<TextField>(
                find.byKey(const ValueKey('conversation-name')),
              )
              .controller!;
          expect(
            name.selection,
            TextSelection(baseOffset: 0, extentOffset: name.text.length),
          );
          expect(find.byType(Dialog), findsNothing);
          await _capture(
            tester,
            boundary,
            '${spec.$1}-new-conversation-inline',
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('conversation-$defaultConversationId')),
          );
          await tester.pumpAndSettle();
        }
        final device = 'c' * 32;
        harness.lan.sessions[device] = PeerSession(
          receiveToken: 'a' * 43,
          sendToken: 'b' * 43,
        );
        harness.inbox.store.profiles[device] = {'name': 'My other device'};
        harness.inbox.statuses['device:$device'] = SyncStatus()
          ..online = true
          ..needsAttention = true
          ..error = '连接已失效，请重新配对';
        harness.inbox.activity.value++;
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('open-sync-problems')));
        await tester.pumpAndSettle();
        await _capture(tester, boundary, '${spec.$1}-pairing-recovery');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        harness.lan.sessions.remove(device);
        harness.inbox.statuses.remove('device:$device');
      }
    },
  );
}
