import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/ui/chat/image_viewer.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets('save-as exists only in file right-click and long-press menus', (
    tester,
  ) async {
    final file = File('${harness.directory.path}/参考素材.zip');
    await tester.runAsync(() async {
      await file.writeAsString('test data');
      await harness.inbox.addFile(file.path);
    });
    await harness.mount(tester);
    expect(find.text('另存为'), findsNothing);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
    final card = find.byKey(
      ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
    );
    await tester.tapAt(
      tester.getTopLeft(card) + const Offset(30, 20),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('另存为'), findsOneWidget);
    await tester.tapAt(const Offset(1050, 100));
    await tester.pumpAndSettle();
    expect(find.text('另存为'), findsNothing);
    await tester.longPressAt(tester.getTopLeft(card) + const Offset(30, 20));
    await tester.pumpAndSettle();
    expect(find.text('另存为'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'settings dismiss the keyboard but message menus preserve editing focus',
    (tester) async {
      final file = File('${harness.directory.path}/phone-file.zip');
      await tester.runAsync(() async {
        await file.writeAsString('data');
        await harness.inbox.addFile(file.path);
      });
      await harness.mount(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.android,
      );
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.tap(editor);
      await tester.pump();
      await tester.enterText(editor, '草稿应保留');
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.widget<TextField>(editor).controller!.text, '草稿应保留');
      await tester.tap(editor);
      await tester.pump();
      final message = find.byKey(
        ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
      );
      await tester.longPressAt(tester.getCenter(message));
      await tester.pumpAndSettle();
      expect(find.text('删除'), findsOneWidget);
      expect(find.text('另存为'), findsOneWidget);
      await tester.tapAt(const Offset(380, 100));
      await tester.pumpAndSettle();
      expect(find.text('删除'), findsNothing);
      expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isTrue);
      expect(tester.testTextInput.isVisible, isTrue);
      expect(find.byType(ImageViewer), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'links open through the platform and Escape hides the desktop window',
    (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lanflow/desktop'), (
            call,
          ) async {
            calls.add(call);
            return null;
          });
      await tester.runAsync(
        () => harness.inbox.addText('https://example.com/idea'),
      );
      await harness.mount(tester);
      await tester.tap(find.text('https://example.com/idea').last);
      await tester.pumpAndSettle();
      expect(
        calls.where((c) => c.method == 'openUrl').single.arguments,
        'https://example.com/idea',
      );
      expect(find.text('这台电脑'), findsNothing);
      expect(find.text('本机'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('inbox-composer')),
        '未发送的草稿',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(calls.last.method, 'hideToTray');
      final button = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == '添加文件',
        ),
      );
      expect(
        IconButtonTheme.of(
          tester.element(find.byWidget(button)),
        ).style!.foregroundColor!.resolve({}),
        isNot(Colors.white),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'Escape dismisses nested dialogs without hiding or refocusing the editor',
    (tester) async {
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('lanflow/desktop'), (
            call,
          ) async {
            calls.add(call.method);
            return null;
          });
      await harness.mount(tester);
      await tester.enterText(
        find.byKey(const ValueKey('inbox-composer')),
        '保留输入',
      );
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑设备名称与头像'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '设备名称',
        ),
        '临时编辑名称',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-panel')), findsNothing);
      expect(calls, isNot(contains('hideToTray')));
      expect(tester.testTextInput.isVisible, isFalse);
      await tester.tap(find.byTooltip('我的设备').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('添加 NAS'));
      await tester.tap(find.text('添加 NAS'));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-page-devices')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('我的设备与 NAS'), findsNothing);
      expect(calls, isNot(contains('hideToTray')));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'one right click retargets the menu; outside clicks reach controls',
    (tester) async {
      await tester.runAsync(() async {
        await harness.inbox.addText('第一条右键消息');
        await harness.inbox.addText('第二条右键消息');
      });
      await harness.mount(tester);
      final older = harness.inbox.items.last.item;
      final newer = harness.inbox.items.first.item;
      final first = find.byKey(ValueKey('inbox-item-${older.id}'));
      final second = find.byKey(ValueKey('inbox-item-${newer.id}'));
      // Open below the first bubble, then right-click above it on another.
      await tester.tapAt(
        tester.getCenter(second),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await tester.tapAt(
        tester.getCenter(first),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('desktop-context-menu')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('desktop-menu-copy')));
      await tester.pumpAndSettle();
      expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, older.text);

      await tester.tapAt(
        tester.getCenter(first),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.tap(editor);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desktop-context-menu')), findsNothing);
      expect(tester.widget<TextField>(editor).focusNode!.hasFocus, isTrue);

      await tester.tapAt(
        tester.getCenter(first),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('settings-panel')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('desktop message selection copies a range and preserves links', (
    tester,
  ) async {
    const text = 'alpha beta gamma delta';
    await tester.runAsync(() => harness.inbox.addText(text));
    await harness.mount(tester);
    final bubble = find.byKey(
      ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
    );
    final rich = find.descendant(of: bubble, matching: find.byType(RichText));
    final bounds = tester.getRect(rich.first);
    final mouse = await tester.startGesture(
      bounds.topLeft + const Offset(2, 8),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(bounds.topLeft + const Offset(90, 8));
    await mouse.up();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final copied = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    expect(copied, isNotEmpty);
    expect(copied, isNot(text));
    expect(text, contains(copied!));
    await tester.tapAt(
      bounds.topLeft + const Offset(20, 8),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('复制选中文字'), findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(rich.first);
    expect(
      paragraph.selections.any((selection) => !selection.isCollapsed),
      isTrue,
      reason:
          'The selected range must remain highlighted while the menu is open',
    );
    expect(Focus.of(tester.element(rich.first)).hasFocus, isTrue);
    await tester.tap(find.text('复制选中文字'));
    await tester.pumpAndSettle();
    expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, copied);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Escape works after blank clicks, menu dismissal and search', (
    tester,
  ) async {
    var hidden = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('lanflow/desktop'), (
          call,
        ) async {
          if (call.method == 'hideToTray') hidden++;
          return null;
        });
    await tester.runAsync(() => harness.inbox.addText('快捷键测试'));
    await harness.mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hidden, 1);
    await tester.tapAt(const Offset(800, 300));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hidden, 2);
    await tester.tapAt(
      tester.getCenter(
        find.byKey(
          ValueKey('inbox-item-${harness.inbox.items.single.item.id}'),
        ),
      ),
      buttons: kSecondaryMouseButton,
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hidden, 2);
    expect(find.byKey(const ValueKey('desktop-context-menu')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hidden, 3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('global-conversation-search'))).focusNode!.hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hidden, 3);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('global-conversation-search'))).focusNode!.hasFocus, isFalse);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hidden, 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(hidden, 4);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: !Platform.isWindows);

  testWidgets(
    'desktop menu supports keys, scroll dismissal and target deletion',
    (tester) async {
      await tester.runAsync(() async {
        await harness.inbox.addText('保留这条消息');
        await harness.inbox.addText('删除这条消息');
      });
      await harness.mount(tester);
      final target = harness.inbox.items.first.item;
      final bubble = find.byKey(ValueKey('inbox-item-${target.id}'));
      await tester.tapAt(
        tester.getCenter(bubble),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        target.text,
      );
      await tester.tapAt(
        tester.getCenter(bubble),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await tester.sendEventToBinding(
        const PointerScrollEvent(
          position: Offset(600, 200),
          scrollDelta: Offset(0, 50),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('desktop-context-menu')), findsNothing);
      await tester.tapAt(
        tester.getCenter(bubble),
        buttons: kSecondaryMouseButton,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('desktop-menu-delete')));
      await tester.pump();
      for (var i = 0; i < 40 && harness.inbox.items.length != 1; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(harness.inbox.items.single.item.text, '保留这条消息');
      expect(find.byKey(ValueKey('inbox-item-${target.id}')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
