import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:file_selector/file_selector.dart';
import 'package:lanflow/ui/chat/attachment_selection_page.dart';
import 'package:lanflow/ui/chat/quote_preview.dart';
import 'package:lanflow/ui/chat/image_viewer.dart';
import 'package:lanflow/ui/chat/share_receiver_page.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();
  final editor = find.byKey(const ValueKey('inbox-composer'));

  Future<void> settleWrites(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
  }

  testWidgets(
    'image preview and returning from background preserve an open editor',
    (tester) async {
      await tester.runAsync(() async {
        final file = File('${harness.directory.path}/preview.png');
        await file.writeAsBytes(png);
        await harness.inbox.addFile(file.path);
      });
      await harness.mount(
        tester,
        platform: TargetPlatform.android,
        size: const Size(390, 844),
      );
      await tester.tap(editor);
      await tester.pump();
      await tester.enterText(editor, '继续编辑');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final focus = tester.widget<TextField>(editor).focusNode!;
      await tester.tap(
        find.byKey(
          ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
        ),
      );
      await settleWrites(tester);
      expect(find.byType(ImageViewer), findsOneWidget);
      expect(focus.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(focus.hasFocus, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.testTextInput.hide();
      tester.view.viewInsets = const FakeViewPadding();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settleWrites(tester);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.widget<TextField>(editor).controller!.text, '继续编辑');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('holding an open editor pastes without closing it', (
    tester,
  ) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lanflow/clipboard'),
          (_) async => null,
        );
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
    await Clipboard.setData(const ClipboardData(text: '保持键盘'));
    await tester.longPress(editor);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tap(find.text('粘贴'));
    await settleWrites(tester);
    expect(tester.widget<TextField>(editor).controller!.text, '保持键盘');
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'failed external share retains the target and offers retry later',
    (tester) async {
      await tester.pumpWidget(
        AppRoot(
          home: ShareReceiverPage(
            inbox: harness.inbox,
            payload: const {'id': 'retry-share', 'text': '保存失败时保留来源'},
            onSend: (_) async => throw const FileSystemException('disk full'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey('share-to-${harness.inbox.conversationId}')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('share-send')));
      await tester.pumpAndSettle();
      expect(find.text('稍后重试'), findsOneWidget);
      expect(find.text('已发送'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('phone home exposes exactly three destinations and draft text', (
    tester,
  ) async {
    await harness.mount(
      tester,
      platform: TargetPlatform.android,
      size: const Size(390, 844),
    );
    await tester.tap(editor);
    await tester.pump();
    await tester.enterText(editor, '稍后继续写');
    await tester.tap(find.byTooltip('返回会话'));
    await tester.pumpAndSettle();
    expect(find.byType(NavigationDestination), findsNWidgets(3));
    expect(find.byKey(const ValueKey('mobile-nav-trash')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-nav-devices')), findsNothing);
    expect(find.text('[草稿] 稍后继续写', findRichText: true), findsOneWidget);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('settings-page-devices')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('settings-page-transfers')),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'message hold preserves the open keyboard and offers text selection and quote',
    (tester) async {
      await tester.runAsync(() => harness.inbox.addText('可以选择其中几个字'));
      await harness.mount(
        tester,
        platform: TargetPlatform.android,
        size: const Size(390, 844),
      );
      await tester.tap(editor);
      await tester.pump();
      await tester.enterText(editor, '编辑中的内容');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final row = find.byKey(
        ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
      );
      final before = tester.getRect(row);
      await tester.longPress(row);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.getRect(row), before);
      expect(find.text('选择文本'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('touch-menu-quote')));
      await settleWrites(tester);
      expect(find.byType(QuotePreview), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, '发送'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await settleWrites(tester);
      expect(harness.inbox.items.first.item.quote?.text, '可以选择其中几个字');
      expect(harness.inbox.store.draftQuotes, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('holding a closed composer pastes without opening the keyboard', (
    tester,
  ) async {
    await harness.mount(
      tester,
      platform: TargetPlatform.android,
      size: const Size(390, 844),
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('lanflow/clipboard'),
          (_) async => null,
        );
    await Clipboard.setData(const ClipboardData(text: '仅粘贴'));
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.longPress(editor);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.text('粘贴'), findsOneWidget);
    await tester.tap(find.text('粘贴'));
    await settleWrites(tester);
    expect(tester.widget<TextField>(editor).controller!.text, '仅粘贴');
    expect(tester.testTextInput.isVisible, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'attachment panel replaces keyboard area and back closes only the panel',
    (tester) async {
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
      final top = tester.getTopLeft(editor).dy;
      await tester.tap(find.byTooltip('添加内容'));
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('attachment-panel')), findsOneWidget);
      expect(tester.getTopLeft(editor).dy, closeTo(top, 1));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(editor, findsOneWidget);
      expect(find.byKey(const ValueKey('attachment-panel')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('attachment check circles control one batch', (tester) async {
    final files = <XFile>[];
    await tester.runAsync(() async {
      for (var i = 0; i < 3; i++) {
        final file = File('${harness.directory.path}/batch-$i.txt');
        await file.writeAsString('batch');
        files.add(XFile(file.path));
      }
    });
    await tester.pumpWidget(
      AppRoot(
        home: AttachmentSelectionPage(files: files, onAdd: () async => []),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('添加 3 个附件'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('attachment-choice-1')));
    await tester.pumpAndSettle();
    expect(find.text('添加 2 个附件'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'external share requires destination and send then offers both return choices',
    (tester) async {
      Map<String, dynamic>? sent;
      await tester.pumpWidget(
        AppRoot(
          home: ShareReceiverPage(
            inbox: harness.inbox,
            payload: const {
              'id': 'incoming-share',
              'text': '分享给自己的链接',
              'files': [],
            },
            onSend: (payload) async {
              sent = payload;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(sent, isNull);
      await tester.tap(
        find.byKey(ValueKey('share-to-${harness.inbox.conversationId}')),
      );
      await tester.pumpAndSettle();
      expect(find.text('分享给自己的链接'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('share-send')));
      await tester.pumpAndSettle();
      expect(sent?['conversationId'], harness.inbox.conversationId);
      expect(find.text('返回原应用'), findsOneWidget);
      expect(find.text('留在 LanFlow'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
