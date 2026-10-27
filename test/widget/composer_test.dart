import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets(
    'empty inbox stays idle and saves offline without selecting a device',
    (tester) async {
      await harness.mount(tester);
      expect(find.text('发给自己'), findsNWidgets(2));
      expect(find.text('给自己发条消息吧'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('inbox-composer')),
        '在地铁上想到的新想法',
      );
      await tester.pump();
      await tester.runAsync(() async {
        final action = tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
            .onPressed!;
        await Function.apply(action, const []);
      });
      await tester.pumpAndSettle();
      expect(harness.inbox.items.single.item.text, '在地铁上想到的新想法');
      expect(find.text('消息详情'), findsNothing);
      expect(
        find.byKey(
          ValueKey('sync-badge-${harness.inbox.items.single.item.id}'),
        ),
        findsOneWidget,
      );
      expect(find.text('接收'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('IME composition is not sent by Enter or save', (tester) async {
    await harness.mount(tester);
    final field = find.byKey(const ValueKey('inbox-composer'));
    await tester.enterText(field, '正在输入');
    final composer = tester.widget<TextField>(field).controller!;
    composer.value = composer.value.copyWith(
      composing: const TextRange(start: 0, end: 4),
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '发送'));
    expect(harness.inbox.items, isEmpty);
    expect(composer.text, '正在输入');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('desktop clipboard image previews in the composer before save', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lanflow/clipboard'),
          (call) async => png,
        );
    await harness.mount(tester);
    await tester.tap(find.byKey(const ValueKey('inbox-composer')));
    await tester.runAsync(() async {
      final shortcuts = tester.widget<CallbackShortcuts>(
        find.byType(CallbackShortcuts).last,
      );
      shortcuts.bindings[const SingleActivator(
        LogicalKeyboardKey.keyV,
        control: true,
      )]!();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      // Decode real files outside the widget test's fake async zone. Otherwise
      // FileImage's native file mapping can remain open after the test unmounts.
      final provider = FileImage(
        harness.inbox.store.blob(
          harness.inbox.store.draftAttachments.single.digest,
        ),
      );
      final context = tester.element(
        find.byKey(const ValueKey('inbox-composer')),
      );
      await precacheImage(
        provider,
        context,
      ).timeout(const Duration(seconds: 10));
      if (!context.mounted) return;
      await precacheImage(
        ResizeImage(
          provider,
          width: ChatMetrics.imageWidthDesktop.toInt(),
          height: ChatMetrics.imageHeightDesktop.toInt(),
          policy: ResizeImagePolicy.fit,
          allowUpscaling: false,
        ),
        context,
      ).timeout(const Duration(seconds: 10));
      await precacheImage(
        ResizeImage(provider, width: 264, allowUpscaling: false),
        context,
      ).timeout(const Duration(seconds: 10));
    });
    await tester.pumpAndSettle();
    expect(harness.inbox.items, isEmpty);
    expect(harness.inbox.store.draftAttachments, hasLength(1));
    expect(
      find.byKey(
        ValueKey(
          'draft-image-${harness.inbox.store.draftAttachments.single.id}',
        ),
      ),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      final action = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '发送'))
          .onPressed!;
      await Function.apply(action, const []);
    });
    await tester.pumpAndSettle();
    expect(harness.inbox.items, hasLength(1));
    expect(harness.inbox.store.draftAttachments, isEmpty);
    expect(find.text('另存为'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets('send retains typing focus and Shift Enter inserts a newline', (
    tester,
  ) async {
    await harness.mount(tester);
    final field = find.byKey(const ValueKey('inbox-composer'));
    await tester.enterText(field, '第一行');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text, contains('\n'));
    expect(harness.inbox.items, isEmpty);
    await tester.enterText(field, '发送后继续输入');
    await tester.runAsync(() => harness.inbox.store.save());
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, '发送'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(harness.inbox.items.single.item.text, '发送后继续输入');
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
    await tester.runAsync(() async {
      final reopened = InboxStore(harness.inbox.store.directory);
      await reopened.load();
      expect(reopened.draft, isEmpty);
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('clipboard image keeps its original category across a switch', (
    tester,
  ) async {
    final pending = Completer<Uint8List?>();
    var requested = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lanflow/clipboard'), (
          _,
        ) {
          requested = true;
          return pending.future;
        });
    late Conversation other;
    await tester.runAsync(() async {
      other = await harness.inbox.createConversation('工作');
      harness.inbox.selectConversation(defaultConversationId);
    });
    await harness.mount(tester);
    await tester.tap(find.byKey(const ValueKey('inbox-composer')));
    await tester.runAsync(() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(requested, isTrue);
    await tester.pump();
    await tester.tap(find.byKey(ValueKey('conversation-${other.id}')));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      pending.complete(png);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
    expect(
      harness.inbox.store.attachmentDrafts[defaultConversationId],
      hasLength(1),
    );
    expect(harness.inbox.store.draftAttachments, isEmpty);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('inbox-composer')))
          .focusNode!
          .hasFocus,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets(
    'desktop composer stays stable at startup and resizes from its divider',
    (tester) async {
      harness.lan.ready = false;
      await harness.mount(tester);
      final panel = find.byKey(const ValueKey('chat-composer-panel'));
      final before = tester.getRect(panel);
      harness.lan.ready = true;
      harness.inbox.selectConversation(defaultConversationId);
      await tester.pumpAndSettle();
      expect(tester.getRect(panel), before);
      await tester.drag(
        find.byKey(const ValueKey('composer-resize-handle')),
        const Offset(0, -80),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(panel).height, greaterThan(before.height + 50));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('file drop covers the composer and is disabled behind a dialog', (
    tester,
  ) async {
    final file = File('${harness.directory.path}/drag-file.zip');
    await tester.runAsync(() => file.writeAsString('drop data'));
    await harness.mount(tester);
    final area = find.byKey(const ValueKey('chat-drop-area'));
    final editor = find.byKey(const ValueKey('inbox-composer'));
    expect(tester.getRect(area).contains(tester.getCenter(editor)), isTrue);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(tester.widget<DropTarget>(area).enable, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.widget<DropTarget>(area).enable, isTrue);
    final point = tester.getCenter(editor);
    await tester.runAsync(() async {
      tester.widget<DropTarget>(area).onDragDone!(
        DropDoneDetails(
          files: [DropItemFile(file.path)],
          localPosition: point - tester.getTopLeft(area),
          globalPosition: point,
        ),
      );
      await harness.waitFor(
        () => harness.inbox.store.draftAttachments.isNotEmpty,
      );
    });
    await tester.pumpAndSettle();
    expect(harness.inbox.items, isEmpty);
    expect(harness.inbox.store.draftAttachments.single.name, 'drag-file.zip');
    final send = find.widgetWithText(FilledButton, '发送');
    for (
      var attempt = 0;
      attempt < 250 && tester.widget<FilledButton>(send).onPressed == null;
      attempt++
    ) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    expect(
      tester.widget<FilledButton>(send).onPressed,
      isNotNull,
      reason: 'Wait until the attachment is saved and Send becomes available.',
    );
    await tester.runAsync(() async {
      await Function.apply(
        tester.widget<FilledButton>(send).onPressed!,
        const [],
      );
    });
    await tester.pumpAndSettle();
    expect(harness.inbox.items.single.item.name, 'drag-file.zip');
    expect(harness.inbox.store.draftAttachments, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
