import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/storage/storage_backup.dart';
import 'package:lanflow/core/storage/storage_location.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:path/path.dart' as p;

import '../support/test_device.dart';

void main() {
  test(
    'closing waits for an attachment draft already being imported',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-close-import-',
      );
      final data = p.join(root.path, 'data');
      final device = await TestDevice.create(data, '关闭期间的草稿');
      final source = File(p.join(root.path, 'large-draft.bin'));
      final bytes = List<int>.generate(12 * 1024 * 1024 + 7, (i) => i % 251);
      await source.writeAsBytes(bytes);
      try {
        final staged = device.inbox.stageFile(source.path);
        await device.close();
        await staged;
        device.inbox.dispose();
        device.lan.dispose();
        final reopened = await TestDevice.create(data, '关闭期间的草稿');
        try {
          final draft = reopened.inbox.store.draftAttachments.single;
          expect(draft.name, 'large-draft.bin');
          expect(
            await reopened.inbox.store.blob(draft.digest).readAsBytes(),
            bytes,
          );
        } finally {
          await reopened.close();
          reopened.inbox.dispose();
          reopened.lan.dispose();
        }
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'complete backup restores original files, drafts, favorites, trash, language and bindings',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-backup-roundtrip-',
      );
      final source = Directory(p.join(root.path, 'original'));
      final original = await TestDevice.create(source.path, '备份设备');
      final peer = await TestDevice.create(p.join(root.path, 'peer'), '另一设备');
      peer.lan.onPrompt = (_) async => true;
      final remote = await original.lan.addAddress(
        '127.0.0.1:${peer.lan.self.port}',
      );
      await original.lan.connect(remote);
      final text = (await original.inbox.addText('需要保留的收藏消息'))!;
      final gone = (await original.inbox.addText('最近删除仍可恢复'))!;
      final attachment = File(p.join(root.path, '设备.bin'));
      final bytes = List<int>.generate(2 * 1024 * 1024 + 17, (i) => i % 251);
      await attachment.writeAsBytes(bytes);
      final sent = await original.inbox.addFile(attachment.path);
      await original.inbox.stageFile(attachment.path);
      original.inbox.setDraft('待发送草稿');
      await original.inbox.setFavorites([text.item.id, sent.item.id], true);
      await original.inbox.setFavoritePreferences(
        FavoritePreferences(
          layout: 'list',
          filter: 'file',
          sort: 'oldest',
          onlyPinned: true,
        ),
      );
      await original.inbox.setFavoritesPinned(
        original.inbox.favoriteEntries.map((entry) => entry.id),
        true,
      );
      final favoritePreferences = original.inbox.favoritePreferences;
      await original.inbox.deleteItems([gone.item.id]);
      await original.inbox.setLanguage('en');
      final identity = original.lan.identity.id;
      final tokens = original.lan.sessions[peer.lan.identity.id]!.toJson();
      await original.close();
      original.inbox.dispose();
      original.lan.dispose();
      await peer.close();
      peer.inbox.dispose();
      peer.lan.dispose();
      try {
        final recovered = File(
          p.join(source.path, 'system', 'recovered', 'edited.tmp'),
        );
        await recovered.parent.create(recursive: true);
        await recovered.writeAsString(
          'Externally edited bytes must survive backup',
        );
        final backup = p.join(root.path, 'complete.zip');
        await StorageBackup.create(source, backup);
        final location = StorageLocation(source);
        final restored = await StorageBackup.restore(
          archivePath: backup,
          source: source,
          destination: p.join(root.path, 'restored'),
          location: location,
        );
        final reopened = await TestDevice.create(restored.target.path, '备份设备');
        try {
          expect(reopened.lan.identity.id, identity);
          expect(
            await File(
              p.join(restored.target.path, 'system', 'recovered', 'edited.tmp'),
            ).readAsString(),
            'Externally edited bytes must survive backup',
          );
          expect(reopened.lan.sessions.values.single.toJson(), tokens);
          expect(reopened.inbox.store.draft, '待发送草稿');
          expect(reopened.inbox.store.draftAttachments.single.name, '设备.bin');
          expect(reopened.inbox.language.value, 'en');
          expect(reopened.inbox.favoritePreferences, favoritePreferences);
          expect(
            reopened.inbox.store.favorites,
            containsAll([text.item.id, sent.item.id]),
          );
          expect(reopened.inbox.items.length, 2);
          expect(
            await reopened.inbox.store.blob(sent.item.digest).readAsBytes(),
            bytes,
          );
          expect(
            (await reopened.inbox.store.recentlyDeleted()).single.item.id,
            gone.item.id,
          );
          await restored.commit();
          expect(
            await File(
              p.join(source.path, 'system', 'messages.sqlite3'),
            ).exists(),
            isTrue,
          );
          expect(
            await File(
              p.join(restored.target.path, 'files', '设备.bin'),
            ).readAsBytes(),
            bytes,
          );
        } finally {
          await reopened.close();
          reopened.inbox.dispose();
          reopened.lan.dispose();
        }
        final before = await File(backup).readAsBytes();
        await expectLater(
          StorageBackup.create(source, backup),
          throwsFormatException,
        );
        expect(await File(backup).readAsBytes(), before);
        final contents = ZipDecoder().decodeBytes(before);
        final corrupt = Archive();
        for (final entry in contents) {
          final data = entry.content.toList();
          if (entry.name == 'files/设备.bin') data[0] ^= 0xff;
          corrupt.addFile(ArchiveFile.bytes(entry.name, data));
        }
        final damaged = File(p.join(root.path, 'tampered.zip'));
        await damaged.writeAsBytes(ZipEncoder().encode(corrupt));
        await expectLater(
          StorageBackup.restore(
            archivePath: damaged.path,
            source: source,
            destination: p.join(root.path, 'tampered-target'),
            location: location,
          ),
          throwsFormatException,
        );
        expect(
          await Directory(p.join(root.path, 'tampered-target')).exists(),
          isFalse,
        );
        expect(
          await File(p.join(source.path, 'files', '设备.bin')).readAsBytes(),
          bytes,
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'unsafe, incomplete and conflicting backup inputs preserve existing data',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-backup-invalid-',
      );
      final source = await Directory(p.join(root.path, 'original')).create();
      final sentinel = File(p.join(source.path, 'keep.data'));
      await sentinel.writeAsString('original remains');
      final location = StorageLocation(source);
      try {
        for (final name in [
          '../escape.txt',
          'system/../../escape.txt',
          'system/device/identity.json:stream',
          'files/CON.txt',
          'files\\escape.txt',
        ]) {
          final zip = File(p.join(root.path, 'invalid.zip'));
          final archive = Archive()
            ..addFile(ArchiveFile.string(name, 'hostile entry'));
          await zip.writeAsBytes(ZipEncoder().encode(archive));
          await expectLater(
            StorageBackup.restore(
              archivePath: zip.path,
              source: source,
              destination: p.join(root.path, 'target'),
              location: location,
            ),
            throwsFormatException,
          );
          expect(
            await Directory(p.join(root.path, 'target')).exists(),
            isFalse,
          );
          expect(await sentinel.readAsString(), 'original remains');
        }
        final zip = File(p.join(root.path, 'incomplete.zip'));
        final archive = Archive()
          ..addFile(
            ArchiveFile.string(
              'lanflow-backup.json',
              jsonEncode({
                'format': 'lanflow-backup',
                'schema': 1,
                'sourceRoot': source.path,
                'files': {},
              }),
            ),
          );
        await zip.writeAsBytes(ZipEncoder().encode(archive));
        await expectLater(
          StorageBackup.restore(
            archivePath: zip.path,
            source: source,
            destination: p.join(root.path, 'target'),
            location: location,
          ),
          throwsFormatException,
        );
        final target = await Directory(p.join(root.path, 'occupied')).create();
        await File(
          p.join(target.path, 'existing.data'),
        ).writeAsString('do not replace');
        await expectLater(
          StorageBackup.restore(
            archivePath: zip.path,
            source: source,
            destination: target.path,
            location: location,
          ),
          throwsFormatException,
        );
        expect(
          await File(p.join(target.path, 'existing.data')).readAsString(),
          'do not replace',
        );
        expect(
          await root
              .list()
              .where((entry) => entry.path.contains('.restoring-'))
              .isEmpty,
          isTrue,
        );
        expect((await location.resolve()).path, source.path);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
