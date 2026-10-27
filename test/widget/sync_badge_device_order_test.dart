import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/message_sync_badge.dart';
import 'package:lanflow/ui/chat/sync_details.dart';
import 'package:lanflow/ui/shared/device_avatar.dart';
import 'package:lanflow/ui/shared/device_avatar_choices.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import '../support/widget_harness.dart';

Future<void> loadPreviewFonts(WidgetTester tester) => tester.runAsync(() async {
  for (final font in [
    ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
    ('Microsoft YaHei UI', r'C:\Windows\Fonts\msyh.ttc'),
    ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
    ('MaterialIcons', 'build/unit_test_assets/fonts/MaterialIcons-Regular.otf'),
  ]) {
    final file = File(font.$2);
    if (await file.exists()) {
      await (FontLoader(
        font.$1,
      )..addFont(file.readAsBytes().then(ByteData.sublistView))).load();
    }
  }
});

Future<void> savePreview(
  WidgetTester tester,
  String name, {
  Finder? focus,
}) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    focus == null
        ? find.byType(RepaintBoundary).first
        : find.ancestor(of: focus, matching: find.byType(RepaintBoundary)).last,
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('build/previews/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  final harness = WidgetTestHarness();
  testWidgets(
    'corner badge is green only after all copies finish and opens immediately',
    (tester) async {
      await loadPreviewFonts(tester);
      late InboxEntry entry;
      await tester.runAsync(() async {
        entry = (await harness.inbox.addText('小圆标位于消息右下角'))!;
      });
      await harness.mount(tester);
      final badge = find.byKey(ValueKey('sync-badge-${entry.item.id}'));
      final content = tester.getRect(
        find.byKey(ValueKey('message-badge-content-${entry.item.id}')),
      );
      final circle = tester.getRect(badge);
      expect(circle.width, MessageSyncBadge.diameter);
      expect(
        circle.center.dx,
        closeTo(content.right - ChatMetrics.bubbleTailWidth, .1),
      );
      expect(circle.center.dy, closeTo(content.bottom, .1));
      Color? color() =>
          (tester.widget<Container>(badge).decoration as BoxDecoration).color;
      expect(color(), MessageSyncBadge.completeColor);
      final id = 'e' * 32;
      harness.lan.sessions[id] = PeerSession(
        sendToken: 'a' * 43,
        receiveToken: 'b' * 43,
      );
      final status = harness.inbox.statuses['device:$id'] = SyncStatus();
      harness.inbox.activity.value++;
      await tester.pump();
      expect(color(), MessageSyncBadge.pendingColor);
      expect(
        find.descendant(
          of: badge,
          matching: find.byIcon(Icons.priority_high_rounded),
        ),
        findsOneWidget,
      );
      status
        ..busy = true
        ..online = true;
      harness.inbox.activity.value++;
      await tester.pump();
      expect(color(), MessageSyncBadge.pendingColor);
      entry.copies.add('device:$id');
      status
        ..busy = false
        ..online = false;
      harness.inbox.activity.value++;
      await tester.pump();
      expect(
        color(),
        MessageSyncBadge.completeColor,
        reason: 'Going offline must not invalidate a completed copy',
      );
      expect(
        find.descendant(of: badge, matching: find.byIcon(Icons.check_rounded)),
        findsOneWidget,
      );
      expect(find.text('消息详情'), findsNothing);
      // The part outside the bubble is still in the badge hit box.
      await tester.tapAt(circle.center + const Offset(4, 4));
      await tester.pump();
      expect(find.byType(SyncDetails), findsOneWidget);
      expect(
        ModalRoute.of(
          tester.element(find.byType(SyncDetails)),
        )!.transitionDuration,
        Duration.zero,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await savePreview(tester, 'message-sync-corner');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'device presets and colors can be saved locally and for paired devices',
    (tester) async {
      await loadPreviewFonts(tester);
      final id = 'e' * 32;
      harness.lan.sessions[id] = PeerSession(
        sendToken: 'a' * 43,
        receiveToken: 'b' * 43,
      );
      harness.inbox.statuses['device:$id'] = SyncStatus()
        ..error = '连接不到设备，请确认对方已打开 LanFlow 且网络可达'
        ..errorCategory = 'offline';
      await harness.mount(tester);
      await harness.openSettingsPage(tester, 'profile');
      expect(find.byType(DeviceAvatarChoices), findsOneWidget);
      for (final preset in ['linux', 'windows', 'android', 'ios', 'macos']) {
        expect(
          find.byKey(ValueKey('device-avatar-preset-$preset')),
          findsOneWidget,
        );
      }
      await tester.tap(find.byKey(const ValueKey('device-avatar-preset-ios')));
      await tester.tap(
        find.byKey(const ValueKey('device-avatar-color-4286473141')),
      );
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.runAsync(
        () => harness.waitFor(
          () =>
              harness.inbox.deviceAvatarPreset(harness.lan.identity.id) ==
              'ios',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        harness.inbox.deviceAvatarColor(harness.lan.identity.id),
        0xFF7E63B5,
      );
      await harness.openSettingsPage(tester, 'devices');
      expect(find.text('离线'), findsOneWidget);
      expect(find.textContaining('连接不到设备'), findsNothing);
      harness.inbox.statuses['device:$id']!.online = true;
      harness.inbox.activity.value++;
      await tester.pump();
      expect(find.text('已连接'), findsOneWidget);
      final avatar = find.byKey(ValueKey('edit-device-avatar-$id'));
      await tester.tap(avatar);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('device-avatar-preset-linux')),
      );
      await tester.tap(
        find.byKey(const ValueKey('device-avatar-color-4291192450')),
      );
      await tester.pumpAndSettle();
      await savePreview(
        tester,
        'device-avatar-presets',
        focus: find.byType(DeviceAvatarChoices),
      );
      await tester.tap(find.byKey(const ValueKey('save-device-avatar')));
      await tester.runAsync(
        () => harness.waitFor(
          () => harness.inbox.deviceAvatarPreset(id) == 'linux',
        ),
      );
      await tester.pumpAndSettle();
      final shown = tester.widget<DeviceAvatar>(
        find.descendant(of: avatar, matching: find.byType(DeviceAvatar)),
      );
      expect(shown.preset, 'linux');
      expect(shown.color, 0xFFC66682);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'dragging rows saves manual order while pinned rows return to their position',
    (tester) async {
      late Conversation one, two;
      await tester.runAsync(() async {
        one = await harness.inbox.createConversation('One');
        two = await harness.inbox.createConversation('Two');
      });
      await harness.mount(tester);
      Finder row(String id) => find.byKey(ValueKey('conversation-$id'));
      Future<void> drag(String id, Offset end) async {
        final gesture = await tester.startGesture(
          tester.getCenter(row(id)),
          kind: PointerDeviceKind.mouse,
        );
        await gesture.moveBy(const Offset(0, -10));
        await tester.pump(const Duration(milliseconds: 80));
        await gesture.moveTo(end);
        await tester.pump(const Duration(milliseconds: 350));
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pumpAndSettle();
      }

      await drag(
        two.id,
        tester.getCenter(row(defaultConversationId)) + const Offset(0, 5),
      );
      expect(harness.inbox.conversations.map((c) => c.id), [
        two.id,
        defaultConversationId,
        one.id,
      ]);
      await tester.runAsync(
        () => harness.inbox.setConversationPinned(one.id, true),
      );
      await tester.pumpAndSettle();
      await drag(
        one.id,
        tester.getBottomLeft(row(defaultConversationId)) +
            const Offset(100, 10),
      );
      expect(harness.inbox.conversations.map((c) => c.id), [
        one.id,
        two.id,
        defaultConversationId,
      ]);
      expect(
        tester.getTopLeft(row(one.id)).dy,
        lessThan(tester.getTopLeft(row(two.id)).dy),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
