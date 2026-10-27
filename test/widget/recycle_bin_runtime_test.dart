import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/storage/storage_location.dart';
import 'package:lanflow/runtime.dart';
import 'package:lanflow/ui/chat/desktop_navigation.dart';
import 'package:lanflow/ui/chat/home_page.dart';
import 'package:lanflow/ui/chat/mobile_home.dart';
import 'package:lanflow/ui/settings/recently_deleted_panel.dart';

void main() {
  for (final mobile in [false, true]) {
    testWidgets(
      '${mobile ? 'mobile' : 'desktop'} recycle bin survives failed cleanup recovery and successful session restart',
      (tester) async {
        const desktop = MethodChannel('lanflow/desktop');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(desktop, (_) async => null);
        debugDefaultTargetPlatformOverride = mobile
            ? TargetPlatform.android
            : TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        tester.view.physicalSize = mobile
            ? const Size(390, 844)
            : const Size(1180, 780);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Directory root;
        late RuntimeSession initial;
        late String favoriteId, liveFileId;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp(
            'lanflow-recycle-runtime-',
          );
          initial = await RuntimeSession.open(
            Directory('${root.path}/data'),
            enableDiscovery: false,
            preferredPort: 0,
            bindAddress: InternetAddress.loopbackIPv4,
          );
          await initial.start(acceptShares: false);
          await initial.inbox.addText('Live conversation text');
          final liveFile = File('${root.path}/live.bin');
          await liveFile.writeAsBytes([1, 2, 3]);
          liveFileId = (await initial.inbox.addFile(liveFile.path)).item.id;
          final favoriteSource = File('${root.path}/favorite.bin');
          await favoriteSource.writeAsBytes([4, 5, 6]);
          final favoriteMessage = await initial.inbox.addFile(
            favoriteSource.path,
          );
          await initial.inbox.setFavorites([favoriteMessage.item.id], true);
          favoriteId = initial.inbox.favoriteEntries.single.id;
          final discarded = (await initial.inbox.addText(
            'Discard both independent records',
          ))!;
          await initial.inbox.setFavorites([discarded.item.id], true);
          await initial.inbox.setFavorites([discarded.item.id], false);
          await initial.inbox.deleteItem(discarded.item);
          final draftFile = File('${root.path}/draft.bin');
          await draftFile.writeAsBytes([7, 8, 9]);
          await initial.inbox.stageFile(draftFile.path);
          initial.inbox.setDraft('Keep unsent draft');
        });
        await tester.pumpWidget(
          LanFlowHost(
            session: initial,
            location: StorageLocation(initial.lan.store.directory),
          ),
        );
        HomePage home() => tester.widget<HomePage>(find.byType(HomePage));
        Future<void> settleUntil(bool Function() done) async {
          for (var tick = 0; tick < 500; tick++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 20));
            if (done()) return;
          }
          fail('Runtime cleanup did not settle');
        }

        void expectTrash() {
          expect(find.byType(RecentlyDeletedPanel), findsOneWidget);
          if (mobile) {
            expect(
              tester.widget<MobileHome>(find.byType(MobileHome)).section,
              MobileSection.trash,
            );
            expect(
              find.byKey(const ValueKey('mobile-nav-conversations')),
              findsOneWidget,
            );
          } else {
            expect(
              tester
                  .widget<DesktopNavigation>(find.byType(DesktopNavigation))
                  .section,
              MobileSection.trash,
            );
          }
        }

        Future<void> verifyProtected() async {
          final current = home().inbox;
          final persisted = await tester.runAsync(
            () async => current.store.loadEntries(
              await current.store.conversationIds(current.conversationId),
            ),
          );
          expect(current.store.messageCount, 3);
          expect(persisted, hasLength(3));
          expect(
            persisted!.any(
              (entry) => entry.item.text == 'Live conversation text',
            ),
            isTrue,
          );
          expect(current.favoriteEntries.single.id, favoriteId);
          expect(current.store.draft, 'Keep unsent draft');
          await tester.runAsync(() async {
            expect(
              await (await current.store.fileForExport(
                current.store.find(liveFileId)!.item,
              )).readAsBytes(),
              [1, 2, 3],
            );
            expect(
              await (await current.favoriteFileForExport(
                current.favoriteEntries.single,
              )).readAsBytes(),
              [4, 5, 6],
            );
            expect(
              await (await current.store.fileForExport(
                current.store.draftAttachments.single,
              )).readAsBytes(),
              [7, 8, 9],
            );
          });
        }

        Directory? blocker;
        try {
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(
              ValueKey(mobile ? 'mobile-nav-trash' : 'desktop-nav-trash'),
            ),
          );
          await settleUntil(
            () =>
                find
                    .byKey(const ValueKey('empty-local-trash'))
                    .evaluate()
                    .isNotEmpty &&
                tester
                        .widget<TextButton>(
                          find.byKey(const ValueKey('empty-local-trash')),
                        )
                        .onPressed !=
                    null,
          );
          expectTrash();
          for (final failClose in [true, false]) {
            final previous = home().inbox;
            if (failClose) {
              blocker = Directory(
                '${home().controller.store.deviceDirectory.path}/state.pending.json',
              );
              await tester.runAsync(() => blocker!.create());
            }
            await tester.runAsync(
              () => tester.tap(find.byKey(const ValueKey('empty-local-trash'))),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('永久清空'));
            await tester.pump();
            await settleUntil(
              () =>
                  find.byType(HomePage).evaluate().isNotEmpty &&
                  !identical(home().inbox, previous) &&
                  !home().interactionsBlocked &&
                  find
                      .byKey(const ValueKey('storage-migration-overlay'))
                      .evaluate()
                      .isEmpty,
            );
            await settleUntil(
              () =>
                  find.byType(CircularProgressIndicator).evaluate().isEmpty &&
                  find.byType(LinearProgressIndicator).evaluate().isEmpty,
            );
            expectTrash();
            await verifyProtected();
            await tester.runAsync(() async {
              expect(
                (await home().inbox.store.recentlyDeleted()).length,
                failClose ? 1 : 0,
              );
              if (failClose) {
                await blocker!.delete();
                blocker = null;
                await home().controller.retrySave();
              }
            });
            expect(
              find.text(failClose ? '回收站未完全清空，请检查空间和权限后重试。' : '已清空回收站'),
              findsOneWidget,
            );
            expect(
              find.byKey(const ValueKey('empty-trash-progress')),
              findsNothing,
            );
            expect(tester.takeException(), isNull);
            await tester.pump(const Duration(seconds: 1));
            expect(find.byKey(const ValueKey('runtime-notice')), findsNothing);
          }
        } finally {
          final current = home();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            if (blocker != null && await blocker!.exists()) {
              await blocker!.delete();
            }
            await current.controller.close();
            await current.inbox.close();
            current.controller.dispose();
            current.inbox.dispose();
            await root.delete(recursive: true);
          });
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(desktop, null);
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
