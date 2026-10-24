import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/ui/chat/favorites_panel.dart';
import 'package:lanflow/ui/chat/message_search_panel.dart';
import 'package:lanflow/ui/shared/app_root.dart';

import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  void expectNoFilterControls() {
    for (final key in [
      'search-filters',
      'global-search-filters',
      'clear-search-filters',
      'apply-search-filters',
    ]) {
      expect(find.byKey(ValueKey(key)), findsNothing);
    }
    expect(find.byTooltip('筛选'), findsNothing);
    expect(find.byTooltip('Filters'), findsNothing);
    expect(find.byIcon(Icons.filter_alt), findsNothing);
    expect(find.byIcon(Icons.filter_alt_outlined), findsNothing);
  }

  testWidgets(
    'global and conversation search keep keyword and scope controls without filters',
    (tester) async {
      late InboxEntry local;
      await tester.runAsync(() async {
        local = (await harness.inbox.addText('needle 本地内容'))!;
        final file = File('${harness.directory.path}/needle.txt');
        await file.writeAsString('attachment');
        await harness.inbox.addFile(file.path);
        await harness.inbox.createConversation('Work');
        await harness.inbox.addText('needle other conversation');
      });
      for (final sidebar in [false, true]) {
        final session = MessageSearchSession(
          conversationId: defaultConversationId,
          all: true,
          query: 'needle',
        );
        MessageSearchSelection? selected;
        await tester.pumpWidget(
          AppRoot(
            language: 'en',
            home: Scaffold(
              body: MessageSearchPanel(
                inbox: harness.inbox,
                session: session,
                onSelected: (value) => selected = value,
                idle: sidebar ? const Text('Conversation list') : null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expectNoFilterControls();
        expect(find.text('3 matching messages'), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('search-scope-current')));
        await tester.pumpAndSettle();
        expect(find.text('2 matching messages'), findsOneWidget);
        await tester.tap(
          find.byKey(ValueKey('search-result-${local.item.id}')),
        );
        expect(selected?.entry?.item.id, local.item.id);
        await tester.tap(find.byTooltip('Clear search'));
        await tester.pumpAndSettle();
        expect(session.query, isEmpty);
        expect(
          sidebar
              ? find.text('Conversation list')
              : find.text('Search results appear here'),
          findsOneWidget,
        );
        expectNoFilterControls();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        session.dispose();
      }
    },
  );

  testWidgets('keyword results still load later pages after filter removal', (
    tester,
  ) async {
    String? oldest;
    await tester.runAsync(() async {
      for (var index = 0; index < 120; index++) {
        final entry = (await harness.inbox.addText(
          'pagination needle $index',
        ))!;
        oldest ??= entry.item.id;
      }
    });
    final session = MessageSearchSession(
      conversationId: defaultConversationId,
      query: 'pagination needle',
    );
    await tester.pumpWidget(
      AppRoot(
        language: 'en',
        home: Scaffold(
          body: MessageSearchPanel(
            inbox: harness.inbox,
            session: session,
            onSelected: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('120 matching messages'), findsOneWidget);
    final oldestResult = find.byKey(ValueKey('search-result-$oldest'));
    expect(oldestResult, findsNothing);
    await tester.scrollUntilVisible(
      oldestResult,
      600,
      maxScrolls: 40,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('message-search-results')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(oldestResult, findsOneWidget);
    expectNoFilterControls();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    session.dispose();
  });

  testWidgets('favorites retain their own keyword search', (tester) async {
    late InboxEntry saved;
    await tester.runAsync(() async {
      saved = (await harness.inbox.addText('saved needle 收藏原文'))!;
      final other = (await harness.inbox.addText('another favorite'))!;
      await harness.inbox.setFavorites([saved.item.id, other.item.id], true);
      await harness.inbox.addText('unsaved needle');
    });
    InboxEntry? selected;
    await tester.pumpWidget(
      AppRoot(
        language: 'en',
        home: Scaffold(
          body: FavoritesPanel(
            inbox: harness.inbox,
            embedded: true,
            onLocate: (entry) => selected = entry,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('favorites-search')),
      'needle',
    );
    await tester.pumpAndSettle();
    expect(find.text('saved needle 收藏原文'), findsOneWidget);
    expect(find.text('another favorite'), findsNothing);
    expect(find.text('unsaved needle'), findsNothing);
    final favorite = harness.inbox.favoriteEntries.firstWhere(
      (entry) => entry.originalMessageId == saved.item.id,
    );
    await tester.tap(find.byKey(ValueKey('favorite-${favorite.id}')));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    await tester.tap(find.text('Go to original message'));
    await tester.pumpAndSettle();
    expect(selected?.item.id, saved.item.id);
    expect(find.byKey(const ValueKey('favorites-filter-menu')), findsOneWidget);
    expect(find.byKey(const ValueKey('search-filters')), findsNothing);
    expect(find.byKey(const ValueKey('global-search-filters')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
