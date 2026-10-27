import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/app.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/sync_details.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/profile_avatar.dart';
import 'package:lanflow/ui/shared/runtime_feedback.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets(
    'migration overlays inherit the dark theme and block shortcuts and pointer actions',
    (tester) async {
      harness.inbox.appearance.value = 'dark';
      var hidden = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lanflow/desktop'), (
            call,
          ) async {
            if (call.method == 'hideToTray') hidden++;
            return null;
          });
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Widget app(bool changing) => LanFlowApp(
        controller: harness.lan,
        inbox: harness.inbox,
        platform: TargetPlatform.windows,
        interactionsBlocked: changing,
        builder: (context, child) => RuntimeFeedback(
          changing: changing,
          progress: '正在迁移并校验 50%',
          notice: changing ? null : '数据已迁移到新位置',
          onDismiss: () {},
          child: child!,
        ),
      );
      await tester.pumpWidget(app(true));
      await tester.pump(const Duration(milliseconds: 250));
      final overlay = find.byKey(const ValueKey('storage-migration-overlay'));
      final theme = Theme.of(tester.element(overlay));
      expect(theme.brightness, Brightness.dark);
      expect(
        tester.widget<Material>(overlay).color,
        ChatPalette.of(tester.element(overlay)).canvas,
      );
      await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('global-conversation-search'))));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(hidden, 0);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('global-conversation-search'))).focusNode!.hasFocus, isFalse);
      expect(harness.inbox.readingConversation, isNull);
      await tester.pumpWidget(app(false));
      await tester.pumpAndSettle();
      expect(overlay, findsNothing);
      expect(
        Theme.of(
          tester.element(find.byKey(const ValueKey('runtime-notice'))),
        ).brightness,
        Brightness.dark,
      );
      await harness.openGlobalSearch(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('global-conversation-search')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'startup recovery follows the system appearance and prevents duplicate retries',
    (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final gate = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        AppRoot(
          home: StartupFailure(
            onRetry: () {
              calls++;
              return gate.future;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        Theme.of(tester.element(find.byType(StartupFailure))).brightness,
        Brightness.dark,
      );
      await tester.tap(find.widgetWithText(FilledButton, '重试'));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '重试中…'))
            .onPressed,
        isNull,
      );
      expect(calls, 1);
      gate.completeError(StateError('private storage path'));
      await tester.pumpAndSettle();
      expect(find.textContaining('仍无法访问存储位置'), findsOneWidget);
      expect(find.textContaining('private storage'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '重试'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'every consecutive message keeps its avatar, receipt and detail access',
    (tester) async {
      final entries = <InboxEntry>[];
      await tester.runAsync(() async {
        for (var i = 0; i < 3; i++) {
          entries.add((await harness.inbox.addText('连续消息 $i'))!);
        }
      });
      await harness.mount(tester);
      final history = find.byKey(const ValueKey('self-chat-history'));
      expect(
        find.descendant(of: history, matching: find.byType(ProfileAvatar)),
        findsNWidgets(3),
      );
      expect(
        find.byKey(ValueKey('copy-status-${entries[0].item.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('copy-status-${entries[1].item.id}')),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey('copy-status-${entries[2].item.id}')),
        findsOneWidget,
      );
      await tester.tapAt(
        tester.getCenter(
          find.byKey(ValueKey('inbox-item-${entries[0].item.id}')),
        ),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('同步详情'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SyncDetails>(find.byType(SyncDetails)).entry.item.id,
        entries[0].item.id,
      );
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      final id = 'e' * 32;
      final endpoint = 'device:$id';
      harness.lan.sessions[id] = PeerSession(
        receiveToken: 'a' * 43,
        sendToken: 'b' * 43,
      );
      harness.inbox.statuses[endpoint] = SyncStatus()
        ..online = true
        ..needsAttention = true
        ..error = '设备证书不一致';
      entries[1].copies.add(endpoint);
      entries[2].copies.add(endpoint);
      harness.inbox.activity.value++;
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('copy-status-${entries[0].item.id}')),
        findsOneWidget,
      );
      expect(find.text('已同步 0/1 · 连接或传输待处理'), findsNothing);
      expect(
        find.byKey(ValueKey('copy-status-${entries[1].item.id}')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed task loading offers retry instead of claiming the queue is empty',
    (tester) async {
      final inbox = harness.inbox as WidgetInbox;
      inbox.transfersError = StateError('raw database error at /private/path');
      await harness.mount(tester);
      await harness.openSettingsPage(tester, 'transfers');
      await tester.pumpAndSettle();
      expect(find.text('无法加载传输任务'), findsOneWidget);
      expect(find.text('暂无待传输的附件'), findsNothing);
      expect(find.textContaining('/private/path'), findsNothing);
      inbox.transfersError = null;
      inbox.freezeTransfers = true;
      await tester.tap(find.widgetWithText(TextButton, '重试'));
      await tester.pumpAndSettle();
      expect(find.text('暂无待传输的附件'), findsOneWidget);
      expect(find.text('无法加载传输任务'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
