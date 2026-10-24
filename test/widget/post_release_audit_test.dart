import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/message_text.dart';
import 'package:lanflow/ui/shared/app_panel.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  testWidgets(
    'highlighted phrases can cross link boundaries without breaking link actions',
    (tester) async {
      const text = '请访问 https://example.com/notes 获取资料';
      String? opened;
      for (final query in ['访问 https://example.com', 'notes 获取']) {
        await tester.pumpWidget(
          MaterialApp(
            theme: chatTheme(Brightness.dark),
            home: Scaffold(
              body: Center(
                child: MessageText(
                  text: text,
                  highlightQuery: query,
                  onLink: (value) => opened = value,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final rich = find.descendant(
          of: find.byType(MessageText),
          matching: find.byType(RichText),
        );
        final span = tester.widget<RichText>(rich.first).text;
        final marked = StringBuffer();
        span.visitChildren((part) {
          if (part is TextSpan && part.style?.backgroundColor != null) {
            marked.write(part.text);
          }
          return true;
        });
        expect(marked.toString(), query);
        final paragraph = tester.renderObject<RenderParagraph>(rich.first);
        final start = text.indexOf('example');
        final box = paragraph
            .getBoxesForSelection(
              TextSelection(baseOffset: start, extentOffset: start + 7),
            )
            .first;
        await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
        expect(opened, 'https://example.com/notes');
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'search controls stay visible and scrolling does not reopen the phone keyboard',
    (tester) async {
      harness.inbox.store.applySnapshot({
        'revision': harness.inbox.store.revision + 1,
        'profiles': Map.of(harness.inbox.store.profiles),
        'entries': [
          for (var i = 0; i < 150; i++)
            {
              'sequence': i + 1,
              'item': InboxItem(
                id: 'focus-search-${i.toString().padLeft(5, '0')}',
                originId: harness.lan.identity.id,
                originName: harness.lan.name,
                createdAt: DateTime.utc(2026, 10, 21).add(Duration(seconds: i)),
                kind: MessageKind.text,
                text: '检索关键词 $i',
              ).toJson(),
              'copies': <String>[],
            },
        ],
      });
      await harness.mount(
        tester,
        size: const Size(390, 844),
        platform: TargetPlatform.android,
      );
      await harness.openGlobalSearch(tester);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('global-conversation-search'));
      await tester.enterText(input, '关键词');
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      final results = find.byKey(const ValueKey('message-search-results'));
      await tester.drag(results, const Offset(0, -1800));
      await tester.pumpAndSettle();
      expect(input, findsOneWidget);
      expect(tester.testTextInput.isVisible, isFalse);
      tester.widget<ListView>(results).controller!.jumpTo(0);
      await tester.pumpAndSettle();
      final editable = tester.widget<EditableText>(
        find.descendant(of: input, matching: find.byType(EditableText)),
      );
      expect(editable.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'pending NAS binding disables editing and every dismissal path until it finishes',
    (tester) async {
      final inbox = harness.inbox as WidgetInbox;
      final gate = inbox.hubGate = Completer<void>();
      addTearDown(() async {
        if (!gate.isCompleted) gate.completeError(StateError('cancelled test'));
        await tester.pump();
      });
      await harness.mount(tester);
      await tester.tap(find.byTooltip('我的设备').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('添加 NAS'));
      await tester.tap(find.text('添加 NAS'));
      await tester.pumpAndSettle();
      final panel = find.byWidgetPredicate(
        (w) => w is AppPanel && w.title == '添加 NAS',
      );
      await tester.tap(find.widgetWithText(FilledButton, '连接'));
      await tester.pump();
      expect(inbox.hubCalls, 1);
      for (final field in tester.widgetList<TextField>(
        find.descendant(of: panel, matching: find.byType(TextField)),
      )) {
        expect(field.enabled, isFalse);
      }
      final close = find.descendant(
        of: panel,
        matching: find.byWidgetPredicate(
          (w) => w is IconButton && w.tooltip == '关闭',
        ),
      );
      expect(tester.widget<IconButton>(close).onPressed, isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(panel, findsOneWidget);
      gate.completeError(StateError('private connection error'));
      await tester.pumpAndSettle();
      expect(find.text('连接失败，请检查 NAS 地址和连接码'), findsOneWidget);
      expect(find.textContaining('private connection'), findsNothing);
      expect(tester.widget<IconButton>(close).onPressed, isNotNull);
      await tester.tap(close);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'profile saving rejects duplicate submission and locks avatar changes',
    (tester) async {
      final inbox = harness.inbox as WidgetInbox;
      final gate = inbox.profileGate = Completer<void>();
      addTearDown(() async {
        if (!gate.isCompleted) gate.completeError(StateError('cancelled test'));
        await tester.pump();
      });
      await harness.mount(tester);
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑设备名称与头像'));
      await tester.pumpAndSettle();
      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '保存'),
      );
      save.onPressed!();
      save.onPressed!();
      await tester.pump();
      expect(inbox.profileCalls, 1);
      final avatar = find.descendant(
        of: find.byTooltip('更换头像'),
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(avatar).onTap, isNull);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (w) => w is IconButton && w.tooltip == '关闭',
              ),
            )
            .onPressed,
        isNull,
      );
      gate.completeError(StateError('private storage error'));
      await tester.pumpAndSettle();
      expect(find.text('保存失败，请重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
