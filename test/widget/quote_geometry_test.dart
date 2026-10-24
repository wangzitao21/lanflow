import 'dart:async';
import 'dart:io';
// The platform interface controls the non-Windows picker without native IO.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/chat/chat_composer.dart';
import 'package:lanflow/ui/chat/image_viewer.dart';
import '../support/widget_harness.dart';

class _ControlledSelector extends FileSelectorPlatform {
  _ControlledSelector(this.pending);

  final Future<List<String>> pending;
  int calls = 0;

  @override
  Future<List<XFile>> openFiles({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    calls++;
    return [for (final path in await pending) XFile(path)];
  }
}

void main() {
  final harness = WidgetTestHarness();
  final editor = find.byKey(const ValueKey('inbox-composer'));
  final quote = find.byKey(const ValueKey('composer-quote'));

  Future<void> prepare(WidgetTester tester, {bool photo = false}) async {
    await tester.runAsync(() async {
      late InboxItem item;
      if (photo) {
        final file = File(
          '${harness.directory.path}/long-clipboard-image-name.png',
        );
        await file.writeAsBytes(png);
        item = (await harness.inbox.addFile(file.path)).item;
      } else {
        item = (await harness.inbox.addText('那就对了'))!.item;
      }
      await harness.inbox.setDraftQuote(MessageQuote.fromItem(item));
      harness.inbox.store.draft = '未发送的内容';
    });
  }

  testWidgets(
    'desktop quote is a compact left-aligned row below the editor and above tools',
    (tester) async {
      await prepare(tester);
      await harness.mount(tester);
      final field = tester.getRect(editor);
      final preview = tester.getRect(quote);
      final toolbar = tester.getRect(find.byTooltip('添加图片或视频'));
      expect(preview.left, closeTo(field.left, 1));
      expect(preview.top, greaterThanOrEqualTo(field.bottom));
      expect(preview.bottom, lessThanOrEqualTo(toolbar.top + 1));
      expect(preview.height, lessThanOrEqualTo(32));
      expect(preview.width, lessThan(field.width * .6));
      expect(
        (tester.widget<Container>(quote).decoration! as BoxDecoration).color,
        isNull,
      );
      await tester.tap(editor);
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('取消引用'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(quote, findsNothing);
      expect(tester.widget<TextField>(editor).controller!.text, '未发送的内容');
      expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final language in ['zh', 'en']) {
    testWidgets('mobile $language quote aligns exactly below the text box', (
      tester,
    ) async {
      await prepare(tester, photo: true);
      await tester.runAsync(() => harness.inbox.setLanguage(language));
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await harness.mount(
        tester,
        platform: TargetPlatform.android,
        size: const Size(390, 844),
      );
      final field = tester.getRect(editor);
      final preview = tester.getRect(quote);
      expect(preview.top, closeTo(field.bottom + 4, 1));
      expect(preview.left, closeTo(field.left, 1));
      expect(preview.right, closeTo(field.right, 1));
      final label = tester.widget<Text>(
        find.byKey(const ValueKey('composer-quote-label')),
      );
      expect(label.maxLines, 1);
      expect(label.data, isNot(contains('[image]')));
      expect(label.data, isNot(contains('clipboard-image-name')));
      expect(
        find.byKey(
          ValueKey('quote-thumbnail-${harness.inbox.items.single.item.id}'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'opening and closing images keeps the composer fixed through transient IME insets',
    (tester) async {
      await prepare(tester, photo: true);
      await harness.mount(
        tester,
        platform: TargetPlatform.android,
        size: const Size(390, 844),
      );
      await tester.tap(editor);
      await tester.pump();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final before = tester.getRect(editor);
      final quoted = tester.getRect(quote);
      await tester.tap(
        find.byKey(
          ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
        ),
      );
      await tester.pump();
      for (final metrics in [
        (844.0, 280.0),
        (844.0, 0.0),
        (700.0, 0.0),
        (844.0, 120.0),
        (844.0, 280.0),
      ]) {
        tester.view.physicalSize = Size(390, metrics.$1);
        tester.view.viewInsets = FakeViewPadding(bottom: metrics.$2);
        await tester.pump(const Duration(milliseconds: 70));
        expect(tester.getRect(editor), before);
        expect(tester.getRect(quote), quoted);
      }
      expect(find.byType(ImageViewer), findsOneWidget);
      expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isTrue);
      await tester.tap(find.byTooltip('关闭图片'));
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pump(const Duration(milliseconds: 80));
      expect(tester.getRect(editor), before);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(editor), before);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.getRect(editor), before);
      expect(tester.widget<TextField>(editor).controller!.text, '未发送的内容');
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('native attachment picker also preserves the editing position', (
    tester,
  ) async {
    await prepare(tester);
    final gate = Completer<List<String>>();
    final previousSelector = FileSelectorPlatform.instance;
    final selector = _ControlledSelector(gate.future);
    FileSelectorPlatform.instance = selector;
    const channel = MethodChannel('lanflow/file_picker');
    var nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method != 'openFiles') return null;
          nativeCalls++;
          return gate.future;
        });
    addTearDown(() {
      if (!gate.isCompleted) gate.complete([]);
      FileSelectorPlatform.instance = previousSelector;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
    await harness.mount(
      tester,
      platform: TargetPlatform.android,
      size: const Size(390, 844),
    );
    await tester.tap(editor);
    await tester.pump();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final before = tester.getRect(editor);
    var pickerFinished = false;
    final picking = tester
        .widget<ChatComposer>(find.byType(ChatComposer))
        .onPick(true)
        .whenComplete(() => pickerFinished = true);
    tester.view.viewInsets = const FakeViewPadding();
    await tester.pumpAndSettle();
    expect(nativeCalls, Platform.isWindows ? 1 : 0);
    expect(selector.calls, Platform.isWindows ? 0 : 1);
    expect(pickerFinished, isFalse);
    expect(tester.getRect(editor), before);
    gate.complete([]);
    await tester.pump();
    expect(pickerFinished, isTrue);
    await picking;
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(editor), before);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(tester.getRect(editor), before);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
