import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/network/models.dart';

import '../support/test_device.dart';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Runtime condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _GatedLegacyStore extends InboxStore {
  _GatedLegacyStore(super.directory);
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> save() async {
    if (migrated.isNotEmpty && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.save();
  }
}

void main() {
  final devices = <TestDevice>[];
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanflow-runtime-regression-');
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

  Future<Peer> pair(TestDevice a, TestDevice b) async {
    b.lan.onPrompt = (_) async => true;
    final peer = await a.lan.addAddress('127.0.0.1:${b.lan.self.port}');
    await a.lan.connect(peer);
    return peer;
  }

  for (final delayFirstPrompt in [false, true]) {
    test(
      'simultaneous pairing remains valid with delayed prompt $delayFirstPrompt',
      () async {
        final a = await create('a');
        final b = await create('b');
        final both = Completer<void>();
        var prompts = 0;
        Future<bool> approve(bool delayed) async {
          if (++prompts == 2) both.complete();
          await both.future;
          if (delayed) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          return true;
        }

        a.lan.onPrompt = (_) => approve(delayFirstPrompt);
        b.lan.onPrompt = (_) => approve(!delayFirstPrompt);
        final peerB = await a.lan.addAddress('127.0.0.1:${b.lan.self.port}');
        final peerA = await b.lan.addAddress('127.0.0.1:${a.lan.self.port}');
        await Future.wait([a.lan.connect(peerB), b.lan.connect(peerA)]);
        final aSession = a.lan.sessions[b.lan.identity.id]!;
        final bSession = b.lan.sessions[a.lan.identity.id]!;
        expect(aSession.sendToken, bSession.receiveToken);
        expect(bSession.sendToken, aSession.receiveToken);
        final entry = (await a.inbox.addText('paired concurrently'))!;
        await a.inbox.syncNow();
        expect(b.inbox.store.find(entry.item.id), isNotNull);
      },
    );
  }

  test(
    'idle notifications leave normal requests and transfers available',
    () async {
      final device = await create('receiver');
      final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
      final watches = <Future<void>>[];
      try {
        for (var i = 0; i < 16; i++) {
          final id = i.toRadixString(16).padLeft(32, '0');
          device.lan.peers[id] = Peer(
            id: id,
            name: 'peer$i',
            platform: 'windows',
            address: '127.0.0.1',
            port: 12345,
            fingerprint: '$id$id',
          );
          device.lan.sessions[id] = PeerSession(
            receiveToken: 'token$i',
            sendToken: 'send$i',
          );
          final request = await client.getUrl(
            Uri.parse(
              'https://127.0.0.1:${device.lan.self.port}/v3/watch?after=${device.inbox.store.changeCursor}',
            ),
          );
          request.headers.set('X-Lanflow-Device', id);
          request.headers.set('Authorization', 'Bearer token$i');
          watches.add(
            request
                .close()
                .then<void>((response) async {
                  await response.drain<void>();
                })
                .catchError((Object _) {}),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
        final request = await client.getUrl(
          Uri.parse('https://127.0.0.1:${device.lan.self.port}/v1/info'),
        );
        final response = await request.close();
        expect(response.statusCode, 200);
        await response.drain<void>();
        expect(device.inbox.transferring, isFalse);
      } finally {
        client.close(force: true);
        // Release server-side waits before waiting for the client requests.
        await device.close();
        await Future.wait(watches);
      }
    },
  );

  test(
    'live legacy imports notify the inbox and propagate to bound devices',
    () async {
      final source = await create('source');
      final receiver = await create('receiver', automatic: true);
      final other = await create('other');
      final peer = await pair(source, receiver);
      final old = receiver.lan.peers[source.lan.identity.id]!;
      receiver.lan.peers[old.id] = Peer(
        id: old.id,
        name: old.name,
        platform: old.platform,
        address: old.address,
        port: old.port,
        fingerprint: old.fingerprint,
      );
      await pair(receiver, other);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      var notified = false;
      receiver.inbox.addListener(() {
        if (receiver.inbox.items.any(
          (e) => e.item.text == 'legacy notification',
        )) {
          notified = true;
        }
      });
      await source.lan.sendText(peer, 'legacy notification');
      await _until(
        () =>
            other.inbox.items.any((e) => e.item.text == 'legacy notification'),
      );
      expect(notified, isTrue);
    },
  );

  test(
    'legacy messages arriving during an import are drained without another event',
    () async {
      final source = await create('source');
      final initial = await create('receiver');
      await initial.inbox.close();
      initial.inbox.dispose();
      final gated = _GatedLegacyStore(initial.lan.store.directory);
      final controller = InboxController(
        lan: initial.lan,
        store: gated,
        automaticSync: false,
      );
      final receiver = TestDevice(initial.lan, controller);
      devices[devices.indexOf(initial)] = receiver;
      await controller.start();
      final peer = await pair(source, receiver);
      try {
        await source.lan.sendText(peer, 'first legacy message');
        await gated.entered.future.timeout(const Duration(seconds: 10));
        await source.lan.sendText(peer, 'arrived during the first import');
        await Future<void>.delayed(const Duration(milliseconds: 60));
        gated.release.complete();
        await _until(
          () => receiver.inbox.items.any(
            (e) => e.item.text == 'arrived during the first import',
          ),
        );
        expect(receiver.inbox.items.length, 2);
      } finally {
        if (!gated.release.isCompleted) gated.release.complete();
      }
    },
  );

  test(
    'overlapping passive blob transfers retain activity until every request settles',
    () async {
      final source = await create('source');
      final receiver = await create('receiver');
      await pair(source, receiver);
      final get = Completer<void>();
      final put = Completer<void>();
      receiver.lan.onInboxRequest = (request) async {
        await request.drain<void>();
        await (request.method == 'GET' ? get.future : put.future);
        if (request.method == 'PUT') {
          throw const FormatException('interrupted upload');
        }
        await request.response.close();
      };
      final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
      Future<int> request(String method) async {
        final request = await client.openUrl(
          method,
          Uri.parse(
            'https://127.0.0.1:${receiver.lan.self.port}/v2/blobs/${'a' * 64}',
          ),
        );
        request.headers.set('X-Lanflow-Device', source.lan.identity.id);
        request.headers.set(
          'Authorization',
          'Bearer ${source.lan.sessions[receiver.lan.identity.id]!.sendToken}',
        );
        request.contentLength = 0;
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      final downloading = request('GET');
      final uploading = request('PUT');
      try {
        await _until(() => receiver.inbox.activeTransferCount == 2);
        expect(receiver.inbox.syncing, isFalse);
        expect(receiver.inbox.transferring, isTrue);
        get.complete();
        expect(await downloading, 200);
        await _until(() => receiver.inbox.activeTransferCount == 1);
        expect(receiver.inbox.transferring, isTrue);
        put.complete();
        expect(await uploading, 400);
        await _until(() => !receiver.inbox.transferring);
      } finally {
        if (!get.isCompleted) get.complete();
        if (!put.isCompleted) put.complete();
        client.close(force: true);
        await Future.wait([downloading, uploading]);
      }
    },
  );

  test('legacy file sending and receiving both report active work', () async {
    final source = await create('source');
    final receiver = await create('receiver');
    final peer = await pair(source, receiver);
    var sent = false, received = false;
    source.inbox.activity.addListener(() {
      sent |= source.inbox.transferring;
    });
    receiver.inbox.activity.addListener(() {
      received |= receiver.inbox.transferring;
    });
    final file = File('${root.path}/file.bin');
    await file.writeAsBytes(List.filled(32768, 42));
    await source.lan.sendFile(peer, file.path);
    expect(sent, isTrue);
    expect(received, isTrue);
    expect(source.inbox.transferring, isFalse);
    expect(receiver.inbox.transferring, isFalse);
  });
}
