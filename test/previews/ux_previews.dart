import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/app.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/chat/share_receiver_page.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();
  testWidgets('render new home, composer, appearance and share surfaces', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final name in [
        'Roboto',
        'Segoe UI',
        'Microsoft YaHei UI',
        'Microsoft YaHei',
      ]) {
        await (FontLoader(name)..addFont(
              File(
                r'C:\Windows\Fonts\msyh.ttc',
              ).readAsBytes().then(ByteData.sublistView),
            ))
            .load();
      }
      await (FontLoader('MaterialIcons')..addFont(
            File(
              'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
            ).readAsBytes().then(ByteData.sublistView),
          ))
          .load();
      await harness.inbox.createConversation('工作');
      await harness.inbox.addText('今天的资料已经整理好了');
      await harness.inbox.setConversationAvatar(
        harness.inbox.conversationId,
        'work',
      );
      await harness.inbox.createConversation('灵感');
      await harness.inbox.setConversationAvatar(
        harness.inbox.conversationId,
        'idea',
      );
      harness.inbox.store.draft = '想到一个新方案，稍后继续写';
      harness.inbox.selectConversation(defaultConversationId);
      final message = (await harness.inbox.addText('周末把文件整理一下，顺便看看这些照片。'))!;
      await harness.inbox.setDraftQuote(MessageQuote.fromItem(message.item));
      harness.inbox.store.draft = '好的，先放在这里';
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    Future<void> capture(String name) => tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.5);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/previews').create(recursive: true);
      await File(
        'build/previews/ux-$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: LanFlowApp(
          controller: harness.lan,
          inbox: harness.inbox,
          platform: TargetPlatform.android,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await capture('home');
    await tester.longPress(
      find.byKey(const ValueKey('conversation-$defaultConversationId')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('会话背景颜色'));
    await tester.pumpAndSettle();
    await capture('background');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('conversation-$defaultConversationId')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加内容'));
    await tester.pumpAndSettle();
    await capture('composer');
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: AppRoot(
          platform: TargetPlatform.android,
          home: ShareReceiverPage(
            inbox: harness.inbox,
            payload: const {
              'id': 'preview',
              'text': 'https://example.com/reading',
              'files': [],
            },
            onSend: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await capture('share-list');
    await tester.tap(
      find.byKey(const ValueKey('share-to-$defaultConversationId')),
    );
    await tester.pumpAndSettle();
    await capture('share-confirm');
    await tester.tap(find.byKey(const ValueKey('share-send')));
    await tester.pumpAndSettle();
    await capture('share-done');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
