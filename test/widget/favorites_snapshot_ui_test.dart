import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
// The platform interface only controls the test's save dialog destination.
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/ui/chat/favorite_actions.dart';
import 'package:lanflow/ui/chat/favorite_card.dart';
import 'package:lanflow/ui/chat/favorite_detail.dart';
import 'package:lanflow/ui/chat/favorites_panel.dart';
import 'package:lanflow/ui/shared/app_root.dart';
import 'package:lanflow/ui/shared/attachment_thumbnail.dart';

import '../support/favorite_ui_harness.dart';
import '../support/widget_harness.dart';

class _SaveDestination extends FileSelectorPlatform {
  String? destination;
  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async => destination == null ? null : FileSaveLocation(destination!);
}

void main() {
  final harness = WidgetTestHarness();

  Future<void> mount(
    WidgetTester tester,
    FavoriteUiInbox inbox, {
    ValueChanged<InboxEntry>? onLocate,
    ValueChanged<VoidCallback?>? onBackHandlerChanged,
    Size size = const Size(960, 780),
    EdgeInsets padding = const EdgeInsets.all(16),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      AppRoot(
        language: 'en',
        home: Scaffold(
          body: Padding(
            padding: padding,
            child: FavoritesPanel(
              inbox: inbox,
              embedded: true,
              onLocate: onLocate,
              onBackHandlerChanged: onBackHandlerChanged,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'deleted original text remains readable and copyable inside its independent favorite',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      late FavoriteEntry favorite;
      await tester.runAsync(() async {
        final original = (await inbox.addText(
          '收藏中的独立原文\nhttps://example.com/notes',
        ))!;
        favorite = inbox.capture(original.item);
        await inbox.deleteItem(original.item);
      });
      var located = false;
      await mount(tester, inbox, onLocate: (_) => located = true);
      await tester.tap(find.byKey(ValueKey('favorite-${favorite.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteDetail), findsOneWidget);
      expect(located, isFalse);
      expect(
        find.byKey(const ValueKey('favorite-detail-locate')),
        findsNothing,
      );
      expect(
        find.text(
          'The original message was deleted. This saved copy is still available.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('favorite-detail-copy')));
      await tester.pumpAndSettle();
      expect(
        (await Clipboard.getData(Clipboard.kTextPlain))?.text,
        favorite.item.text,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'existing originals are located only through the explicit details action',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      late InboxEntry original;
      late FavoriteEntry favorite;
      await tester.runAsync(() async {
        original = (await inbox.addText('Keep the original'))!;
        favorite = inbox.capture(original.item);
      });
      InboxEntry? located;
      await mount(tester, inbox, onLocate: (entry) => located = entry);
      await tester.tap(find.byKey(ValueKey('favorite-${favorite.id}')));
      await tester.pumpAndSettle();
      expect(located, isNull);
      expect(
        find.byKey(const ValueKey('favorite-detail-locate')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('favorite-detail-locate')));
      await tester.pumpAndSettle();
      expect(located?.item.id, original.item.id);
      expect(find.byType(FavoriteDetail), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'favorite file exports use original bytes after its opened preview changes',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      final previousSelector = FileSelectorPlatform.instance;
      final selector = _SaveDestination();
      FileSelectorPlatform.instance = selector;
      addTearDown(() => FileSelectorPlatform.instance = previousSelector);
      await tester.runAsync(() async {
        final original = File('${harness.directory.path}/reference.txt');
        await original.writeAsString('ORIGINAL');
        final item = InboxItem(
          id: randomToken(18),
          originId: 'a' * 32,
          originName: 'My device',
          createdAt: DateTime.now().toUtc(),
          kind: MessageKind.file,
          name: 'reference.txt',
          size: 8,
          digest: 'a' * 64,
        );
        final favorite = inbox.capture(item);
        inbox.attachmentFiles[favorite.id] = original;
        File? opened;
        final actions = FavoriteActions(
          inbox,
          openAttachment: (file) async => opened = file,
        );
        await actions.openFile(favorite);
        expect(opened!.path, isNot(original.path));
        await opened!.writeAsString('MODIFIED');
        selector.destination = '${harness.directory.path}/saved.txt';
        expect(await actions.saveFile(favorite), isTrue);
        expect(await File(selector.destination!).readAsString(), 'ORIGINAL');
        selector.destination = '${harness.directory.path}/favorites.zip';
        expect(await actions.export([favorite]), isTrue);
        final archive = ZipDecoder().decodeBytes(
          await File(selector.destination!).readAsBytes(),
        );
        expect(
          utf8.decode(
            archive
                .findFile('attachments/${favorite.id}/reference.txt')!
                .content,
          ),
          'ORIGINAL',
        );
        final metadata =
            jsonDecode(utf8.decode(archive.findFile('messages.json')!.content))
                as List;
        expect(metadata.single['originalMessageId'], item.id);
        expect(
          metadata.single['savedAt'],
          favorite.savedAt.toUtc().toIso8601String(),
        );
      });
    },
  );

  testWidgets(
    'batch favorite deletion is independent, undoable and searchable',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      late FavoriteEntry first, second;
      await tester.runAsync(() async {
        first = inbox.capture((await inbox.addText('First saved text'))!.item);
        second = inbox.capture(
          (await inbox.addText('Second saved text'))!.item,
        );
      });
      await mount(tester, inbox);
      await tester.tap(find.byKey(const ValueKey('favorites-select-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorites-select-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorites-delete-selected')));
      await tester.pumpAndSettle();
      expect(inbox.saved, isEmpty);
      expect(inbox.items.length, 2);
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(inbox.saved.map((entry) => entry.id).toSet(), {
        first.id,
        second.id,
      });
      await tester.enterText(
        find.byKey(const ValueKey('favorites-search')),
        'Second',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('favorite-${first.id}')), findsNothing);
      expect(find.byKey(ValueKey('favorite-${second.id}')), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'linked favorite deletion confirms original-message impact before acting',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      inbox.store.linkFavoriteDeletion = true;
      late FavoriteEntry favorite;
      await tester.runAsync(() async {
        favorite = inbox.capture(
          (await inbox.addText('Linked original'))!.item,
        );
      });
      await mount(tester, inbox);
      await tester.tap(find.byKey(ValueKey('favorite-${favorite.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorite-detail-delete')));
      await tester.pumpAndSettle();
      expect(inbox.deleteCalls, 0);
      expect(find.textContaining('Linked deletion is enabled'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(inbox.deleteCalls, 0);
      expect(find.byType(FavoriteDetail), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'masonry cards use staggered desktop columns and keep widths while selecting',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      for (var index = 0; index < 18; index++) {
        inbox.capture(
          InboxItem(
            id: randomToken(18),
            originId: 'c' * 32,
            originName: 'My device',
            createdAt: DateTime.utc(2026, 10, 1),
            kind: MessageKind.text,
            text: index.isEven
                ? 'A longer saved note $index.\n${'Useful reference text. ' * 12}'
                : 'Quick note $index',
          ),
          savedAt: DateTime.utc(2026, 10, 1).subtract(Duration(minutes: index)),
        );
      }
      await mount(
        tester,
        inbox,
        size: const Size(1180, 780),
        padding: EdgeInsets.zero,
      );
      Map<String, Rect> cards() => {
        for (final card in tester.widgetList<FavoriteCard>(
          find.byType(FavoriteCard),
        ))
          card.id: tester.getRect(find.byKey(ValueKey('favorite-${card.id}'))),
      };
      final initial = cards();
      final columns = initial.values.map((rect) => rect.left).toSet();
      expect(columns, hasLength(4));
      expect(initial.values.every((rect) => rect.width < 320), isTrue);
      final firstTop = initial.values
          .map((rect) => rect.top)
          .reduce((a, b) => a < b ? a : b);
      final firstRow = initial.values
          .where((rect) => rect.top == firstTop)
          .toList();
      final longestBottom = firstRow
          .map((rect) => rect.bottom)
          .reduce((a, b) => a > b ? a : b);
      expect(firstRow, hasLength(4));
      expect(
        initial.values.any(
          (rect) => rect.top > firstTop && rect.top < longestBottom,
        ),
        isTrue,
        reason:
            'Short cards should stack without waiting for the longest neighboring card.',
      );
      for (final a in initial.entries) {
        for (final b in initial.entries) {
          if (a.key != b.key) expect(a.value.overlaps(b.value), isFalse);
        }
      }
      await tester.tap(find.byKey(const ValueKey('favorites-select-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorites-select-all')));
      await tester.pumpAndSettle();
      for (final card in cards().entries) {
        final previous = initial[card.key];
        if (previous != null) {
          expect(card.value.left, previous.left);
          expect(card.value.width, previous.width);
          expect(card.value.height, previous.height);
        }
      }
      expect(find.text('18 selected'), findsOneWidget);
      tester.view.physicalSize = const Size(390, 844);
      await tester.pumpAndSettle();
      expect(cards().values.map((rect) => rect.left).toSet(), hasLength(2));
      expect(find.text('18 selected'), findsOneWidget);
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(cards().values.map((rect) => rect.left).toSet(), hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'large image collections only load cards near the shared viewport',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      for (var index = 0; index < 180; index++) {
        inbox.capture(
          InboxItem(
            id: randomToken(18),
            originId: 'd' * 32,
            originName: 'My phone',
            createdAt: DateTime.utc(2026, 10, 1),
            kind: MessageKind.image,
            name: 'Saved image $index.png',
            digest: 'd' * 64,
            size: 500,
          ),
        );
      }
      await mount(tester, inbox, size: const Size(1180, 780));
      expect(inbox.fileExportRequests, greaterThan(0));
      expect(inbox.fileExportRequests, lessThan(40));
      expect(find.byType(FavoriteCard).evaluate().length, lessThan(40));
      final scroll = tester
          .widget<CustomScrollView>(
            find.byKey(const PageStorageKey('favorites-list')),
          )
          .controller!;
      scroll.jumpTo(900);
      await tester.pumpAndSettle();
      expect(inbox.fileExportRequests, lessThan(64));
      expect(find.byType(FavoriteCard).evaluate().length, lessThan(40));
      final arriving = tester
          .widgetList<FavoriteCard>(find.byType(FavoriteCard))
          .first;
      await tester.runAsync(() async {
        inbox.attachmentFiles[arriving.id] = await favoriteImageFixture(
          harness.directory,
          'later-tall-image.png',
          100,
          600,
        );
        inbox.changed();
      });
      await settleFavoriteImages(tester);
      final visibleRects = tester
          .widgetList<FavoriteCard>(find.byType(FavoriteCard))
          .map(
            (card) =>
                tester.getRect(find.byKey(ValueKey('favorite-${card.id}'))),
          )
          .toList();
      for (var a = 0; a < visibleRects.length; a++) {
        for (var b = a + 1; b < visibleRects.length; b++) {
          expect(visibleRects[a].overlaps(visibleRects[b]), isFalse);
        }
      }
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        tester
            .getTopLeft(
              find.byKey(ValueKey('favorite-${inbox.saved.first.id}')),
            )
            .dy,
        closeTo(
          tester
              .getTopLeft(find.byKey(const PageStorageKey('favorites-list')))
              .dy,
          .1,
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'portrait favorite thumbnails keep their aspect ratio on a narrow large-text page',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      late FavoriteEntry favorite;
      await tester.runAsync(() async {
        final file = await favoriteImageFixture(
          harness.directory,
          'portrait.png',
          120,
          360,
        );
        favorite = inbox.capture(
          InboxItem(
            id: randomToken(18),
            originId: 'a' * 32,
            originName: 'My phone',
            createdAt: DateTime.now().toUtc(),
            kind: MessageKind.image,
            name: 'portrait.png',
            size: await file.length(),
            digest: 'b' * 64,
          ),
        );
        inbox.attachmentFiles[favorite.id] = file;
      });
      tester.platformDispatcher.textScaleFactorTestValue = 1.4;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await mount(tester, inbox, size: const Size(320, 720));
      await settleFavoriteImages(tester);
      final image = find.descendant(
        of: find.byKey(ValueKey('favorite-${favorite.id}')),
        matching: find.byType(AttachmentThumbnail),
      );
      final actual = tester.getSize(image);
      expect(actual.width / actual.height, closeTo(1 / 3, .01));
      expect(actual.height, lessThanOrEqualTo(300));
      expect(
        tester.getSize(find.byKey(ValueKey('favorite-${favorite.id}'))).height,
        lessThan(540),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a later attachment notification restores the card and already open detail preview',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      final favorite = inbox.capture(
        InboxItem(
          id: randomToken(18),
          originId: 'b' * 32,
          originName: 'My phone',
          createdAt: DateTime.now().toUtc(),
          kind: MessageKind.image,
          name: 'arriving-image.png',
          size: 512,
          digest: 'e' * 64,
        ),
      );
      await mount(tester, inbox);
      expect(find.text('Attachment unavailable'), findsOneWidget);
      expect(find.byType(AttachmentThumbnail), findsNothing);

      await tester.tap(find.byKey(ValueKey('favorite-${favorite.id}')));
      await tester.pumpAndSettle();
      expect(find.text('Attachment unavailable'), findsOneWidget);
      final detailState = tester.state<FavoriteDetailState>(
        find.byType(FavoriteDetail),
      );
      await tester.runAsync(() async {
        inbox.attachmentFiles[favorite.id] = await favoriteImageFixture(
          harness.directory,
          favorite.item.name,
          180,
          120,
        );
        inbox.changed();
      });
      await settleFavoriteImages(tester);
      expect(
        tester.state<FavoriteDetailState>(find.byType(FavoriteDetail)),
        same(detailState),
      );
      final detailImage = find.descendant(
        of: find.byType(FavoriteDetail),
        matching: find.byType(RawImage),
      );
      expect(detailImage, findsOneWidget);
      expect(tester.widget<RawImage>(detailImage).image, isNotNull);
      expect(find.text('Attachment unavailable'), findsNothing);

      await tester.tap(find.byKey(const ValueKey('favorite-detail-back')));
      await settleFavoriteImages(tester);
      final cardImage = find.descendant(
        of: find.byKey(ValueKey('favorite-${favorite.id}')),
        matching: find.byType(RawImage),
      );
      expect(cardImage, findsOneWidget);
      expect(tester.widget<RawImage>(cardImage).image, isNotNull);
      expect(find.text('Attachment unavailable'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'inline details preserve list search scroll and selection when the back handler returns',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      final entries = <FavoriteEntry>[];
      for (var index = 0; index < 30; index++) {
        entries.add(
          inbox.capture(
            InboxItem(
              id: randomToken(18),
              originId: 'c' * 32,
              originName: 'My device',
              createdAt: DateTime.utc(2026, 10, 1),
              kind: MessageKind.text,
              text: 'Saved note $index',
            ),
            savedAt: DateTime.utc(2026, 10, 1).add(Duration(minutes: index)),
          ),
        );
      }
      VoidCallback? back;
      await mount(tester, inbox, onBackHandlerChanged: (value) => back = value);
      await tester.enterText(
        find.byKey(const ValueKey('favorites-search')),
        'note',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorites-select-mode')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('favorites-select-all')));
      await tester.pumpAndSettle();
      final target = entries[4];
      final list = find.byKey(const PageStorageKey('favorites-list'));
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('favorite-menu-${target.id}')),
        500,
        maxScrolls: 35,
        scrollable: find
            .descendant(of: list, matching: find.byType(Scrollable))
            .first,
      );
      final offset = tester.widget<CustomScrollView>(list).controller!.offset;
      await tester.tap(find.byKey(ValueKey('favorite-menu-${target.id}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('touch-menu-view')));
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteDetail), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(back, isNotNull);
      back!();
      await tester.pumpAndSettle();
      expect(back, isNull);
      expect(find.byType(FavoriteDetail), findsNothing);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('favorites-search')))
            .controller!
            .text,
        'note',
      );
      expect(find.text('30 selected'), findsOneWidget);
      expect(
        tester.widget<CustomScrollView>(list).controller!.offset,
        closeTo(offset, 1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'standalone favorites dialog Back exits details before dismissing the collection',
    (tester) async {
      final inbox = await installFavoriteUiInbox(tester, harness);
      final entry = inbox.capture(
        InboxItem(
          id: randomToken(18),
          originId: 'd' * 32,
          originName: 'My device',
          createdAt: DateTime.utc(2026, 10, 1),
          kind: MessageKind.text,
          text: 'Independent favorite',
        ),
      );
      await tester.pumpWidget(
        AppRoot(
          language: 'en',
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => FavoritesPanel(inbox: inbox),
                ),
                child: const Text('Open collection'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open collection'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('favorite-${entry.id}')));
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteDetail), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(FavoriteDetail), findsNothing);
      expect(find.byType(FavoritesPanel), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(FavoritesPanel), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
