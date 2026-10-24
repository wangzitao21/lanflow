import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_models.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets(
    'wide Android uses the shared split layout and preserves drafts when narrowed',
    (tester) async {
      await harness.mount(
        tester,
        platform: TargetPlatform.android,
        openMobileChat: false,
      );
      final conversation = find.byKey(
        ValueKey('conversation-$defaultConversationId'),
      );
      final editor = find.byKey(const ValueKey('inbox-composer'));
      expect(conversation, findsOneWidget);
      expect(editor, findsOneWidget);
      await tester.tap(conversation);
      await tester.pumpAndSettle();
      await tester.tap(editor);
      await tester.pump();
      await tester.enterText(editor, 'Android 草稿');
      expect(Theme.of(tester.element(editor)).platform, TargetPlatform.android);
      expect(
        find.byKey(const ValueKey('composer-resize-handle')),
        findsOneWidget,
      );
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      await tester.tap(conversation);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, 'Android 草稿');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'phone layout and an empty device refresh settle without a spinner',
    (tester) async {
      await harness.mount(
        tester,
        size: const Size(360, 780),
        platform: TargetPlatform.android,
      );
      await tester.tap(find.byTooltip('我的设备'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无附近设备'), findsOneWidget);
      harness.lan.stall = true;
      await tester.tap(find.widgetWithText(TextButton, '刷新'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text('刷新中'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'phone scroll cancels the hold; back and attachments keep drafts',
    (tester) async {
      await tester.runAsync(() async {
        for (var i = 0; i < 25; i++) {
          await harness.inbox.addText('手机滚动消息 $i');
        }
      });
      await harness.mount(
        tester,
        size: const Size(360, 640),
        platform: TargetPlatform.android,
      );
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.tap(editor);
      await tester.pump();
      await tester.enterText(editor, '保留手机草稿');
      await tester.tap(find.byTooltip('添加内容'));
      await tester.pumpAndSettle();
      expect(find.text('图片与视频'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      final gesture = await tester.startGesture(const Offset(220, 400));
      await tester.pump(const Duration(milliseconds: 150));
      await gesture.moveBy(const Offset(0, 150));
      await tester.pump(const Duration(milliseconds: 400));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-action-palette')),
        findsNothing,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(editor, findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('conversation-$defaultConversationId')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, '保留手机草稿');
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('compact windows and phone keyboard keep all controls usable', (
    tester,
  ) async {
    await harness.mount(tester, size: const Size(880, 560));
    expect(
      tester.getSize(find.byKey(const ValueKey('chat-composer-panel'))).height,
      greaterThan(100),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('inbox-composer'))).height,
      greaterThanOrEqualTo(28),
    );
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await harness.mount(
      tester,
      size: const Size(320, 568),
      platform: TargetPlatform.android,
    );
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final button = find.widgetWithText(FilledButton, '发送');
    expect(tester.getRect(button).bottom, lessThanOrEqualTo(308));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑设备名称与头像'));
    await tester.pumpAndSettle();
    final name = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '设备名称',
    );
    await tester.ensureVisible(name);
    await tester.enterText(name, '小屏幕上的设备');
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.widgetWithText(FilledButton, '保存')).bottom,
      lessThanOrEqualTo(308),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'desktop sidebar creates a real broadcast conversation from a right click',
    (tester) async {
      await harness.mount(tester);
      await tester.tapAt(
        const Offset(200, 650),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('desktop-menu-new')));
      await tester.runAsync(
        () => harness.waitFor(() => harness.inbox.conversations.length == 2),
      );
      await tester.pumpAndSettle();
      final nameField = find.byKey(const ValueKey('conversation-name'));
      final initial = tester.widget<TextField>(nameField).controller!;
      expect(initial.text, '新建会话');
      expect(
        initial.selection,
        TextSelection(baseOffset: 0, extentOffset: initial.text.length),
      );
      expect(find.byType(Dialog), findsNothing);
      await tester.enterText(nameField, '灵感');
      await tester.pump();
      await tester.runAsync(() async {
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await harness.waitFor(() => harness.inbox.conversation.name == '灵感');
      });
      await tester.pumpAndSettle();
      expect(harness.inbox.conversation.name, '灵感');
      expect(find.text('灵感'), findsNWidgets(2));
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'phone starts with categories; hold menu anchors above the bubble within 350ms',
    (tester) async {
      await tester.runAsync(() => harness.inbox.addText('长按这条消息'));
      await harness.mount(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.android,
        openMobileChat: false,
      );
      expect(find.byKey(const ValueKey('inbox-composer')), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('conversation-$defaultConversationId')),
      );
      await tester.pumpAndSettle();
      final message = find.byKey(
        ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
      );
      final top = tester.getTopLeft(message).dy;
      final gesture = await tester.startGesture(tester.getCenter(message));
      await tester.pump(const Duration(milliseconds: 351));
      expect(
        find.byKey(const ValueKey('message-action-palette')),
        findsOneWidget,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      final palette = tester.getRect(
        find.byKey(const ValueKey('message-action-palette')),
      );
      expect(palette.bottom, lessThanOrEqualTo(top));
      await tester.tapAt(const Offset(380, 500));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('message-action-palette')),
        findsNothing,
      );
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byTooltip('返回会话'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('inbox-composer')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
