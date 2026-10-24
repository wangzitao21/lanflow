import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/storage/local_store.dart';
import 'package:lanflow/core/storage/storage_layout.dart';

import '../support/test_device.dart';

class _DelayedSettingsStore extends InboxStore {
  _DelayedSettingsStore(super.directory);
  Completer<void>? releaseSave;
  Completer<void>? saving;
  bool failAfterRelease = false;

  @override
  Future<void> save() async {
    final release = releaseSave;
    if (release != null) {
      releaseSave = null;
      saving!.complete();
      await release.future;
      if (failAfterRelease) {
        throw const FileSystemException('Injected settings save failure');
      }
    }
    await super.save();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  final devices = <TestDevice>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanflow-favorite-snapshots-');
  });
  tearDown(() async {
    for (final device in devices.reversed) {
      await device.close();
      device.inbox.dispose();
      device.lan.dispose();
    }
    devices.clear();
    await root.delete(recursive: true);
  });
  Future<TestDevice> create(String name) async {
    final device = await TestDevice.create('${root.path}/$name', name);
    devices.add(device);
    return device;
  }

  test(
    'sequential undo restores every selected message and preserves independent favorites',
    () async {
      final device = await create('sequential-restore');
      final first = (await device.inbox.addText('first selected message'))!;
      final second = (await device.inbox.addText('second selected message'))!;
      await device.inbox.setFavorites([first.item.id, second.item.id], true);
      final favorites = device.inbox.favoriteEntries
          .map((entry) => entry.id)
          .toSet();
      await device.inbox.deleteItems([first.item.id, second.item.id]);
      for (final item in [first.item, second.item]) {
        await device.inbox.restoreItem(item);
      }
      expect(device.inbox.items.map((entry) => entry.item.text).toSet(), {
        first.item.text,
        second.item.text,
      });
      expect(device.inbox.items.length, 2);
      expect(
        device.inbox.items.every(
          (entry) =>
              entry.item.id != first.item.id && entry.item.id != second.item.id,
        ),
        isTrue,
      );
      expect(
        device.inbox.favoriteEntries.map((entry) => entry.id).toSet(),
        favorites,
      );
      expect(await device.inbox.store.recentlyDeleted(), isEmpty);
    },
  );

  test(
    'independent snapshots keep original attachment bytes after source deletion and restart',
    () async {
      final first = await create('saved');
      final text = (await first.inbox.addText('独立保存的原文'))!;
      final source = File('${root.path}/original.txt');
      await source.writeAsString('ORIGINAL BYTES');
      final file = await first.inbox.addFile(source.path);
      final originalPath = (await first.inbox.store.fileForExport(
        file.item,
      )).path;
      await first.inbox.setFavorites([text.item.id, file.item.id], true);
      final snapshots = List.of(first.inbox.favoriteEntries);
      expect(snapshots.length, 2);
      expect(
        snapshots.every((entry) => entry.id != entry.originalMessageId),
        isTrue,
      );
      final attachment = snapshots.singleWhere((entry) => entry.item.isFile);
      expect(
        (await first.inbox.favoriteFileForExport(attachment)).path,
        originalPath,
      );
      final preview = await first.inbox.favoriteFileForOpening(attachment);
      expect(preview.path, isNot(originalPath));
      await preview.writeAsString('external edit to preview only');
      expect(
        await (await first.inbox.favoriteFileForExport(
          attachment,
        )).readAsString(),
        'ORIGINAL BYTES',
      );
      await first.inbox.deleteItems([text.item.id, file.item.id]);
      expect(first.inbox.items, isEmpty);
      expect(first.inbox.favoriteEntries.length, 2);
      expect(first.inbox.diagnostics()['favorites'], 2);
      expect(await first.inbox.favoriteAvailable(attachment), isTrue);
      final heldStore = first.inbox.store;
      await first.close();
      first.inbox.dispose();
      first.lan.dispose();
      devices.remove(first);
      expect(heldStore.favoriteEntries, isEmpty);
      expect(heldStore.findFavorite(attachment.id), isNull);
      final reopened = await create('saved');
      expect(reopened.inbox.items, isEmpty);
      expect(
        reopened.inbox.favoriteEntries.map((entry) => entry.id).toSet(),
        snapshots.map((entry) => entry.id).toSet(),
      );
      expect(
        await (await reopened.inbox.favoriteFileForExport(
          attachment,
        )).readAsString(),
        'ORIGINAL BYTES',
      );
      await reopened.inbox.deleteFavorites([attachment.id]);
      final trash = await reopened.inbox.store.recentlyDeleted();
      expect(trash.where((entry) => entry.isFavorite).single.id, attachment.id);
      final revision = reopened.inbox.store.favoritesRevision;
      await reopened.inbox.restoreFavorites([attachment.id]);
      expect(reopened.inbox.store.favoritesRevision, greaterThan(revision));
      expect(reopened.inbox.items, isEmpty);
      expect(reopened.inbox.favoriteEntries.length, 2);
    },
  );

  test(
    'linked deletion setting save failure rolls back before concurrent close persists settings',
    () async {
      final directory = Directory('${root.path}/settings');
      final lan = LanController(
        store: LocalStore(directory),
        receiveDirectory: StorageLayout.received(directory),
        enableDiscovery: false,
        preferredPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      await lan.start();
      final store = _DelayedSettingsStore(directory);
      final inbox = InboxController(
        lan: lan,
        store: store,
        automaticSync: false,
      );
      final device = TestDevice(lan, inbox);
      devices.add(device);
      await inbox.start();
      final text = (await inbox.addText('persist after settings failure'))!;
      await inbox.setFavorites([text.item.id], true);
      final favorite = inbox.favoriteEntries.single;
      final release = Completer<void>();
      store.releaseSave = release;
      store.saving = Completer<void>();
      store.failAfterRelease = true;
      final change = inbox.setLinkFavoriteDeletion(true);
      final failure = expectLater(change, throwsA(isA<FileSystemException>()));
      await store.saving!.future;
      var closed = false;
      final close = device.close().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        closed,
        isFalse,
        reason: 'close must await the accepted settings operation',
      );
      release.complete();
      await failure;
      await close;
      expect(inbox.linkFavoriteDeletion, isFalse);
      inbox.dispose();
      lan.dispose();
      devices.remove(device);
      final reopened = await create('settings');
      expect(reopened.inbox.linkFavoriteDeletion, isFalse);
      expect(reopened.inbox.store.find(text.item.id), isNotNull);
      expect(reopened.inbox.favoriteEntries.single.id, favorite.id);
      await reopened.inbox.setLinkFavoriteDeletion(true);
      await reopened.inbox.setFavorites([text.item.id], false);
      expect(reopened.inbox.items, isEmpty);
      expect(reopened.inbox.favoriteEntries, isEmpty);
      expect(
        (await reopened.inbox.store.recentlyDeleted())
            .map((entry) => entry.source)
            .toSet(),
        {'favorite', 'conversation'},
      );
    },
  );
}
