import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/storage/storage_location.dart';
import 'package:lanflow/runtime.dart';
import 'package:lanflow/ui/chat/home_page.dart';
import 'package:lanflow/ui/chat/desktop_navigation.dart';
import 'package:lanflow/ui/chat/mobile_home.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets(
    'failed close during backup, cleanup or relocation preserves pending local edits',
    (tester) async {
      late Directory root;
      late RuntimeSession initial;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp(
          'lanflow-close-write-failure-',
        );
        initial = await RuntimeSession.open(
          Directory(p.join(root.path, 'data')),
          enableDiscovery: false,
          preferredPort: 0,
          bindAddress: InternetAddress.loopbackIPv4,
        );
        await initial.start();
        final deleted = await initial.inbox.addText(
          'Keep the recoverable record on failure',
        );
        await initial.inbox.deleteItem(deleted!.item);
      });
      const desktop = MethodChannel('lanflow/desktop');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(desktop, (_) async => null);
      tester.view.physicalSize = const Size(1180, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        LanFlowHost(
          session: initial,
          location: StorageLocation(initial.lan.store.directory),
        ),
      );
      await tester.pumpAndSettle();
      try {
        for (final operation in ['backup', 'cleanup', 'relocate']) {
          final previous = tester.widget<HomePage>(find.byType(HomePage));
          final peerId = 'b' * 32;
          final expectedName = 'pending-$operation';
          final expectedDraft = 'pending draft before $operation';
          final blocker = Directory(
            p.join(
              previous.controller.store.deviceDirectory.path,
              'state.pending.json',
            ),
          );
          await tester.runAsync(() async {
            await previous.controller.retrySave();
            await blocker.create();
            previous.controller.peers[peerId] = Peer(
              id: peerId,
              name: 'pending peer',
              platform: 'windows',
              address: '127.0.0.1',
              port: 9,
              fingerprint: 'b' * 64,
              online: false,
            );
            previous.controller.sessions[peerId] = PeerSession(
              receiveToken: 'receive-$operation',
              sendToken: 'send-$operation',
            );
            previous.controller.updateSettings(deviceName: expectedName);
            previous.inbox.setDraft(expectedDraft);
          });
          var finished = false;
          Object? failure;
          await tester.runAsync(() async {
            final Future<dynamic> future = switch (operation) {
              'backup' => previous.inbox.backupStorage!(
                p.join(root.path, 'backup.zip'),
              ),
              'cleanup' => previous.inbox.cleanupStorage!(true),
              _ => previous.inbox.relocateStorage!(
                p.join(root.path, 'moved'),
                true,
              ),
            };
            unawaited(
              future.then<void>(
                (_) => finished = true,
                onError: (Object error) {
                  failure = error;
                  finished = true;
                },
              ),
            );
          });
          for (var tick = 0; tick < 500 && !finished; tick++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(finished, isTrue);
          if (operation != 'relocate') expect(failure, isNotNull);
          await tester.pumpAndSettle();
          final recovered = tester.widget<HomePage>(find.byType(HomePage));
          expect(identical(recovered.inbox, previous.inbox), isFalse);
          expect(recovered.inbox.ready, isTrue);
          expect(recovered.controller.name, expectedName);
          expect(
            recovered.controller.sessions[peerId]?.sendToken,
            'send-$operation',
          );
          expect(recovered.inbox.store.draft, expectedDraft);
          if (operation == 'cleanup') {
            if (find.byType(DesktopNavigation).evaluate().isNotEmpty) {
              expect(
                tester
                    .widget<DesktopNavigation>(find.byType(DesktopNavigation))
                    .section,
                MobileSection.trash,
              );
              await tester.tap(
                find.byKey(const ValueKey('desktop-nav-conversations')),
              );
            } else {
              expect(
                tester.widget<MobileHome>(find.byType(MobileHome)).section,
                MobileSection.trash,
              );
              await tester.tap(find.byKey(const ValueKey('mobile-nav-conversations')));
            }
            await tester.pumpAndSettle();
          }
          if (find.byKey(const ValueKey('inbox-composer')).evaluate().isEmpty) {
            await tester.tap(find.byKey(ValueKey('conversation-${recovered.inbox.conversationId}')));
            await tester.pumpAndSettle();
          }
          final editor = tester.widget<TextField>(
            find.byKey(const ValueKey('inbox-composer')),
          );
          expect(editor.enabled, isTrue);
          expect(editor.controller?.text, expectedDraft);
          await tester.runAsync(() async {
            expect((await recovered.inbox.store.recentlyDeleted()).length, 1);
            expect(
              await Directory(p.join(root.path, 'moved')).exists(),
              isFalse,
            );
            expect(
              await File(p.join(root.path, 'backup.zip')).exists(),
              isFalse,
            );
            await blocker.delete();
            await recovered.controller.retrySave();
            await recovered.inbox.flushLocalWrites();
          });
          expect(tester.takeException(), isNull);
        }
      } finally {
        final home = tester.widget<HomePage>(find.byType(HomePage));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          final blocker = Directory(
            p.join(
              home.controller.store.deviceDirectory.path,
              'state.pending.json',
            ),
          );
          if (await blocker.exists()) await blocker.delete();
          await home.inbox.close();
          await home.controller.close();
          home.inbox.dispose();
          home.controller.dispose();
          await root.delete(recursive: true);
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(desktop, null);
      }
    },
  );
}
