import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/ui/chat/message_selection.dart';
import '../support/widget_harness.dart';

Future<void> settleWorkspace(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  await tester.pumpAndSettle();
}

void main() {
  final harness = WidgetTestHarness();
  testWidgets(
    'desktop destinations have identical targets and spacing and switch within the window',
    (tester) async {
      await tester.runAsync(() async {
        final entry = await harness.inbox.addText('A saved favorite');
        await harness.inbox.setFavorites([entry!.item.id], true);
      });
      await harness.mount(tester);
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(editor, 'Keep this draft across destinations');
      final rail = tester.getRect(
        find.byKey(const ValueKey('desktop-navigation-rail')),
      );
      final rectangles = [
        for (final section in [
          'conversations',
          'favorites',
          'trash',
        ])
          tester.getRect(find.byKey(ValueKey('desktop-nav-$section'))),
      ];
      for (final rect in rectangles) {
        expect(rect.size, const Size(44, 44));
        expect(rect.center.dx, rectangles.first.center.dx);
      }
      for (var i = 1; i < rectangles.length; i++) {
        expect(rectangles[i].top - rectangles[i - 1].top, 56);
      }
      for (final section in ['favorites', 'trash']) {
        await tester.tap(find.byKey(ValueKey('desktop-nav-$section')));
        await settleWorkspace(tester);
        expect(find.byType(Dialog), findsNothing);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.byKey(ValueKey('desktop-page-$section')), findsOneWidget);
        expect(find.byKey(const ValueKey('inbox-composer')), findsNothing);
        expect(
          tester.getRect(find.byKey(const ValueKey('desktop-navigation-rail'))),
          rail,
        );
      }
      await tester.tap(find.byKey(const ValueKey('desktop-nav-favorites')));
      await settleWorkspace(tester);
      await tester.enterText(
        find.byKey(const ValueKey('favorites-search')),
        'saved',
      );
      await tester.tap(find.byKey(const ValueKey('desktop-nav-conversations')));
      await settleWorkspace(tester);
      expect(
        tester.widget<TextField>(editor).controller!.text,
        'Keep this draft across destinations',
      );
      await tester.tap(find.byKey(const ValueKey('desktop-nav-favorites')));
      await settleWorkspace(tester);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('favorites-search')))
            .controller!
            .text,
        'saved',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'favorite details return to the saved search before leaving the workspace',
    (tester) async {
      late String favoriteId;
      await tester.runAsync(() async {
        final entry = await harness.inbox.addText('Saved reference');
        await harness.inbox.setFavorites([entry!.item.id], true);
        favoriteId = harness.inbox.favoriteEntries.single.id;
      });
      await harness.mount(tester);
      await tester.tap(find.byKey(const ValueKey('desktop-nav-favorites')));
      await settleWorkspace(tester);
      final search = find.byKey(const ValueKey('favorites-search'));
      await tester.enterText(search, 'reference');
      await tester.pumpAndSettle(const Duration(milliseconds: 120));
      await tester.tap(find.byKey(ValueKey('favorite-$favoriteId')));
      await settleWorkspace(tester);
      expect(
        find.byKey(const ValueKey('favorite-detail-copy')),
        findsOneWidget,
      );
      expect(find.byType(Dialog), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleWorkspace(tester);
      expect(find.byKey(const ValueKey('favorite-detail-copy')), findsNothing);
      expect(tester.widget<TextField>(search).controller!.text, 'reference');
      expect(
        find.byKey(const ValueKey('desktop-page-favorites')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settleWorkspace(tester);
      expect(find.byKey(const ValueKey('inbox-composer')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'phone recycle bin opens from home and returns without an extra window',
    (tester) async {
      await harness.mount(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.android,
        openMobileChat: false,
      );
      await tester.tap(find.byKey(const ValueKey('mobile-nav-trash')));
      await settleWorkspace(tester);
      expect(find.byKey(const ValueKey('trash-search')), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byKey(const ValueKey('mobile-navigation')), findsOneWidget);
      await tester.binding.handlePopRoute();
      await settleWorkspace(tester);
      expect(find.byKey(const ValueKey('trash-search')), findsNothing);
      expect(find.byKey(const ValueKey('mobile-navigation')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new conversation is created immediately with its entire inline name selected',
    (tester) async {
      await harness.mount(tester);
      final before = harness.inbox.conversations.length;
      await tester.tap(find.byTooltip('新建会话'));
      await settleWorkspace(tester);
      expect(harness.inbox.conversations.length, before + 1);
      expect(harness.inbox.conversation.name, '新建会话');
      expect(find.byType(AlertDialog), findsNothing);
      final field = find.byKey(const ValueKey('conversation-name'));
      final controller = tester.widget<TextField>(field).controller!;
      expect(
        controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 4),
      );
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await tester.enterText(field, '项目草稿');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settleWorkspace(tester);
      expect(harness.inbox.conversation.name, '项目草稿');
      expect(find.byKey(const ValueKey('conversation-name')), findsNothing);
      await tester.tap(find.byTooltip('新建会话'));
      await settleWorkspace(tester);
      await tester.tap(find.byKey(const ValueKey('desktop-nav-favorites')));
      await settleWorkspace(tester);
      expect(
        harness.inbox.conversations.where((c) => c.name == '新建会话'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'multi-select keeps the editor area and restores its draft after the action panel closes',
    (tester) async {
      await tester.runAsync(() async {
        await harness.inbox.addText('Select this message');
      });
      await harness.mount(tester);
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(editor, 'Unsent draft');
      final panel = find.byKey(const ValueKey('chat-composer-panel'));
      final bounds = tester.getRect(panel);
      final controller = tester.widget<TextField>(editor).controller;
      await tester.tap(find.byTooltip('多选消息'));
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), bounds);
      expect(editor.hitTestable(), findsNothing);
      expect(controller!.text, 'Unsent draft');
      expect(
        find.byKey(const ValueKey('delete-selected-messages')),
        findsOneWidget,
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      final selection = tester
          .widget<SelectableMessage>(find.byType(SelectableMessage).first)
          .selection;
      expect(selection.ids, hasLength(1));
      expect(harness.inbox.items, hasLength(1));
      expect(find.byType(AlertDialog), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), bounds);
      expect(editor.hitTestable(), findsOneWidget);
      expect(tester.widget<TextField>(editor).controller, same(controller));
      expect(controller.text, 'Unsent draft');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'attachment picker opens once and stages the result in the original conversation',
    (tester) async {
      const channel = MethodChannel('lanflow/file_picker');
      final picked = Completer<List<String>>();
      var calls = 0;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'openFiles') {
          calls++;
          return picked.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      late File attachment;
      await tester.runAsync(() async {
        attachment = await File(
          '${harness.directory.path}/picker-result.txt',
        ).writeAsString('Keep this in the original draft');
      });
      await harness.mount(tester);
      final original = harness.inbox.conversationId;
      try {
        await tester.tap(find.byTooltip('添加文件'));
        await tester.pump();
        expect(calls, 1);
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.folder_open_outlined),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.image_outlined),
              )
              .onPressed,
          isNull,
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull);
        await tester.runAsync(() async {
          final next = await harness.inbox.createConversation(
            'Other conversation',
          );
          harness.inbox.selectConversation(next.id);
          picked.complete([attachment.path]);
        });
        for (
          var i = 0;
          i < 100 &&
              (harness.inbox.store.attachmentDrafts[original]?.isEmpty ?? true);
          i++
        ) {
          await settleWorkspace(tester);
        }
        expect(harness.inbox.store.attachmentDrafts[original], hasLength(1));
        expect(harness.inbox.store.draftAttachments, isEmpty);
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      } finally {
        if (!picked.isCompleted) picked.complete([]);
        await settleWorkspace(tester);
      }
    },
    skip: !Platform.isWindows,
  );
}
