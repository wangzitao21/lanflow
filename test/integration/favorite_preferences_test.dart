import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/storage/local_store.dart';
import 'package:lanflow/core/storage/storage_layout.dart';
import 'package:lanflow/platform/native_core.dart';

import '../support/test_device.dart';

class _QueuedSaveStore extends InboxStore {
  _QueuedSaveStore(super.directory);
  Completer<void>? entered, release;
  bool failNext = false;
  int saves = 0;

  @override
  Future<void> save() async {
    saves++;
    final gate = release;
    if (gate != null) {
      release = null;
      entered!.complete();
      await gate.future;
      if (failNext) {
        failNext = false;
        throw const FileSystemException('Injected preference write failure');
      }
    }
    await super.save();
  }
}

void main() {
  test(
    'favorite preferences are immutable and tolerate missing or malformed old settings',
    () {
      final defaults = FavoritePreferences();
      expect(FavoritePreferences.fromJson(null), defaults);
      expect(
        FavoritePreferences.fromJson({
          'layout': 'unknown',
          'filter': 42,
          'sort': 'unknown',
          'onlyPinned': 'yes',
          'pinned': [],
        }),
        defaults,
      );
      final source = {'saved-favorite-id': 123};
      final settings = defaults.copyWith(
        layout: 'list',
        filter: 'image',
        sort: 'titleDesc',
        onlyPinned: true,
        pinned: source,
      );
      source['saved-favorite-id'] = 456;
      expect(settings.pinned['saved-favorite-id'], 123);
      expect(() => settings.pinned['new-id'] = 100, throwsUnsupportedError);
      expect(FavoritePreferences.fromJson(settings.toJson()), settings);
      expect(settings.copyWith().hashCode, settings.hashCode);
      expect(defaults.layout, 'masonry');
      expect(defaults.filter, 'all');
      expect(defaults.sort, 'newest');
      expect(defaults.onlyPinned, isFalse);
    },
  );

  test(
    'preferences and independent snapshot pins persist locally through restart without sync events',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-favorite-preferences-',
      );
      var a = await TestDevice.create('${root.path}/a', 'Preference owner');
      final b = await TestDevice.create(
        '${root.path}/b',
        'Independent preferences',
      );
      var aDisposed = false;
      try {
        b.lan.onPrompt = (_) async => true;
        await a.lan.connect(
          await a.lan.addAddress('127.0.0.1:${b.lan.self.port}'),
        );
        final first = (await a.inbox.addText('Pinned snapshot'))!;
        final second = (await a.inbox.addText('Another snapshot'))!;
        await a.inbox.setFavorites([first.item.id, second.item.id], true);
        final ids = a.inbox.favoriteEntries.map((e) => e.id).toList();
        final before = await a.inbox.store.changes(
          0,
          capabilities: 'favorites,favoriteSnapshots',
        );
        final revision = a.inbox.favoritePreferencesRevision;
        final base = a.inbox.favoritePreferences;
        final pin = a.inbox.setFavoritesPinned([ids.first], true);
        final layout = a.inbox.setFavoritePreferences(
          base.copyWith(layout: 'list'),
        );
        final sort = a.inbox.setFavoritePreferences(
          base.copyWith(sort: 'titleAsc'),
        );
        await Future.wait([pin, layout, sort]);
        expect(a.inbox.favoritePreferences.layout, 'list');
        expect(a.inbox.favoritePreferences.sort, 'titleAsc');
        expect(a.inbox.favoritePreferences.pinned.keys, [ids.first]);
        await a.inbox.setFavoritePreferences(
          FavoritePreferences(
            layout: 'list',
            filter: 'text',
            sort: 'titleAsc',
            onlyPinned: true,
          ),
        );
        await a.inbox.setFavoritesPinned([ids.first], true);
        final stamp = a.inbox.favoritePreferences.pinned[ids.first];
        await a.inbox.setFavoritesPinned([
          ids.first,
          first.item.id,
          'missing-favorite',
        ], true);
        expect(a.inbox.favoritePreferences.pinned, {ids.first: stamp});
        await a.inbox.setFavoritesPinned([ids.last], true);
        expect(a.inbox.favoritePreferencesRevision, greaterThan(revision));
        final expected = a.inbox.favoritePreferences;
        final after = await a.inbox.store.changes(
          0,
          capabilities: 'favorites,favoriteSnapshots',
        );
        expect(
          after,
          before,
          reason: 'local preferences must not create synchronization events',
        );
        final saved =
            await NativeCore.run({
                  'op': 'snapshot',
                  'root': a.inbox.store.directory.path,
                })
                as Map;
        expect(saved['favoritePreferences'], expected.toJson());
        await a.inbox.syncNow();
        expect(b.inbox.favoriteEntries.length, 2);
        expect(b.inbox.favoritePreferences, FavoritePreferences());
        await a.inbox.deleteItem(first.item);
        expect(
          a.inbox.favoritePreferences.pinned.containsKey(ids.first),
          isTrue,
        );
        await a.close();
        a.inbox.dispose();
        a.lan.dispose();
        aDisposed = true;
        a = await TestDevice.create('${root.path}/a', 'Preference owner');
        aDisposed = false;
        expect(a.inbox.favoritePreferences, expected);
        expect(a.inbox.favoriteEntries.length, 2);
        await a.inbox.setFavoritesPinned([ids.first], false);
        expect(a.inbox.favoritePreferences.pinned.keys, [ids.last]);
        expect(a.inbox.favoritePreferences.layout, 'list');
        expect(a.inbox.favoritePreferences.sort, 'titleAsc');
      } finally {
        if (!aDisposed) {
          await a.close();
          a.inbox.dispose();
          a.lan.dispose();
        }
        await b.close();
        b.inbox.dispose();
        b.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'failed preference save rolls back before queued pin updates and close waits for all writes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-preference-rollback-',
      );
      final lan = LanController(
        store: LocalStore(root),
        receiveDirectory: StorageLayout.received(root),
        enableDiscovery: false,
        preferredPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      await lan.start();
      final store = _QueuedSaveStore(root);
      final inbox = InboxController(
        lan: lan,
        store: store,
        automaticSync: false,
      );
      await inbox.start();
      final first = (await inbox.addText('First'))!;
      final second = (await inbox.addText('Second'))!;
      await inbox.setFavorites([first.item.id, second.item.id], true);
      final ids = inbox.favoriteEntries.map((e) => e.id).toList();
      final gate = Completer<void>();
      store.entered = Completer<void>();
      store.release = gate;
      store.failNext = true;
      final saving = inbox.setFavoritePreferences(
        inbox.favoritePreferences.copyWith(layout: 'list', sort: 'titleDesc'),
      );
      final failed = expectLater(saving, throwsA(isA<FileSystemException>()));
      await store.entered!.future;
      final firstPin = inbox.setFavoritesPinned([ids.first], true);
      final secondPin = inbox.setFavoritesPinned([ids.last], true);
      final presentation = inbox.setFavoritePreferences(
        inbox.favoritePreferences.copyWith(sort: 'titleAsc', filter: 'text'),
      );
      await Future<void>.delayed(Duration.zero);
      final savesWhileBlocked = store.saves;
      var closed = false;
      final closing = inbox.close().then((_) => closed = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(closed, isFalse);
      expect(
        store.saves,
        savesWhileBlocked,
        reason:
            'the blocked preference transaction serializes later pin writes',
      );
      gate.complete();
      await failed;
      await firstPin;
      await secondPin;
      await presentation;
      await closing;
      expect(inbox.favoritePreferences.layout, 'masonry');
      expect(inbox.favoritePreferences.sort, 'titleAsc');
      expect(inbox.favoritePreferences.filter, 'text');
      expect(inbox.favoritePreferences.pinned.keys.toSet(), ids.toSet());
      final expected = inbox.favoritePreferences;
      await lan.close();
      inbox.dispose();
      lan.dispose();
      final reopened = InboxStore(root);
      try {
        await reopened.load();
        expect(reopened.favoritePreferences, expected);
        expect(reopened.favoriteEntries.length, 2);
      } finally {
        await reopened.close();
        await root.delete(recursive: true);
      }
    },
  );
}
