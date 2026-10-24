import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/storage/storage_location.dart';
import 'package:lanflow/platform/platform_bridge.dart';
import 'package:lanflow/runtime.dart';
import 'package:lanflow/ui/chat/home_page.dart';

void main() {
  testWidgets(
    'Host keeps failed title edits in the live session and flushes them before backup move and quit',
    (tester) async {
      late Directory temporary;
      late RuntimeSession initial;
      late String conversation;
      await tester.runAsync(() async {
        temporary = await Directory.systemTemp.createTemp(
          'lanflow-title-close-',
        );
        initial = await RuntimeSession.open(
          Directory('${temporary.path}/data'),
          enableDiscovery: false,
          preferredPort: 0,
          bindAddress: InternetAddress.loopbackIPv4,
        );
        await initial.start();
        conversation = (await initial.inbox.createConversation(
          'Original title',
        )).id;
      });
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('lanflow/desktop'),
            (_) async => null,
          );
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

      Future<Object?> complete(
        Future<dynamic> Function() action, {
        bool settle = true,
      }) async {
        var finished = false;
        Object? failure;
        await tester.runAsync(() async {
          unawaited(
            action().then<void>(
              (_) => finished = true,
              onError: (Object error) {
                failure = error;
                finished = true;
              },
            ),
          );
        });
        for (var tick = 0; tick < 600 && !finished; tick++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(finished, isTrue);
        if (settle) await tester.pumpAndSettle();
        return failure;
      }

      Future<void> edit(String value) async {
        await tester.tapAt(
          tester.getCenter(find.byKey(ValueKey('conversation-$conversation'))),
          buttons: kSecondaryMouseButton,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('desktop-menu-rename')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('conversation-name')),
          value,
        );
      }

      try {
        await edit('Title before backup');
        final before = tester.widget<HomePage>(find.byType(HomePage));
        final titleCommit = before.inbox.onCommitPendingEdits!;
        before.inbox.onCommitPendingEdits = () async {
          throw StateError('injected title commit failure');
        };
        expect(
          await complete(
            () => before.inbox.backupStorage!('${temporary.path}/backup.zip'),
          ),
          isNotNull,
        );
        final retained = tester.widget<HomePage>(find.byType(HomePage));
        expect(identical(retained.inbox, before.inbox), isTrue);
        expect(initial.isClosed, isFalse);
        expect(retained.inbox.store.loaded, isTrue);
        expect(
          tester
              .widget<TextField>(
                find.byKey(const ValueKey('conversation-name')),
              )
              .controller!
              .text,
          'Title before backup',
        );
        expect(retained.inbox.conversation.name, 'Original title');
        await tester.runAsync(() async {
          expect(await File('${temporary.path}/backup.zip').exists(), isFalse);
        });
        retained.inbox.onCommitPendingEdits = titleCommit;
        expect(
          await complete(
            () => retained.inbox.backupStorage!('${temporary.path}/backup.zip'),
          ),
          isNull,
        );
        var home = tester.widget<HomePage>(find.byType(HomePage));
        expect(identical(home.inbox, retained.inbox), isFalse);
        expect(home.inbox.conversation.name, 'Title before backup');

        await edit('Title before move');
        expect(
          await complete(
            () => home.inbox.relocateStorage!('${temporary.path}/moved', true),
          ),
          isNull,
        );
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(home.inbox.conversation.name, 'Title before move');
        expect(
          home.inbox.store.directory.path,
          '${temporary.path}${Platform.pathSeparator}moved',
        );

        await edit('Title before quit');
        expect(
          await complete(() => PlatformBridge.prepareToQuit(), settle: false),
          isNull,
        );
        expect(home.inbox.store.loaded, isFalse);
        await tester.runAsync(() async {
          final reopened = InboxStore(home.inbox.store.directory);
          await reopened.load();
          expect(
            reopened.conversations[conversation]!.name,
            'Title before quit',
          );
          await reopened.close();
        });
        expect(tester.takeException(), isNull);
      } finally {
        final home = tester.widget<HomePage>(find.byType(HomePage));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await home.inbox.close();
          await home.controller.close();
          home.inbox.dispose();
          home.controller.dispose();
          await temporary.delete(recursive: true);
        });
        PlatformBridge.setQuitHandler(() async {}, fallback: true);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('lanflow/desktop'),
              null,
            );
      }
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
    skip: !Platform.isWindows,
  );
}
