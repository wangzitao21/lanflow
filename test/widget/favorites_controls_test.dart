import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/platform/title_order.dart';
import 'package:lanflow/ui/chat/favorite_card.dart';
import 'package:lanflow/ui/chat/favorite_detail.dart';
import 'package:lanflow/ui/chat/favorite_list_tile.dart';
import 'package:lanflow/ui/chat/favorite_masonry.dart';
import 'package:lanflow/ui/chat/favorites_panel.dart';
import 'package:lanflow/ui/shared/app_feedback.dart';
import 'package:lanflow/ui/shared/app_root.dart';

import '../support/favorite_ui_harness.dart';
import '../support/widget_harness.dart';

void main() {
  final harness = WidgetTestHarness();

  Future<FavoriteUiInbox> seed(WidgetTester tester) async {
    final inbox = await installFavoriteUiInbox(tester, harness);
    for (final (index, kind, title) in [
      (0, MessageKind.text, 'Alpha note'),
      (1, MessageKind.text, 'Zulu note'),
      (2, MessageKind.file, 'Banana.pdf'),
      (3, MessageKind.image, 'Apricot.png'),
    ]) {
      inbox.capture(
        InboxItem(
          id: randomToken(18),
          originId: 'a' * 32,
          originName: 'My device',
          createdAt: DateTime.utc(2026, 10, 1),
          kind: kind,
          text: kind == MessageKind.text ? title : '',
          name: kind == MessageKind.text ? '' : title,
          digest: kind == MessageKind.text ? '' : 'a' * 64,
          size: kind == MessageKind.text ? 0 : 1024,
        ),
        savedAt: DateTime.utc(2026, 10, 1, 0, index),
      );
    }
    return inbox;
  }

  Future<void> mount(
    WidgetTester tester,
    InboxController inbox, {
    Size size = const Size(960, 780),
    TitleOrder? titleOrder,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppRoot(
        language: 'en',
        home: Scaffold(
          body: FavoritesPanel(
            inbox: inbox,
            embedded: true,
            titleOrder: titleOrder,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  Future<void> menu(WidgetTester tester, String menu, String item) async {
    await tester.tap(find.byKey(ValueKey('favorites-$menu-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('favorites-$menu-$item')));
    await settle(tester);
  }

  List<String> listNames(WidgetTester tester) => tester
      .widgetList<FavoriteListTile>(find.byType(FavoriteListTile))
      .map(
        (tile) => tile.entry.item.isFile
            ? tile.entry.item.name
            : tile.entry.item.text,
      )
      .toList();

  testWidgets(
    'real favorite pin and view preferences survive closing and reopening the store',
    (tester) async {
      final inbox = harness.inbox;
      late FavoriteEntry favorite;
      await tester.runAsync(() async {
        final original = (await inbox.addText('Persistent favorite snapshot'))!;
        await inbox.setFavorites([original.item.id], true);
        favorite = inbox.favoriteEntries.single;
      });
      expect(
        inbox.store.findFavorite(favorite.id)?.item.text,
        'Persistent favorite snapshot',
      );
      await mount(tester, inbox);
      await tester.tap(find.byKey(ValueKey('favorite-menu-${favorite.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('touch-menu-pin')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('favorites-view-list')));
      await settle(tester);
      await menu(tester, 'filter', 'text');
      await menu(tester, 'filter', 'pinned');
      expect(inbox.favoritePreferences.layout, 'list');
      expect(inbox.favoritePreferences.pinned.containsKey(favorite.id), isTrue);
      expect(listNames(tester), ['Persistent favorite snapshot']);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        await inbox.close();
        inbox.dispose();
        harness.inbox = WidgetInbox(
          lan: harness.lan,
          store: InboxStore(harness.directory),
        );
        await harness.inbox.start();
      });
      await mount(tester, harness.inbox);
      expect(harness.inbox.favoritePreferences.layout, 'list');
      expect(harness.inbox.favoritePreferences.filter, 'text');
      expect(harness.inbox.favoritePreferences.onlyPinned, isTrue);
      expect(
        harness.inbox.favoritePreferences.pinned.containsKey(favorite.id),
        isTrue,
      );
      expect(harness.inbox.store.findFavorite(favorite.id), isNotNull);
      expect(listNames(tester), ['Persistent favorite snapshot']);
      await tester.tap(find.byKey(ValueKey('favorite-${favorite.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteDetail), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'stale title failure does not replace a newer sort and the same title option can retry',
    (tester) async {
      final inbox = await seed(tester);
      await inbox.setFavoritePreferences(
        inbox.favoritePreferences.copyWith(layout: 'list'),
      );
      final pending = <Completer<List<Uint8List>>>[];
      final titleOrder = TitleOrder(
        keyLoader: (values) {
          final request = Completer<List<Uint8List>>();
          pending.add(request);
          return request.future;
        },
      );
      await mount(tester, inbox, titleOrder: titleOrder);
      Future<void> choose(String sort) async {
        await tester.tap(find.byKey(const ValueKey('favorites-sort-menu')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.byKey(ValueKey('favorites-sort-$sort')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
      }

      await choose('titleAsc');
      expect(pending, hasLength(1));
      await choose('oldest');
      pending[0].completeError(StateError('Late title failure'));
      await tester.pumpAndSettle();
      expect(find.byType(AppStatusMessage), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(listNames(tester), [
        'Alpha note',
        'Zulu note',
        'Banana.pdf',
        'Apricot.png',
      ]);
      await choose('titleAsc');
      expect(pending, hasLength(2));
      pending[1].completeError(StateError('Retry needed'));
      await tester.pumpAndSettle();
      expect(find.byType(AppStatusMessage), findsOneWidget);
      expect(listNames(tester), [
        'Alpha note',
        'Zulu note',
        'Banana.pdf',
        'Apricot.png',
      ]);
      await choose('titleAsc');
      expect(pending, hasLength(3));
      pending[2].complete([
        for (final entry in inbox.saved)
          Uint8List.fromList(
            (entry.item.isFile ? entry.item.name : entry.item.text).codeUnits,
          ),
      ]);
      await tester.pumpAndSettle();
      expect(find.byType(AppStatusMessage), findsNothing);
      expect(listNames(tester), [
        'Alpha note',
        'Apricot.png',
        'Banana.pdf',
        'Zulu note',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('type and pinned filters combine with search in both views', (
    tester,
  ) async {
    final inbox = await seed(tester);
    final picture = inbox.saved.firstWhere(
      (entry) => entry.item.kind == MessageKind.image,
    );
    await inbox.setFavoritesPinned([picture.id], true);
    await mount(tester, inbox);
    await menu(tester, 'filter', 'image');
    expect(find.byType(FavoriteCard), findsOneWidget);
    expect(find.byKey(ValueKey('favorite-pin-${picture.id}')), findsOneWidget);
    await menu(tester, 'filter', 'pinned');
    expect(find.byType(FavoriteCard), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('favorites-view-list')));
    await tester.pumpAndSettle();
    expect(listNames(tester), ['Apricot.png']);
    expect(inbox.favoritePreferences.filter, 'image');
    expect(inbox.favoritePreferences.onlyPinned, isTrue);
    await tester.enterText(
      find.byKey(const ValueKey('favorites-search')),
      'no match',
    );
    await tester.pumpAndSettle();
    expect(find.byType(FavoriteListTile), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('favorites-search')),
      'Apricot',
    );
    await tester.pumpAndSettle();
    expect(listNames(tester), ['Apricot.png']);
    await tester.tap(find.byKey(const ValueKey('favorites-clear-filters')));
    await tester.pumpAndSettle();
    expect(inbox.favoritePreferences.onlyPinned, isFalse);
    expect(inbox.favoritePreferences.filter, 'all');
    expect(listNames(tester), ['Apricot.png']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'sorting respects pins and cached title order without losing user text',
    (tester) async {
      final inbox = await seed(tester);
      final zulu = inbox.saved.firstWhere(
        (entry) => entry.item.text == 'Zulu note',
      );
      await inbox.setFavoritePreferences(
        inbox.favoritePreferences.copyWith(layout: 'list'),
      );
      await inbox.setFavoritesPinned([zulu.id], true);
      await mount(tester, inbox);
      expect(listNames(tester), [
        'Zulu note',
        'Apricot.png',
        'Banana.pdf',
        'Alpha note',
      ]);
      await menu(tester, 'sort', 'oldest');
      expect(listNames(tester), [
        'Zulu note',
        'Alpha note',
        'Banana.pdf',
        'Apricot.png',
      ]);
      await menu(tester, 'sort', 'type');
      expect(listNames(tester), [
        'Zulu note',
        'Alpha note',
        'Apricot.png',
        'Banana.pdf',
      ]);
      await menu(tester, 'sort', 'titleAsc');
      expect(listNames(tester), [
        'Zulu note',
        'Alpha note',
        'Apricot.png',
        'Banana.pdf',
      ]);
      await menu(tester, 'sort', 'titleDesc');
      expect(listNames(tester), [
        'Zulu note',
        'Banana.pdf',
        'Apricot.png',
        'Alpha note',
      ]);
      await tester.tap(find.byKey(const ValueKey('favorites-view-masonry')));
      await tester.pumpAndSettle();
      final sorted = tester
          .widget<FavoriteMasonry>(find.byType(FavoriteMasonry))
          .entries;
      await tester.tap(find.byKey(const ValueKey('favorites-select-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('favorite-${zulu.id}')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<FavoriteMasonry>(find.byType(FavoriteMasonry)).entries,
        same(sorted),
      );
      await tester.tap(find.byKey(const ValueKey('favorites-view-list')));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(find.byType(FavoriteListTile), findsNWidgets(4));
      expect(
        inbox.saved.any((entry) => entry.item.text == 'Zulu note'),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'single and batch pin actions work and failed saves retain selection',
    (tester) async {
      final inbox = await seed(tester);
      final target = inbox.saved.last;
      await mount(tester, inbox);
      await tester.tap(find.byKey(ValueKey('favorite-menu-${target.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('touch-menu-pin')));
      await tester.pumpAndSettle();
      expect(inbox.favoritePreferences.pinned.keys, [target.id]);
      await tester.tap(find.byKey(const ValueKey('favorites-select-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorites-select-all')));
      await tester.pumpAndSettle();
      inbox.failPreferences = true;
      await tester.tap(find.byKey(const ValueKey('favorites-pin-selected')));
      await tester.pumpAndSettle();
      expect(inbox.favoritePreferences.pinned.keys, [target.id]);
      expect(find.text('4 selected'), findsOneWidget);
      expect(find.byType(AppStatusMessage), findsOneWidget);
      inbox.failPreferences = false;
      await tester.tap(find.byKey(const ValueKey('favorites-pin-selected')));
      await tester.pumpAndSettle();
      expect(inbox.favoritePreferences.pinned, hasLength(4));
      await tester.tap(find.byKey(const ValueKey('favorites-pin-selected')));
      await tester.pumpAndSettle();
      expect(inbox.favoritePreferences.pinned, isEmpty);
      expect(find.text('4 selected'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'direct trash and secondary click do not open or select cards in either view',
    (tester) async {
      final inbox = await seed(tester);
      await mount(tester, inbox);
      for (final layout in ['masonry', 'list']) {
        if (layout == 'list') {
          await tester.tap(find.byKey(const ValueKey('favorites-view-list')));
          await tester.pumpAndSettle();
        }
        final target = inbox.saved.first;
        final card = find.byKey(ValueKey('favorite-${target.id}'));
        final ink = tester.widget<InkWell>(card);
        expect(ink.splashFactory, same(NoSplash.splashFactory));
        expect(ink.highlightColor, Colors.transparent);
        await tester.tap(card, buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('favorite-action-menu')),
          findsOneWidget,
        );
        expect(
          ModalRoute.of(
            tester.element(find.byKey(const ValueKey('favorite-action-menu'))),
          )!.transitionDuration,
          Duration.zero,
        );
        expect(find.byType(FavoriteDetail), findsNothing);
        await tester.tapAt(const Offset(4, 4));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey('favorite-delete-${target.id}')));
        await tester.pumpAndSettle();
        expect(inbox.saved.any((entry) => entry.id == target.id), isFalse);
        expect(find.byType(FavoriteDetail), findsNothing);
        expect(find.textContaining('selected'), findsNothing);
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();
        expect(inbox.saved.any((entry) => entry.id == target.id), isTrue);
      }
      inbox.store.linkFavoriteDeletion = true;
      final target = inbox.saved.first;
      await tester.tap(find.byKey(ValueKey('favorite-delete-${target.id}')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Linked deletion is enabled'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(inbox.saved.any((entry) => entry.id == target.id), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'successful image futures survive preference and favorite revisions',
    (tester) async {
      final inbox = await seed(tester);
      final picture = inbox.saved.first;
      await tester.runAsync(() async {
        inbox.attachmentFiles[picture.id] = await favoriteImageFixture(
          harness.directory,
          'cached.png',
          180,
          120,
        );
      });
      await mount(tester, inbox);
      await settleFavoriteImages(tester);
      final pictureCard = find.byWidgetPredicate(
        (widget) => widget is FavoriteCard && widget.id == picture.id,
      );
      final initial = tester.widget<FavoriteCard>(pictureCard).imageFile;
      final requests = inbox.fileExportRequests;
      inbox.changed();
      await tester.pumpAndSettle();
      await inbox.setFavoritesPinned([picture.id], true);
      await tester.pumpAndSettle();
      expect(tester.widget<FavoriteCard>(pictureCard).imageFile, same(initial));
      expect(inbox.fileExportRequests, requests);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    '320px large text controls and compact pinned rows remain usable',
    (tester) async {
      final inbox = await seed(tester);
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(tester, inbox, size: const Size(320, 720));
      await menu(tester, 'filter', 'text');
      await tester.tap(find.byKey(const ValueKey('favorites-view-list')));
      await tester.pumpAndSettle();
      expect(listNames(tester), ['Zulu note', 'Alpha note']);
      await tester.tap(find.byKey(const ValueKey('favorites-select-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorites-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorites-pin-selected')));
      await tester.pumpAndSettle();
      expect(inbox.favoritePreferences.pinned, hasLength(2));
      expect(find.byType(FavoriteListTile), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
