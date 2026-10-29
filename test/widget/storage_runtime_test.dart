import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:lanflow/core/storage/storage_location.dart';
import 'package:lanflow/runtime.dart';
import 'package:lanflow/ui/chat/home_page.dart';
import 'package:lanflow/platform/native_core.dart';

class _FailingStorageLocation extends StorageLocation {
  _FailingStorageLocation(super.bootstrap);
  bool failNextCopy = false;
  bool failActivation = false;
  bool failNextDiscard = false;
  @override
  Future<void> activate(Directory root) async {
    if (failActivation) {
      failActivation = false;
      throw const FileSystemException('Simulated locator write failure');
    }
    await super.activate(root);
  }

  @override
  Future<StorageMove> prepare({
    required Directory source,
    required String destination,
    required bool migrate,
    void Function(int, int)? onProgress,
  }) async {
    final move = await super.prepare(
      source: source,
      destination: destination,
      migrate: migrate,
      onProgress: (completed, total) {
        onProgress?.call(completed, total);
        if (failNextCopy && completed > 0) {
          failNextCopy = false;
          throw const FileSystemException(
            'Simulated full disk during migration',
          );
        }
      },
    );
    if (failNextDiscard) {
      failNextDiscard = false;
      return _UndeletableMove(move);
    }
    return move;
  }
}

class _UndeletableMove extends StorageMove {
  _UndeletableMove(this.original)
    : super(
        original.source,
        original.target,
        original.stage,
        original.bootstrap,
        original.id,
        original.migrate,
      );
  final StorageMove original;
  @override
  Future<void> discard() async =>
      throw const FileSystemException('Simulated cleanup permission failure');
  @override
  Future<bool> finish() => original.finish();
}

