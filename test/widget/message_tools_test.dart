import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/link_preview.dart';
import 'package:lanflow/ui/chat/image_viewer.dart';
import 'package:lanflow/ui/chat/favorite_actions.dart';
import 'package:lanflow/ui/chat/message_link_preview.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import '../support/widget_harness.dart';
import 'message_selection_test.dart' show waitForStorage;

void main() {
  final harness = WidgetTestHarness();
  testWidgets(
    'merged copy writes chronological paragraphs and respects the numbering preference',
    (tester) async {
      late InboxEntry first, second;
      await tester.runAsync(() async {
        first = (await harness.inbox.addText('第一条'))!;
        second = (await harness.inbox.addText('第二条'))!;
        await harness.inbox.setMessagePreferences(mergedCopyNumbered: true);
      });
      await harness.mount(tester);
      await tester.tap(find.byTooltip('多选消息'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('select-message-${second.item.id}')),
      );
      await tester.tap(find.byKey(ValueKey('select-message-${first.item.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('selection-panel-copy')));
      await waitForStorage(
        tester,
        () => find.text('已合并复制').evaluate().isNotEmpty,
      );
      expect(
        (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        '1. 第一条\n\n2. 第二条',
      );
    },
  );
  testWidgets(
    'forward menu excludes source and moves to the selected conversation',
    (tester) async {
      late InboxEntry source;
      late Conversation target;
      await tester.runAsync(() async {
        source = (await harness.inbox.addText('需要转发'))!;
        target = await harness.inbox.createConversation('目标');
        harness.inbox.selectConversation(defaultConversationId);
      });
      await harness.mount(tester);
      await tester.tapAt(
        tester.getCenter(find.byKey(ValueKey('inbox-item-${source.item.id}'))),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('转发'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('forward-target-$defaultConversationId')),
        findsNothing,
      );
      await tester.tap(find.byKey(ValueKey('forward-target-${target.id}')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('confirm-forward')));
      await waitForStorage(
        tester,
        () => harness.inbox.itemsIn(target.id).isNotEmpty,
      );
      expect(
        find.byKey(const ValueKey('forward-message-dialog')),
        findsNothing,
      );
      expect(harness.inbox.itemsIn(defaultConversationId), isEmpty);
      expect(harness.inbox.itemsIn(target.id).single.item.text, '需要转发');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'phone long hold drags a conversation and menu remains available via more',
    (tester) async {
      late Conversation a, b;
      await tester.runAsync(() async {
        a = await harness.inbox.createConversation('A');
        b = await harness.inbox.createConversation('B');
      });
      await harness.mount(
        tester,
        platform: TargetPlatform.android,
        size: const Size(390, 844),
        openMobileChat: false,
      );
      final row = find.byKey(ValueKey('conversation-${a.id}'));
      expect(
        find.byType(ReorderableDelayedDragStartListener),
        findsNWidgets(3),
      );
      final gesture = await tester.startGesture(tester.getCenter(row));
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        find.byKey(const ValueKey('conversation-action-palette')),
        findsNothing,
      );
      for (var step = 0; step < 4; step++) {
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pump(const Duration(milliseconds: 500));
      await gesture.up();
      await tester.pumpAndSettle();
      await waitForStorage(
        tester,
        () => harness.inbox.conversations.last.id == a.id,
      );
      expect(harness.inbox.conversations.map((c) => c.id), [
        defaultConversationId,
        b.id,
        a.id,
      ]);
      await tester.tap(find.byKey(ValueKey('conversation-menu-${a.id}')));
      await tester.pumpAndSettle();
      expect(find.text('置顶'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'settings expose both toggles with their defaults and persist changes',
    (tester) async {
      await harness.mount(tester);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final numbered = find.byKey(const ValueKey('merged-copy-numbered'));
      await tester.ensureVisible(numbered);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(numbered).value, isFalse);
      await tester.tap(numbered);
      await tester.pump();
      await waitForStorage(
        tester,
        () =>
            harness.inbox.store.mergedCopyNumbered &&
            tester.widget<SwitchListTile>(numbered).onChanged != null,
      );
      final cut = find.byKey(const ValueKey('cut-forward'));
      await tester.ensureVisible(cut);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(cut).value, isTrue);
      await tester.tap(cut);
      await tester.pump();
      await waitForStorage(
        tester,
        () =>
            !harness.inbox.store.cutForward &&
            tester.widget<SwitchListTile>(cut).onChanged != null,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'image message and viewer menus both copy image bytes to the platform clipboard',
    (tester) async {
      late InboxEntry item;
      await tester.runAsync(() async {
        final file = File('${harness.directory.path}/image.png');
        await file.writeAsBytes(png);
        item = await harness.inbox.addFile(file.path);
      });
      final writes = <MethodCall>[];
      final channel = MethodChannel(
        Platform.isWindows ? 'lanflow/clipboard' : 'lanflow/platform',
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            writes.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      await harness.mount(tester);
      final image = find.byKey(ValueKey('inbox-item-${item.item.id}'));
      await tester.tapAt(
        tester.getCenter(image),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('复制图片'));
      await waitForStorage(tester, () => writes.isNotEmpty);
      final bytes = Platform.isWindows
          ? (writes.last.arguments as Map)['png'] as Uint8List
          : writes.last.arguments as Uint8List;
      expect(bytes.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      await tester.runAsync(() async {
        await precacheImage(
          FileImage(await harness.inbox.store.fileForOpening(item.item)),
          tester.element(image),
        );
      });
      await tester.tap(image);
      await waitForStorage(
        tester,
        () => find.byType(ImageViewer).evaluate().isNotEmpty,
      );
      expect(find.byType(ImageViewer), findsOneWidget);
      await tester.tap(find.byTooltip('图片操作'));
      await tester.pumpAndSettle();
      expect(find.text('复制图片'), findsOneWidget);
      await tester.tap(find.text('复制图片'));
      await waitForStorage(tester, () => writes.length == 2);
      expect(find.byType(ImageViewer), findsOneWidget);
      await tester.runAsync(() async {
        await harness.inbox.setFavorites([item.item.id], true);
        await FavoriteActions(
          harness.inbox,
        ).copy(harness.inbox.favoriteEntries.single);
      });
      expect(writes.length, 3);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'link preview renders title summary and source, opens original link, and falls back offline',
    (tester) async {
      final url = Uri.parse('https://example.com/article');
      String? opened;
      final service = LinkPreviewService(
        loader: (_) async => LinkPreview(
          url: url,
          title: '研究标题',
          description: '文章摘要',
          source: '研究所',
        ),
      );
      Widget preview(LinkPreviewService source) => AppRoot(
        home: Material(
          child: Center(
            child: SizedBox(
              width: 250,
              child: MessageLinkPreview(
                text: url.toString(),
                service: source,
                fallback: Text(url.toString()),
                onLink: (value) => opened = value,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(preview(service));
      await tester.pumpAndSettle();
      expect(find.text('文章摘要'), findsOneWidget);
      expect(find.text('研究所'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('message-link-card')));
      expect(opened, url.toString());
      await tester.pumpWidget(
        preview(LinkPreviewService(loader: (_) async => null)),
      );
      await tester.pumpAndSettle();
      expect(find.text(url.toString()), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
