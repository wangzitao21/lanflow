import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_api.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/platform/native_core.dart';

import '../support/test_device.dart';

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Sync audit timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  final devices = <TestDevice>[];
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanflow-sync-audit-');
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
  Future<TestDevice> create(String name, {bool automatic = false}) async {
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
    final peer = await a.lan.addAddress('127.0.0.1:${b.lan.self.port}');
    await a.lan.connect(peer);
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  test(
    'a paused receiver is reachable and explains why syncing waits',
    () async {
      final a = await create('sender');
      final b = await create('paused');
      await pair(a, b);
      final item = (await a.inbox.addText('wait for resume'))!;
      b.lan.setReceivingPaused(true);
      await a.inbox.syncNow();
      final status = a.inbox.statuses['device:${b.lan.identity.id}']!;
      expect(status.errorCategory, 'paused');
      expect(status.online, isTrue);
      expect(status.error, '对方已暂停同步，恢复后会继续');
      expect(status.needsAttention, isFalse);
      expect(a.inbox.copyDetails(item).single.detail, status.error);
      b.lan.setReceivingPaused(false);
      await a.inbox.retrySync('device:${b.lan.identity.id}');
      expect(b.inbox.store.find(item.item.id), isNotNull);
      expect(status.error, isNull);
    },
  );

  test(
    'a busy peer retries an announced pull with no local outgoing work',
    () async {
      final a = await create('reader', automatic: true);
      final b = await create('writer');
      await pair(a, b);
      await until(
        () =>
            a.inbox.statuses.values.any((s) => s.lastSuccess != null) &&
            !a.inbox.syncing,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final handler = b.lan.onInboxRequest!;
      var failures = 0;
      b.lan.onInboxRequest = (request) async {
        if (request.method == 'GET' &&
            request.uri.path == '/v3/changes' &&
            failures++ == 0) {
          await inboxReply(request, 503, {'error': '设备忙，请稍后重试'});
          return;
        }
        await handler(request);
      };
      final note = (await b.inbox.addText('only on the remote device'))!;
      // A discovery event advertises new remote work, with no local event to push.
      await a.lan.addAddress('127.0.0.1:${b.lan.self.port}');
      await until(() => a.inbox.statuses.values.any((s) => s.failures > 0));
      final status = a.inbox.statuses['device:${b.lan.identity.id}']!;
      expect(status.online, isTrue);
      expect(status.errorCategory, 'busy');
      expect(status.error, '对方暂时忙，稍后自动重试');
      expect(status.retryAfter, isNotNull);
      await until(() => a.inbox.store.find(note.item.id) != null);
    },
  );

  test(
    'retry on an unavailable local network does not silently clear a failure',
    () async {
      final a = await create('retry');
      final b = await create('target');
      await pair(a, b);
      await a.inbox.syncNow();
      final key = 'device:${b.lan.identity.id}';
      a.inbox.statuses[key]!
        ..needsAttention = true
        ..error = '连接已失效，请重新配对'
        ..errorCategory = 'authentication';
      a.inbox.setNetworkAvailable(false);
      await expectLater(a.inbox.retrySync(key), throwsA(isA<StateError>()));
      expect(a.inbox.statuses[key]!.needsAttention, isTrue);
    },
  );

  test(
    'full snapshots replace edited content while preserving row references',
    () async {
      final a = await create('snapshot');
      final entry = (await a.inbox.addText('before'))!;
      await NativeCore.run({
        'op': 'edit_message',
        'root': a.inbox.store.directory.path,
        'id': entry.item.id,
        'text': 'after',
        'name': '',
      });
      final snapshot = await NativeCore.run({
        'op': 'snapshot',
        'root': a.inbox.store.directory.path,
      });
      a.inbox.store.applySnapshot(Map<String, dynamic>.from(snapshot as Map));
      expect(a.inbox.store.find(entry.item.id), same(entry));
      expect(entry.item.text, 'after');
    },
  );

  test(
    'an old network exchange cannot replace a newly discovered address',
    () async {
      final a = await create('address-reader');
      final b = await create('address-writer');
      await pair(a, b);
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        b.lan.identity.context,
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final finished = Completer<void>();
      server.listen((request) async {
        await request.drain<void>();
        if (!entered.isCompleted) entered.complete();
        await release.future;
        try {
          await inboxReply(request, 200, {
            'keys': <String, String>{},
            'members': <Object>[],
            'device': {...b.lan.self.toJson(), 'port': server.port},
          });
        } finally {
          if (!finished.isCompleted) finished.complete();
        }
      });
      final old = Peer.fromJson({
        ...b.lan.self.toJson(),
        'port': server.port,
      }, address: '127.0.0.1');
      a.lan.peers[b.lan.identity.id] = old;
      final exchange = a.lan.refreshDeviceNetwork(old);
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        await a.lan.addAddress('127.0.0.1:${b.lan.self.port}');
        release.complete();
        await exchange;
        expect(a.lan.peers[b.lan.identity.id]!.port, b.lan.self.port);
      } finally {
        if (!release.isCompleted) release.complete();
        await exchange;
        await finished.future;
        await server.close(force: true);
      }
    },
  );

  test(
    'authenticated inbound membership refresh repairs a stale sender address',
    () async {
      final a = await create('inbound');
      final b = await create('moved');
      await pair(a, b);
      a.lan.peers[b.lan.identity.id]!.address = '127.0.0.2';
      await b.lan.refreshDeviceNetwork(b.lan.peers[a.lan.identity.id]!);
      expect(a.lan.peers[b.lan.identity.id]!.address, '127.0.0.1');
    },
  );

  test(
    'a different device at a saved address is an identity failure',
    () async {
      final a = await create('identity-reader');
      final b = await create('expected');
      final c = await create('different');
      await pair(a, b);
      a.lan.peers[b.lan.identity.id]!.port = c.lan.self.port;
      await a.inbox.addText('never send to the replacement');
      await a.inbox.syncNow();
      final status = a.inbox.statuses['device:${b.lan.identity.id}']!;
      expect(status.errorCategory, 'identity');
      expect(status.needsAttention, isTrue);
      expect(status.error, '设备身份校验失败，请确认设备地址或重新绑定');
      expect(c.inbox.items, isEmpty);
    },
  );

  test(
    'pausing a pull still displays metadata committed before cancellation',
    () async {
      final a = await create('pausing-reader');
      final b = await create('paused-source');
      await pair(a, b);
      final note = (await b.inbox.addText('committed before file transfer'))!;
      final source = File('${root.path}/pending.bin');
      await source.writeAsBytes(List.filled(1024, 31));
      await b.inbox.addFile(source.path);
      final handler = b.lan.onInboxRequest!;
      final entered = Completer<void>();
      final release = Completer<void>();
      final finished = Completer<void>();
      b.lan.onInboxRequest = (request) async {
        final blocked =
            request.method == 'GET' &&
            request.uri.path.startsWith('/v2/blobs/');
        if (blocked) {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
        try {
          await handler(request);
        } finally {
          if (blocked && !finished.isCompleted) finished.complete();
        }
      };
      final running = a.inbox.syncNow();
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        a.lan.setReceivingPaused(true);
        await running.timeout(const Duration(seconds: 5));
        expect(a.inbox.store.find(note.item.id), isNotNull);
        expect(a.inbox.syncProblems, isEmpty);
      } finally {
        release.complete();
        await running;
        await finished.future.timeout(const Duration(seconds: 5));
      }
    },
  );

  test(
    'expired pairing can be repaired without removing local history',
    () async {
      final a = await create('repair-sender');
      final b = await create('repair-target');
      await pair(a, b);
      b.lan.forgetPeer(a.lan.identity.id);
      final note = (await a.inbox.addText('retained across pairing repair'))!;
      await a.inbox.syncNow();
      final key = 'device:${b.lan.identity.id}';
      expect(a.inbox.statuses[key]!.errorCategory, 'authentication');
      expect(a.inbox.statuses[key]!.needsAttention, isTrue);
      final peer = a.lan.peers[b.lan.identity.id]!;
      final oldSession = a.lan.sessions[peer.id];
      b.lan.onPrompt = (_) async => false;
      await expectLater(
        a.lan.connect(peer, rePair: true),
        throwsA(isA<StateError>()),
      );
      expect(a.lan.sessions[peer.id], same(oldSession));
      b.lan.onPrompt = (_) async => true;
      await a.lan.connect(peer, rePair: true);
      await a.inbox.retrySync(key);
      expect(b.inbox.store.find(note.item.id), isNotNull);
      expect(a.inbox.store.find(note.item.id), same(note));
      expect(a.inbox.syncProblems, isEmpty);
    },
  );

  test(
    'three devices converge after simultaneous edits deletes and chunked attachments',
    () async {
      final a = await create('converge-a');
      final b = await create('converge-b');
      final c = await create('converge-c');
      await pair(a, b);
      await pair(c, b);
      await until(
        () => [a, b, c].every((device) => device.lan.sessions.length == 2),
      );
      final note = (await a.inbox.addText('original text'))!;
      final removed = (await a.inbox.addText('delete from another device'))!;
      await a.inbox.syncNow();
      await b.inbox.syncNow();
      await c.inbox.syncNow();
      await Future.wait([
        b.inbox.editMessage(
          b.inbox.store.find(note.item.id)!.item,
          text: 'edit B',
        ),
        c.inbox.editMessage(
          c.inbox.store.find(note.item.id)!.item,
          text: 'edit C',
        ),
      ]);
      await b.inbox.setFavorites([note.item.id], true);
      await c.inbox.deleteItem(c.inbox.store.find(removed.item.id)!.item);
      final bytes = List<int>.generate(
        5 * 1024 * 1024 + 23,
        (index) => index % 251,
      );
      final source = File('${root.path}/multi-route.bin');
      await source.writeAsBytes(bytes);
      final attachment = await a.inbox.addFile(source.path);
      await Future.wait([
        b.inbox.addText('new from B'),
        c.inbox.addText('new from C'),
      ]);
      for (var round = 0; round < 40; round++) {
        await Future.wait([
          a.inbox.syncNow(),
          b.inbox.syncNow(),
          c.inbox.syncNow(),
        ]);
        if (round >= 2 && [a,b,c].every((d)=>d.inbox.transferTasks.isEmpty)) break;
        await Future<void>.delayed(const Duration(milliseconds:250));
      }
      final expected = {
        for (final entry in a.inbox.items) entry.item.id: entry.item.toJson(),
      };
      for (final device in [a, b, c]) {
        expect({
          for (final entry in device.inbox.items)
            entry.item.id: entry.item.toJson(),
        }, expected);
        expect(
          device.inbox.items.map((entry) => entry.item.id).toSet().length,
          device.inbox.items.length,
        );
        expect(device.inbox.store.find(removed.item.id), isNull);
        expect(device.inbox.favoriteEntries.single.item.text,device.inbox.store.find(note.item.id)!.item.text);
        expect(
          await device.inbox.store.blob(attachment.item.digest).readAsBytes(),
          bytes,
        );
        expect(device.inbox.syncProblems, hasLength(1));
        expect(
          device.inbox.syncProblems.single.versions
              .map((version) => version.text)
              .toSet(),
          {'edit B', 'edit C'},
        );
        expect(device.inbox.transferTasks, isEmpty);
      }
    },
  );
}
