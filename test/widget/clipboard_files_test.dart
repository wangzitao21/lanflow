import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/chat_composer.dart';

import '../support/widget_harness.dart';
import 'message_selection_test.dart' show waitForStorage;

void main() {
  final harness = WidgetTestHarness();
  const channel = MethodChannel('lanflow/clipboard');
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);
  bool prepared(WidgetTester tester) =>
      !tester.widget<ChatComposer>(find.byType(ChatComposer)).preparing;

  void clipboard(Future<Object?> Function(MethodCall) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
  }

  Future<void> paste(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('inbox-composer')));
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
  }

  testWidgets(
    'Explorer photos become attachments with original names and bytes',
    (tester) async {
      final files = [
        File('${harness.directory.path}/旅行 照片 🌈.jpg'),
        File('${harness.directory.path}/second.png'),
      ];
      await tester.runAsync(() async {
        for (final file in files) {
          await file.writeAsBytes(png);
        }
      });
      final calls = <String>[];
      clipboard((call) async {
        calls.add(call.method);
        return call.method == 'readFiles'
            ? files.map((file) => file.path).toList()
            : png;
      });
      await harness.mount(tester);
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(editor, 'Keep my draft');
      await paste(tester);
      await waitForStorage(
        tester,
        () =>
            harness.inbox.store.draftAttachments.length == 2 &&
            prepared(tester),
      );
      expect(calls, ['readFiles']);
      expect(
        tester.widget<TextField>(editor).controller!.text,
        'Keep my draft',
      );
      expect(harness.inbox.items, isEmpty);
      expect(harness.inbox.store.draftAttachments.map((item) => item.name), [
        '旅行 照片 🌈.jpg',
        'second.png',
      ]);
      expect(
        harness.inbox.store.draftAttachments.every(
          (item) => item.kind == MessageKind.image,
        ),
        isTrue,
      );
      await tester.runAsync(() async {
        await harness.inbox.sendDraftAttachments();
        for (final entry in harness.inbox.items) {
          expect(
            await harness.inbox.store.blob(entry.item.digest).readAsBytes(),
            png,
          );
        }
      });
      expect(harness.inbox.items, hasLength(2));
      expect(tester.takeException(), isNull);
    },
    variant: windows,
  );

  testWidgets('a pending file paste keeps its original conversation', (
    tester,
  ) async {
    final read = Completer<Object?>();
    late Conversation other;
    final file = File('${harness.directory.path}/photo.png');
    await tester.runAsync(() async {
      await file.writeAsBytes(png);
      other = await harness.inbox.createConversation('Other');
      harness.inbox.selectConversation(defaultConversationId);
    });
    clipboard((call) => read.future);
    await harness.mount(tester);
    await paste(tester);
    harness.inbox.selectConversation(other.id);
    await tester.pump();
    read.complete([file.path]);
    await waitForStorage(
      tester,
      () =>
          harness.inbox.store.attachmentDrafts[defaultConversationId]?.length ==
              1 &&
          prepared(tester),
    );
    expect(harness.inbox.conversationId, other.id);
    expect(harness.inbox.store.draftAttachments, isEmpty);
    expect(tester.takeException(), isNull);
  }, variant: windows);

  testWidgets('screenshot and text paste still work without a file list', (
    tester,
  ) async {
    var image = true;
    clipboard((call) async {
      if (call.method == 'readFiles') return <String>[];
      return image ? png : null;
    });
    await harness.mount(tester);
    await paste(tester);
    await waitForStorage(
      tester,
      () =>
          harness.inbox.store.draftAttachments.length == 1 && prepared(tester),
    );
    expect(harness.inbox.store.draftAttachments.single.kind, MessageKind.image);
    image = false;
    await Clipboard.setData(const ClipboardData(text: 'Pasted text'));
    await paste(tester);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('inbox-composer')))
          .controller!
          .text,
      'Pasted text',
    );
    expect(harness.inbox.store.draftAttachments, hasLength(1));
    expect(tester.takeException(), isNull);
  }, variant: windows);
}
