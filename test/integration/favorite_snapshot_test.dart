import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/platform/native_core.dart';
import '../support/test_device.dart';

void main() {
  late Directory root;
  final devices = <TestDevice>[];
  setUp(
    () async => root = await Directory.systemTemp.createTemp(
      'lanflow-shared-favorites-',
    ),
  );
  tearDown(() async {
    for (final d in devices.reversed) {
      await d.close();
      d.inbox.dispose();
      d.lan.dispose();
    }
    devices.clear();
    await root.delete(recursive: true);
  });
  Future<TestDevice> create(String name) async {
    final d = await TestDevice.create('${root.path}/$name', name);
    devices.add(d);
    return d;
  }

  test(
    'restoring selected deleted messages creates one new message each without reviving old favorites',
    () async {
      final d = await create('restore');
      final a = (await d.inbox.addText('first'))!,
          b = (await d.inbox.addText('second'))!;
      await d.inbox.setFavorites([a.item.id, b.item.id], true);
      await d.inbox.deleteItems([a.item.id, b.item.id]);
      expect(d.inbox.favoriteEntries, isEmpty);
      expect(
        (await d.inbox.store.recentlyDeleted()).map((row) => row.id).toSet(),
        {a.item.id, b.item.id},
      );
      await d.inbox.restoreItem(a.item);
      await d.inbox.restoreItem(b.item);
      expect(d.inbox.items.map((e) => e.item.text).toSet(), {
        'first',
        'second',
      });
      expect(d.inbox.items, hasLength(2));
      expect(d.inbox.favoriteEntries, hasLength(2));
      expect(
        d.inbox.favoriteEntries.every(
          (e) =>
              e.originalMessageId != a.item.id &&
              e.originalMessageId != b.item.id,
        ),
        isTrue,
      );
      expect(await d.inbox.store.recentlyDeleted(), isEmpty);
    },
  );
  test(
    'favorite attachments use original bytes and cannot remain visible after deletion or restart',
    () async {
      final d = await create('files');
      final source = File('${root.path}/original.txt');
      await source.writeAsString('ORIGINAL BYTES');
      final entry = await d.inbox.addFile(source.path);
      await d.inbox.setFavorites([entry.item.id], true);
      final saved = d.inbox.favoriteEntries.single;
      final preview = await d.inbox.favoriteFileForOpening(saved);
      await preview.writeAsString('external preview edit');
      expect(
        await (await d.inbox.favoriteFileForExport(saved)).readAsString(),
        'ORIGINAL BYTES',
      );
      await d.inbox.deleteFavorites([saved.id]);
      expect(d.inbox.items, isEmpty);
      expect(d.inbox.favoriteEntries, isEmpty);
      final trash = await d.inbox.store.recentlyDeleted();
      expect(trash, hasLength(1));
      expect(trash.single.isFavorite, isFalse);
      await d.close();
      d.inbox.dispose();
      d.lan.dispose();
      devices.remove(d);
      final reopened = await create('files');
      expect(reopened.inbox.items, isEmpty);
      expect(reopened.inbox.favoriteEntries, isEmpty);
      await reopened.inbox.restoreItem(entry.item);
      final restored = reopened.inbox.items.single;
      expect(
        await (await reopened.inbox.store.fileForExport(
          restored.item,
        )).readAsString(),
        'ORIGINAL BYTES',
      );
      expect(reopened.inbox.favoriteEntries, hasLength(1));
    },
  );
  test(
    'legacy independent settings cannot disable global deletion, but unbookmarking retains the message',
    () async {
      final d = await create('legacy');
      await NativeCore.run({
        'op': 'save_meta',
        'root': d.inbox.store.directory.path,
        'value': {'linkFavoriteDeletion': false},
      });
      final entry = (await d.inbox.addText('same message'))!;
      await d.inbox.setFavorites([entry.item.id], true);
      await d.inbox.setFavorites([entry.item.id], false);
      expect(d.inbox.store.find(entry.item.id), isNotNull);
      expect(d.inbox.favoriteEntries, isEmpty);
      expect(await d.inbox.store.recentlyDeleted(), isEmpty);
      await d.inbox.setFavorites([entry.item.id], true);
      await d.inbox.deleteFavorites([d.inbox.favoriteEntries.single.id]);
      expect(d.inbox.items, isEmpty);
      expect(d.inbox.favoriteEntries, isEmpty);
    },
  );
}