void main() {
  testWidgets(
    'switching storage replaces the live session and fresh mode retains the old copy',
    (tester) async {
      late Directory root;
      late RuntimeSession initial;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp(
          'lanflow-runtime-storage-',
        );
        initial = await RuntimeSession.open(
          Directory('${root.path}/original'),
          enableDiscovery: false,
          preferredPort: 0,
          bindAddress: InternetAddress.loopbackIPv4,
        );
        await initial.start();
        await initial.inbox.addText('迁移后仍能阅读');
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
      final location = _FailingStorageLocation(
        Directory('${root.path}/original'),
      );
      await tester.pumpWidget(
        LanFlowHost(session: initial, location: location),
      );
      await tester.pumpAndSettle();
      final identity = initial.lan.identity.id;
      Map<String, dynamic>? cleanupResult;
      Future<void> relocate(
        String target,
        bool migrate, {
        String? archive,
        bool backup = false,
        bool? clearTrash,
        bool createIfEmpty = false,
      }) async {
        var done = false;
        Object? error;
        final home = tester.widget<HomePage>(find.byType(HomePage));
        await tester.runAsync(() async {
          final operation = clearTrash != null
              ? home.inbox.cleanupStorage!(clearTrash).then<void>((result) {
                  cleanupResult = result;
                })
              : backup
              ? home.inbox.backupStorage!(target)
              : archive != null
              ? home.inbox.restoreStorage!(archive, target)
              : home.inbox.relocateStorage!(
                  target,
                  migrate,
                  createIfEmpty: createIfEmpty,
                );
          unawaited(
            operation
                .then<void>((_) {
                  done = true;
                })
                .catchError((Object e) {
                  error = e;
                  done = true;
                }),
          );
          if (target.endsWith('/moved')) {
            await home.inbox.relocateStorage!('${root.path}/duplicate', false);
          }
        });
        for (var i = 0; i < 500 && !done; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 20));
        }
        expect(error, isNull);
        expect(done, isTrue);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      try {
        await relocate('${root.path}/moved', true);
        var home = tester.widget<HomePage>(find.byType(HomePage));
        expect(
          p.equals(home.controller.store.directory.path, '${root.path}/moved'),
          isTrue,
        );
        expect(home.inbox.items.single.item.text, '迁移后仍能阅读');
        expect(home.controller.identity.id, identity);
        expect(
          await tester.runAsync(
            () => Directory('${root.path}/duplicate').exists(),
          ),
          isFalse,
        );
        location.failNextCopy = true;
        await relocate('${root.path}/failed', true);
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(
          p.equals(home.controller.store.directory.path, '${root.path}/moved'),
          isTrue,
        );
        expect(home.inbox.items.single.item.text, '迁移后仍能阅读');
        expect(find.textContaining('已回到原位置'), findsOneWidget);
        location.failActivation = true;
        await relocate('${root.path}/failed-activation', true);
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(
          p.equals(home.inbox.store.directory.path, '${root.path}/moved'),
          isTrue,
        );
        expect(home.inbox.items.single.item.text, '迁移后仍能阅读');
        expect(
          await tester.runAsync(
            () => Directory('${root.path}/failed-activation').exists(),
          ),
          isFalse,
        );
        location.failActivation = true;
        location.failNextDiscard = true;
        await relocate('${root.path}/failed-cleanup', true);
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(
          p.equals(home.inbox.store.directory.path, '${root.path}/moved'),
          isTrue,
        );
        expect(home.inbox.items.single.item.text, '迁移后仍能阅读');
        expect(
          await tester.runAsync(
            () => Directory('${root.path}/failed-cleanup').exists(),
          ),
          isTrue,
        );
        final backup = '${root.path}/complete.zip';
        await relocate(backup, false, backup: true);
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(home.controller.identity.id, identity);
        await tester.runAsync(() => home.inbox.addText('备份之后的原位置记录'));
        await relocate('${root.path}/restored', false, archive: backup);
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(home.controller.identity.id, identity);
        expect(home.inbox.items.single.item.text, '迁移后仍能阅读');
        expect(
          p.equals(home.inbox.store.directory.path, '${root.path}/restored'),
          isTrue,
        );
        await tester.runAsync(() async {
          final original =
              await NativeCore.run({'op': 'open', 'root': '${root.path}/moved'})
                  as Map;
          expect((original['entries'] as List).length, 2);
          await NativeCore.run({'op': 'close', 'root': '${root.path}/moved'});
          await File(
            '${root.path}/invalid.zip',
          ).writeAsString('invalid backup');
        });
        await relocate(
          '${root.path}/failed-restore',
          false,
          archive: '${root.path}/invalid.zip',
        );
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(
          p.equals(home.inbox.store.directory.path, '${root.path}/restored'),
          isTrue,
        );
        expect(home.inbox.items.single.item.text, '迁移后仍能阅读');
        expect(
          await tester.runAsync(
            () => Directory('${root.path}/failed-restore').exists(),
          ),
          isFalse,
        );
        await tester.runAsync(() async {
          final attached = File('${root.path}/protected.bin');
          await attached.writeAsBytes([1, 2, 3]);
          final message = await home.inbox.addFile(attached.path);
          await home.inbox.stageFile(attached.path);
          await home.inbox.deleteItem(message.item);
          final unused = File('${root.path}/unused.bin');
          await unused.writeAsBytes([7, 8, 9, 10]);
          await home.inbox.store.importFile(
            unused.path,
            name: 'unused.bin',
            kind: 'file',
          );
          await File(
            '${root.path}/restored/files/user-owned.data',
          ).writeAsString('user-owned');
        });
        await relocate('cleanup', false, clearTrash: false);
        expect(cleanupResult?['removedFiles'], 1);
        expect(cleanupResult?['releasedBytes'], 4);
        expect(cleanupResult?['clearedTrash'], 0);
        await relocate('cleanup', false, clearTrash: true);
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(cleanupResult?['clearedTrash'], 1);
        expect(cleanupResult?['releasedBytes'], 0);
        expect(home.inbox.store.draftAttachments.single.name, 'protected.bin');
        await tester.runAsync(() async {
          expect(await home.inbox.store.recentlyDeleted(), isEmpty);
          expect(
            await File(
              '${root.path}/restored/files/protected.bin',
            ).readAsBytes(),
            [1, 2, 3],
          );
          expect(
            await File(
              '${root.path}/restored/files/user-owned.data',
            ).readAsString(),
            'user-owned',
          );
        });
        await relocate('${root.path}/needs-confirmation', false);
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(home.controller.store.directory.path, '${root.path}/restored');
        expect(
          await tester.runAsync(
            () => Directory('${root.path}/needs-confirmation').exists(),
          ),
          false,
        );

        late String existingIdentity;
        await tester.runAsync(() async {
          final existing = await RuntimeSession.open(
            Directory('${root.path}/existing-profile'),
            name: '目标位置设备',
            enableDiscovery: false,
            preferredPort: 0,
            bindAddress: InternetAddress.loopbackIPv4,
          );
          await existing.start();
          existingIdentity = existing.lan.identity.id;
          final item = (await existing.inbox.addText('目标位置独立记录'))!;
          await existing.inbox.setFavorites([item.item.id], true);
          existing.inbox.setDraft('目标位置草稿');
          await existing.inbox.setAppearance('dark');
          await existing.inbox.setLanguage('en');
          await existing.close();
          existing.dispose();
        });
        await relocate('${root.path}/existing-profile', false);
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(home.controller.identity.id, existingIdentity);
        expect(home.controller.name, '目标位置设备');
        expect(home.inbox.items.single.item.text, '目标位置独立记录');
        expect(home.inbox.favoriteEntries, hasLength(1));
        expect(home.inbox.store.draft, '目标位置草稿');
        expect(home.inbox.appearance.value, 'dark');
        expect(home.inbox.language.value, 'en');
        expect(
          (await tester.runAsync(location.resolve))!.path,
          '${root.path}/existing-profile',
        );
        // Switching back must load the original profile rather than merge or
        // overwrite either side, and the remembered path must follow it.
        await relocate('${root.path}/restored', false);
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(home.controller.identity.id, identity);
        expect(home.inbox.items.single.item.text, '迁移后仍能阅读');
        expect(home.inbox.language.value, 'zh');
        expect(
          (await tester.runAsync(location.resolve))!.path,
          '${root.path}/restored',
        );

        await relocate('${root.path}/fresh', false, createIfEmpty: true);
        home = tester.widget<HomePage>(find.byType(HomePage));
        expect(home.inbox.items, isEmpty);
        expect(home.controller.identity.id, isNot(identity));
        expect(
          await tester.runAsync(
            () => File('${root.path}/moved/system/messages.sqlite3').exists(),
          ),
          isTrue,
        );
      } finally {
        final home = tester.widget<HomePage>(find.byType(HomePage));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await home.controller.close();
          await home.inbox.close();
          home.controller.dispose();
          home.inbox.dispose();
          await root.delete(recursive: true);
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('lanflow/desktop'),
              null,
            );
      }
    },
  );
}
