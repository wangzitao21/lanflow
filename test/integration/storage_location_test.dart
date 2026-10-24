import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/storage/storage_location.dart';

import '../support/test_device.dart';

void main() {
  test(
    'migration validates a new copy before switching and preserves unrelated files',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-storage-move-',
      );
      final source = Directory('${root.path}/original');
      final target = Directory('${root.path}/new/LanFlow');
      final location = StorageLocation(source);
      final original = await TestDevice.create(source.path, '迁移设备');
      final bytes = List<int>.generate(16000, (i) => i % 251);
      final file = File('${root.path}/attachment.bin');
      await file.writeAsBytes(bytes);
      final attachment = await original.inbox.addFile(file.path);
      original.inbox.setDraft('保留草稿');
      await original.inbox.setConversationPinned(
        original.inbox.conversationId,
        true,
      );
      final identity = original.lan.identity.id;
      await original.close();
      original.inbox.dispose();
      original.lan.dispose();
      final unrelated = File('${source.path}/keep-user-file.bin');
      await unrelated.writeAsString('user file');
      try {
        await expectLater(
          location.prepare(
            source: source,
            destination: '${source.path}/nested',
            migrate: true,
          ),
          throwsFormatException,
        );
        final move = await location.prepare(
          source: source,
          destination: target.path,
          migrate: true,
        );
        expect(
          await File('${source.path}/system/messages.sqlite3').exists(),
          isTrue,
        );
        final migrated = await TestDevice.create(target.path, '迁移设备');
        try {
          expect(migrated.lan.identity.id, identity);
          expect(migrated.inbox.store.draft, '保留草稿');
          expect(
            await migrated.inbox.store
                .blob(attachment.item.digest)
                .readAsBytes(),
            bytes,
          );
          await location.activate(target);
          await location.confirm();
          await move.finish();
          expect(await unrelated.readAsString(), 'user file');
          expect(
            await File('${source.path}/system/messages.sqlite3').exists(),
            isFalse,
          );
          await File(
            '${source.path}/system/storage-location.json',
          ).writeAsString('invalid');
          expect((await location.resolve()).path, target.path);
        } finally {
          await migrated.close();
          migrated.inbox.dispose();
          migrated.lan.dispose();
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'fresh location keeps original history and never inherits bindings',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-storage-fresh-',
      );
      final source = Directory('${root.path}/old');
      final location = StorageLocation(source);
      final old = await TestDevice.create(source.path, '旧设备');
      await old.inbox.addText('原位置记录');
      final identity = old.lan.identity.id;
      await old.close();
      old.inbox.dispose();
      old.lan.dispose();
      final move = await location.prepare(
        source: source,
        destination: '${root.path}/fresh',
        migrate: false,
      );
      final fresh = await TestDevice.create(move.target.path, '新资料');
      try {
        expect(fresh.inbox.items, isEmpty);
        expect(fresh.lan.sessions, isEmpty);
        expect(fresh.lan.identity.id, isNot(identity));
        await location.activate(move.target);
        await location.confirm();
        await move.finish();
        expect(
          await File('${source.path}/system/messages.sqlite3').exists(),
          isTrue,
        );
      } finally {
        await fresh.close();
        fresh.inbox.dispose();
        fresh.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'copy failure and occupied destinations leave source and locator unchanged',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-storage-failure-',
      );
      final source = Directory('${root.path}/old');
      await Directory('${source.path}/inbox').create(recursive: true);
      final database = File('${source.path}/inbox/messages.sqlite3');
      await database.writeAsString('original bytes');
      final location = StorageLocation(source);
      try {
        await expectLater(
          location.prepare(
            source: source,
            destination: '${root.path}/new',
            migrate: true,
            onProgress: (_, _) => throw StateError('Simulated disk failure'),
          ),
          throwsStateError,
        );
        expect(await database.readAsString(), 'original bytes');
        expect((await location.resolve()).path, source.path);
        expect(
          await root
              .list()
              .where((entry) => entry.path.contains('.moving-'))
              .isEmpty,
          isTrue,
        );
        final target = Directory('${root.path}/occupied');
        await target.create();
        await File(
          '${target.path}/existing.bin',
        ).writeAsString('do not replace');
        await expectLater(
          location.prepare(
            source: source,
            destination: target.path,
            migrate: false,
          ),
          throwsFormatException,
        );
        expect(
          await File('${target.path}/existing.bin').readAsString(),
          'do not replace',
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
