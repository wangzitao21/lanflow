import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/message_search_panel.dart';
import 'package:lanflow/ui/chat/message_text.dart';
import 'package:lanflow/ui/settings/settings_panel.dart';
import 'package:lanflow/ui/settings/transfer_dialog.dart';
import 'package:lanflow/ui/shared/chat_theme.dart';
import 'package:lanflow/ui/shared/search_text.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  test(
    'snippets expose a late literal match without splitting emoji characters',
    () {
      final value = '${'前言 ' * 80}🙂报告[Q4]🙂${' 说明' * 80}';
      final snippet = searchExcerpt(value, '报告[Q4]');
      expect(snippet, contains('🙂报告[Q4]🙂'));
      expect(snippet.length, lessThan(160));
      expect(searchPattern('[Q4]')!.hasMatch('报告Q4'), isFalse);
      expect(searchPattern('[Q4]')!.hasMatch('报告[q4]'), isTrue);
    },
  );

  testWidgets('highlighted link text still opens its original full URL', (
    tester,
  ) async {
    String? opened;
    const value = '访问 https://example.com/path 查看';
    await tester.pumpWidget(
      MaterialApp(
        theme: chatTheme(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: MessageText(
              text: value,
              highlightQuery: 'EXAMPLE',
              selectable: true,
              onLink: (url) => opened = url,
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
    final paragraph = tester.renderObject<RenderParagraph>(rich.first);
    final start = value.indexOf('example');
    final box = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: start, extentOffset: start + 7),
        )
        .first;
    await tester.tapAt(paragraph.localToGlobal(box.toRect().center));
    await tester.pump();
    expect(opened, 'https://example.com/path');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('devices and transfers are available inside settings, recovery stays on home', (tester) async {
    await harness.mount(tester);
    expect(find.byKey(const ValueKey('desktop-nav-transfers')), findsNothing);
    await harness.openSettingsPage(tester, 'transfers');
    expect(find.byType(TransferDialog), findsOneWidget);
    expect(find.byType(SettingsPanel), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-page-storage')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-page-devices')), findsOneWidget);
    await harness.closeSettings(tester);
    expect(find.byKey(const ValueKey('desktop-nav-trash')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'search scopes match literal keywords in text and filenames and retain results on return',
    (tester) async {
      late InboxEntry local, remote;
      await tester.runAsync(() async {
        local = (await harness.inbox.addText('报告[Q4] 本机记录'))!;
        final file = File('${harness.directory.path}/报告[Q4].zip');
        await file.writeAsString('file');
        await harness.inbox.addFile(file.path);
        await harness.inbox.createConversation('工作');
        remote = (await harness.inbox.addText('其他会话的报告[q4]'))!;
        await harness.inbox.addText('报告Q4 不匹配方括号');
        harness.inbox.selectConversation(defaultConversationId);
      });
      await harness.mount(tester);
      await harness.openGlobalSearch(tester);
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('global-conversation-search'));
      await tester.enterText(input, '报告[Q4]');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('search-scope-current')));
      await tester.pumpAndSettle();
      expect(find.text('范围：发给自己'), findsOneWidget);
      expect(find.text('2 条匹配消息'), findsOneWidget);
      expect(
        find.byKey(ValueKey('search-result-${remote.item.id}')),
        findsNothing,
      );
      final result = find.byKey(ValueKey('search-result-${local.item.id}'));
      final spans = tester
          .widget<Text>(
            find
                .descendant(
                  of: result,
                  matching: find.byWidgetPredicate(
                    (w) => w is Text && w.textSpan != null,
                  ),
                )
                .first,
          )
          .textSpan!;
      final highlighted = <String>[];
      spans.visitChildren((span) {
        if (span is TextSpan && span.style?.backgroundColor != null) {
          highlighted.add(span.text!);
        }
        return true;
      });
      expect(highlighted, contains('报告[Q4]'));
      await tester.tap(find.byKey(const ValueKey('search-scope-all')));
      await tester.pumpAndSettle();
      expect(find.text('3 条匹配消息'), findsOneWidget);
      await tester.tap(find.byKey(ValueKey('search-result-${remote.item.id}')));
      await tester.pumpAndSettle();
      expect(harness.inbox.conversation.name, '工作');
      expect(
        find.byKey(const ValueKey('located-message-highlight')),
        findsOneWidget,
      );
      expect(
        tester
            .widgetList<MessageText>(find.byType(MessageText))
            .where((message) => message.text == remote.item.text)
            .single
            .highlightQuery,
        '报告[Q4]',
      );
      await tester.tap(find.text('返回搜索结果'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input).controller!.text, '报告[Q4]');
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(const ValueKey('search-scope-all')))
            .selected,
        isTrue,
      );
      await tester.runAsync(() => harness.inbox.deleteItem(remote.item));
      await tester.pumpAndSettle();
      expect(find.text('2 条匹配消息'), findsOneWidget);
      expect(
        find.byKey(ValueKey('search-result-${remote.item.id}')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      expect(find.text('这条消息已删除，请返回搜索结果'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'distant results reveal the original neighbors lazily and preserve drafts and unread state',
    (tester) async {
      const archive = 'archive-conversation-001';
      void history(int count) {
        harness.inbox.store.applySnapshot({
          'revision': harness.inbox.store.revision + 1,
          'profiles': Map.of(harness.inbox.store.profiles),
          'conversations': {
            archive: {'name': '历史资料'},
          },
          'entries': [
            for (var i = 0; i < count; i++)
              {
                'sequence': i + 1,
                'item': InboxItem(
                  id: 'search-history-${i.toString().padLeft(5, '0')}',
                  originId: 'b' * 32,
                  originName: '手机',
                  conversationId: archive,
                  createdAt: DateTime.utc(
                    2026,
                    10,
                    20,
                  ).add(Duration(seconds: i)),
                  kind: MessageKind.text,
                  text: switch (i) {
                    599 => '原消息之前',
                    600 => '定位 needle',
                    601 => '原消息之后',
                    _ => '历史消息 $i',
                  },
                ).toJson(),
                'copies': <String>[],
              },
          ],
        });
      }

      history(1200);
      await harness.mount(tester);
      final editor = find.byKey(const ValueKey('inbox-composer'));
      await tester.enterText(editor, '默认会话的未发送草稿');
      await tester.tap(
        find.byKey(const ValueKey('global-conversation-search')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('global-conversation-search')),
        'needle',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('search-result-search-history-00600')),
      );
      await tester.pumpAndSettle();
      final target = find.byKey(
        const ValueKey('inbox-item-search-history-00600'),
      );
      final viewport = tester.getRect(
        find.byKey(const ValueKey('located-message-history')),
      );
      expect(viewport.overlaps(tester.getRect(target)), isTrue);
      expect(
        tester.getRect(find.text('原消息之前')).bottom,
        lessThan(tester.getRect(target).top),
      );
      expect(
        tester.getRect(find.text('原消息之后')).top,
        greaterThan(tester.getRect(target).bottom),
      );
      expect((harness.inbox as WidgetInbox).statusReads, lessThan(80));
      expect(find.byType(MessageText).evaluate().length, lessThan(40));
      expect(harness.inbox.isUnread(archive), isTrue);
      final targetY = tester.getTopLeft(target).dy;
      history(1201);
      harness.inbox.selectConversation(archive, markRead: false);
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(target).dy, closeTo(targetY, 1));
      await tester.tap(find.text('回到最新'));
      await tester.pumpAndSettle();
      expect(find.text('历史消息 1200'), findsWidgets);
      await tester.tap(find.byTooltip('清空搜索'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('conversation-$defaultConversationId')),
      );
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(editor).controller!.text, '默认会话的未发送草稿');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'phone search works with the keyboard and larger text and closes one layer at a time',
    (tester) async {
      await tester.runAsync(() => harness.inbox.addText('手机搜索关键词'));
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await harness.mount(
        tester,
        size: const Size(320, 568),
        platform: TargetPlatform.android,
      );
      await harness.openGlobalSearch(tester);
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      addTearDown(tester.view.resetViewInsets);
      await tester.enterText(
        find.byKey(const ValueKey('global-conversation-search')),
        '关键词',
      );
      await tester.pumpAndSettle();
      final result = find.byKey(
        ValueKey('search-result-${harness.inbox.items.single.item.id}'),
      );
      await tester.scrollUntilVisible(
        result,
        100,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('message-search-results')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(result).center.dy, lessThan(328));
      await tester.tap(result);
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('located-message-highlight')),
        findsOneWidget,
      );
      await tester.tap(find.text('返回搜索结果'));
      await tester.pumpAndSettle();
      expect(find.byType(MessageSearchPanel), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(MessageSearchPanel), findsOneWidget);
      expect(find.byKey(const ValueKey('located-message-highlight')), findsNothing);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('global-conversation-search'))).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'dark conversation colors remain distinct and unread badges show real counts',
    (tester) async {
      const work = 'colored-work-chat-001';
      const ideas = 'colored-ideas-chat-001';
      harness.inbox.store.applySnapshot({
        'revision': harness.inbox.store.revision + 1,
        'profiles': Map.of(harness.inbox.store.profiles),
        'conversations': {
          work: {'name': '工作'},
          ideas: {'name': '灵感'},
        },
        'entries': [
          for (var i = 0; i < 105; i++)
            {
              'sequence': i + 1,
              'item': InboxItem(
                id: 'unread-message-${i.toString().padLeft(5, '0')}',
                originId: 'b' * 32,
                originName: '手机',
                createdAt: DateTime.utc(2026, 10, 20).add(Duration(seconds: i)),
                kind: MessageKind.text,
                text: '未读消息 $i',
                conversationId: i < 100 ? work : ideas,
              ).toJson(),
              'copies': <String>[],
            },
        ],
      });
      harness.inbox.store.preference(work).background = 0xFFDCE7F3;
      harness.inbox.store.preference(ideas).background = 0xFFE6E0F0;
      harness.inbox.appearance.value = 'dark';
      await harness.mount(tester);
      final palette = ChatPalette.of(
        tester.element(find.byKey(const ValueKey('conversation-$work'))),
      );
      Color rowColor(String id) => tester
          .widget<Material>(
            find
                .ancestor(
                  of: find.byKey(ValueKey('conversation-$id')),
                  matching: find.byType(Material),
                )
                .first,
          )
          .color!;
      final blue = rowColor(work);
      final purple = rowColor(ideas);
      expect(HSLColor.fromColor(blue).saturation, greaterThan(.4));
      expect(
        (HSLColor.fromColor(blue).hue - HSLColor.fromColor(purple).hue).abs(),
        greaterThan(35),
      );
      for (final background in [blue, purple]) {
        expect(
          (palette.text.computeLuminance() + .05) /
              (background.computeLuminance() + .05),
          greaterThan(4.5),
        );
      }
      final badge = find.byKey(const ValueKey('unread-$work'));
      expect(
        find.descendant(of: badge, matching: find.text('99+')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('unread-$ideas')),
          matching: find.text('5'),
        ),
        findsOneWidget,
      );
      expect(
        (tester.widget<Container>(badge).decoration! as BoxDecoration).color,
        const Color(0xFFD93340),
      );
      await tester.tap(find.byKey(const ValueKey('conversation-$work')));
      await tester.pumpAndSettle();
      expect(badge, findsNothing);
      await tester.runAsync(() async {
        await harness.inbox.setConversationUnread(ideas, false);
        await harness.inbox.setConversationUnread(ideas, true);
      });
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('unread-$ideas')),
          matching: find.text('1'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
