import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import '../support/test_device.dart';

Future<void> until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      fail('Strict synchronization did not converge');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Directory root;
  final devices = <TestDevice>[];
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('lanflow-strict-sync-'),
  );
  tearDown(() async {
    for (final device in devices.reversed) {
      await device.close();
      device.inbox.dispose();
      device.lan.dispose();
    }
    devices.clear();
    await root.delete(recursive: true);
  });
  Future<TestDevice> create(String name, {bool automatic = true}) async {
    final device = await TestDevice.create(
      '${root.path}/$name',
      name,
      automaticSync: automatic,
    );
    devices.add(device);
    return device;
  }

  Future<void> pair(TestDevice a, TestDevice b) async {
    b.lan.onPrompt = (_) async => true;
    await a.lan.connect(await a.lan.addAddress('127.0.0.1:${b.lan.self.port}'));
  }

  test(
    'offline devices receive deletions through a surviving peer, including favorites',
    () async {
      final a = await create('a');
      final b = await create('b');
      final c = await create('c');
      await pair(a, b);
      await pair(c, b);
      final entry = (await a.inbox.addText('remove from every device'))!;
      await until(
        () => devices.every((d) => d.inbox.store.find(entry.item.id) != null),
      );
      await b.inbox.setFavorites([entry.item.id], true);
      await until(
        () => devices.every((d) => d.inbox.favoriteEntries.length == 1),
      );
      c.inbox.setNetworkAvailable(false);
      c.lan.setReceivingPaused(true);
      await a.inbox.deleteItem(entry.item);
      await until(
        () =>
            b.inbox.store.find(entry.item.id) == null &&
            b.inbox.favoriteEntries.isEmpty,
      );
      await a.close();
      a.inbox.dispose();
      a.lan.dispose();
      devices.remove(a);
      expect(c.inbox.store.find(entry.item.id), isNotNull);
      c.lan.setReceivingPaused(false);
      c.inbox.setNetworkAvailable(true);
      await until(
        () =>
            c.inbox.store.find(entry.item.id) == null &&
            c.inbox.favoriteEntries.isEmpty,
      );
      for (final device in devices) {
        expect(device.inbox.items, isEmpty);
        expect(device.inbox.favoriteEntries, isEmpty);
      }
    },
  );
  test(
    'favorite content follows message edits and deleting a favorite deletes the message',
    () async {
      final a = await create('a', automatic: false);
      final b = await create('b', automatic: false);
      await pair(a, b);
      final entry = (await a.inbox.addText('before'))!;
      await a.inbox.setFavorites([entry.item.id], true);
      await a.inbox.syncNow();
      await b.inbox.editMessage(
        b.inbox.store.find(entry.item.id)!.item,
        text: 'after',
      );
      await b.inbox.syncNow();
      await a.inbox.syncNow();
      for (final d in devices) {
        expect(d.inbox.favoriteEntries.single.item.text, 'after');
      }
      await b.inbox.deleteFavorites([b.inbox.favoriteEntries.single.id]);
      await b.inbox.syncNow();
      await a.inbox.syncNow();
      for (final d in devices) {
        expect(d.inbox.items, isEmpty);
        expect(d.inbox.favoriteEntries, isEmpty);
      }
    },
  );
  test(
    'conversation avatars and colors sync, survive restart, and reset together',
    () async {
      final a = await create('a', automatic: false);
      final b = await create('b', automatic: false);
      await pair(a, b);
      final conversation = await a.inbox.createConversation('Shared');
      await a.inbox.setConversationAvatar(
        conversation.id,
        'heart',
        color: 0xFFE6E0F0,
      );
      await a.inbox.syncNow();
      expect(b.inbox.conversationAvatar(conversation.id), 'heart');
      expect(b.inbox.conversationAvatarColor(conversation.id), 0xFFE6E0F0);
      await b.inbox.setConversationAvatar(
        defaultConversationId,
        'star',
        color: 0xFFDCE7F3,
      );
      await b.inbox.syncNow();
      expect(a.inbox.conversationAvatar(defaultConversationId), 'star');
      await a.inbox.setConversationAvatar(conversation.id, null, color: null);
      await a.inbox.syncNow();
      expect(b.inbox.conversationAvatar(conversation.id), isNull);
      expect(b.inbox.conversationAvatarColor(conversation.id), isNull);
      await b.close();
      b.inbox.dispose();
      b.lan.dispose();
      devices.remove(b);
      final restarted = await create('b', automatic: false);
      expect(restarted.inbox.conversationAvatar(defaultConversationId), 'star');
      expect(restarted.inbox.conversationAvatar(conversation.id), isNull);
    },
  );
  test(
    'new deletions appear before any unrelated attachment is downloaded',
    () async {
      final a = await create('a', automatic: false);
      final b = await create('b', automatic: false);
      await pair(a, b);
      final old = (await b.inbox.addText('old message'))!;
      await a.inbox.syncNow();
      await b.inbox.deleteItem(old.item);
      final file = File('${root.path}/large.bin');
      await file.writeAsBytes(List.filled(1024, 7));
      await b.inbox.addFile(file.path);
      var blobs = 0;
      final handler = b.lan.onInboxRequest!;
      b.lan.onInboxRequest = (request) async {
        if (request.uri.path.startsWith('/v2/blobs/')) blobs++;
        await handler(request);
      };
      await a.inbox.syncNow();
      expect(a.inbox.store.find(old.item.id), isNull);
      expect(blobs, 0);
      expect(a.inbox.transferTasks, isNotEmpty);
      await a.inbox.syncNow();
      expect(blobs, greaterThan(0));
    },
  );
  test(
    'a deletion interrupts a slow file instead of waiting for its bytes',
    () async {
      final a = await create('a');
      final b = await create('b', automatic: false);
      await pair(a, b);
      final old = (await a.inbox.addText('delete during transfer'))!;
      await until(
        () => b.inbox.store.find(old.item.id) != null && !a.inbox.syncing,
      );
      final file = File('${root.path}/blocked.bin');
      await file.writeAsBytes(List.filled(1024 * 1024, 8));
      await b.inbox.addFile(file.path);
      final entered = Completer<void>(),
          release = Completer<void>(),
          completed = Completer<void>();
      final handler = b.lan.onInboxRequest!;
      b.lan.onInboxRequest = (request) async {
        final blocked =
            request.method == 'GET' &&
            request.uri.path.startsWith('/v2/blobs/') &&
            !entered.isCompleted;
        if (blocked) {
          entered.complete();
          await release.future;
        }
        try {
          await handler(request);
        } finally {
          if (blocked && !completed.isCompleted) completed.complete();
        }
      };
      a.inbox.requestSync(immediate: true);
      try {
        await entered.future.timeout(const Duration(seconds: 8));
        await a.inbox.deleteItem(old.item);
        await until(() => b.inbox.store.find(old.item.id) == null);
        expect(release.isCompleted, isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        await completed.future.timeout(const Duration(seconds: 8));
      }
    },
  );
}
