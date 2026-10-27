import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/chat/conversation_avatar.dart';
import 'package:lanflow/ui/chat/conversation_dialogs.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();
  testWidgets('avatar editor is centered and persists both icon and color', (
    tester,
  ) async {
    const size = Size(1100, 760);
    await harness.mount(tester, size: size);
    final row = find.byKey(
      const ValueKey('conversation-$defaultConversationId'),
    );
    await tester.tapAt(tester.getCenter(row), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('更换头像'));
    await tester.pumpAndSettle();
    final surface = find.byKey(const ValueKey('conversation-avatar-editor'));
    expect(
      (tester.getCenter(surface) - size.center(Offset.zero)).distance,
      lessThan(1),
    );
    final first = tester.getRect(
      find.byKey(const ValueKey('conversation-avatar-chat')),
    );
    final last = tester.getRect(
      find.byKey(const ValueKey('conversation-avatar-idea')),
    );
    expect(
      (first.left + last.right) / 2,
      closeTo(tester.getCenter(surface).dx, 1),
    );
    expect(first.width, closeTo(last.width, 1));
    final icon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('conversation-avatar-chat')),
        matching: find.byType(ConversationAvatar),
      ),
    );
    final lastIcon = tester.getRect(
      find.descendant(
        of: find.byKey(const ValueKey('conversation-avatar-idea')),
        matching: find.byType(ConversationAvatar),
      ),
    );
    expect(
      (icon.left + lastIcon.right) / 2,
      closeTo(tester.getCenter(surface).dx, 1),
    );
    await tester.tap(find.byKey(const ValueKey('conversation-avatar-book')));
    await tester.tap(
      find.byKey(const ValueKey('conversation-avatar-color-4286473141')),
    );
    await tester.pump();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(harness.inbox.conversationAvatar(defaultConversationId), 'book');
    expect(
      harness.inbox.conversationAvatarColor(defaultConversationId),
      0xFF7E63B5,
    );
    final avatar = tester.widget<ConversationAvatar>(
      find.descendant(of: row, matching: find.byType(ConversationAvatar)),
    );
    expect(avatar.color, 0xFF7E63B5);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('appearance dialogs stay inside resized windows', (tester) async {
    await tester.runAsync(() async {
      for (final font in [
        ('Segoe UI', r'C:\Windows\Fonts\segoeui.ttf'),
        ('Microsoft YaHei UI', r'C:\Windows\Fonts\msyh.ttc'),
        ('Microsoft YaHei', r'C:\Windows\Fonts\msyh.ttc'),
        (
          'MaterialIcons',
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
    });
    for (final size in [const Size(1100, 760), const Size(420, 360)]) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      final boundary = GlobalKey();
      late BuildContext target;
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: AppRoot(
            platform: TargetPlatform.windows,
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  target = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        ),
      );
      final dialogs = ConversationDialogs(
        inbox: harness.inbox,
        showDialog: <T>({required context, required builder}) =>
            showDialog<T>(context: context, builder: builder),
        onCreated: (_) {},
      );
      final closed = dialogs.avatar(target, defaultConversationId);
      await tester.pumpAndSettle();
      final dialog = tester.getRect(
        find
            .descendant(
              of: find.byType(Dialog),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(dialog.left, greaterThanOrEqualTo(24));
      expect(dialog.right, lessThanOrEqualTo(size.width - 24));
      expect(dialog.top, greaterThanOrEqualTo(24));
      expect(dialog.bottom, lessThanOrEqualTo(size.height - 24));
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File(
          'build/previews/avatar-editor-${size.width.toInt()}.png',
        );
        await output.parent.create(recursive: true);
        await output.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      Navigator.of(target).pop();
      await tester.pumpAndSettle();
      await closed;
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
