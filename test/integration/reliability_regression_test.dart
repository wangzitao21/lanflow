import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_api.dart';

import '../support/test_device.dart';

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Audit condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  final devices = <TestDevice>[];
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('lanflow-audit-'),
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
  Future<TestDevice> create(String name, {bool automatic = false}) async {
    final d = await TestDevice.create(
      '${root.path}/$name',
      name,
      automaticSync: automatic,
    );
    devices.add(d);
    return d;
  }

  Future<void> bind(TestDevice a, TestDevice b) async {
    b.lan.onPrompt = (_) async => true;
    final peer = await a.lan.addAddress('127.0.0.1:${b.lan.self.port}');
    await a.lan.connect(peer);
  }

  test('transient blob failures retry automatically after backoff', () async {
    final a = await create('automatic-source', automatic: true);
    final b = await create('passive-target');
    await bind(a, b);
    await until(
      () =>
          a.inbox.statuses.values.any((s) => s.lastSuccess != null) &&
          !a.inbox.syncing,
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final original = b.lan.onInboxRequest!;
    var uploads = 0;
    b.lan.onInboxRequest = (request) async {
      if (request.method == 'PUT' &&
          request.uri.path.startsWith('/v2/blobs/')) {
        uploads++;
        if (uploads == 1) {
          await request.drain<void>();
          await inboxReply(request, 503, {'error': 'Temporary audit failure'});
          return;
        }
      }
      await original(request);
    };
    final file = File('${root.path}/retry.bin');
    await file.writeAsString('temporary failure then healthy');
    final entry = await a.inbox.addFile(file.path);
    await until(
      () =>
          a.inbox.transferTasks.any((t) => t.state == 'failed') &&
          !a.inbox.syncing,
    );
    await Future<void>.delayed(const Duration(seconds: 7));
    expect(uploads, greaterThanOrEqualTo(2));
    expect(b.inbox.store.find(entry.item.id), isNotNull);
    expect(a.inbox.transferTasks, isEmpty);
  });

  test('recently deleted retains every record above 500', () async {
    final d = await create('trash-limit');
    String? oldest;
    for (var i = 0; i < 501; i++) {
      final entry = (await d.inbox.addText('deleted audit item $i'))!;
      oldest ??= entry.item.id;
      await d.inbox.deleteItem(entry.item);
    }
    final stats = await d.inbox.store.storageStats();
    final trash = await d.inbox.store.recentlyDeleted();
    expect(stats['deleted'], 501);
    expect(trash.length, 501);
    expect(trash.any((item) => item.item.id == oldest), isTrue);
  });

  test(
    'export reads original bytes after an external editor changes the preview',
    () async {
      final d = await create('cached-file');
      final file = File('${root.path}/original.txt');
      await file.writeAsString('ORIGINAL');
      final entry = await d.inbox.addFile(file.path);
      final preview = await d.inbox.store.fileForOpening(entry.item);
      await preview.writeAsString('MODIFIED');
      final exported = await d.inbox.store.fileForExport(entry.item);
      expect(
        await d.inbox.store.blob(entry.item.digest).readAsString(),
        'ORIGINAL',
      );
      expect(await exported.readAsString(), 'ORIGINAL');
    },
  );

  test(
    'ordinary offline endpoints wait without a user-action warning',
    () async {
      final a = await create('offline-a');
      final b = await create('offline-b');
      await bind(a, b);
      await b.close();
      await a.inbox.addText('offline message');
      await a.inbox.syncNow();
      final status = a.inbox.statuses.values.single;
      expect(status.online, isFalse);
      expect(status.needsAttention, isFalse);
    },
  );

  test(
    'a removed target waiting behind the concurrency limit never starts syncing',
    () async {
      final source = await create('queued-source');
      final targets = <TestDevice>[];
      for (var i = 0; i < 5; i++) {
        final target = await create('queued-target-$i');
        targets.add(target);
        await bind(source, target);
      }
      final entered = Completer<void>();
      final release = Completer<void>();
      final original = targets.first.lan.onInboxRequest!;
      targets.first.lan.onInboxRequest = (request) async {
        if (!entered.isCompleted && request.uri.path == '/v3/changes') {
          entered.complete();
          await release.future;
        }
        await original(request);
      };
      var laterRequests = 0;
      final lastHandler = targets.last.lan.onInboxRequest!;
      targets.last.lan.onInboxRequest = (request) async {
        laterRequests++;
        await lastHandler(request);
      };
      final entry = (await source.inbox.addText(
        'queued target must not receive this',
      ))!;
      final running = source.inbox.syncNow();
      await entered.future.timeout(const Duration(seconds: 10));
      await source.inbox.removeDevice(targets.last.lan.identity.id);
      release.complete();
      await running;
      expect(laterRequests, 0);
      expect(targets.last.inbox.store.find(entry.item.id), isNull);
    },
  );

  test(
    'removing a device cancels subsequent requests in an active batch',
    () async {
      final a = await create('unbind-a');
      final b = await create('unbind-b');
      await bind(a, b);
      final first = (await a.inbox.addText('first pending note'))!;
      final second = (await a.inbox.addText('second pending note'))!;
      final entered = Completer<void>();
      final release = Completer<void>();
      final handled = Completer<void>();
      final original = b.lan.onInboxRequest!;
      var postsAfterRemoval = 0;
      var removed = false;
      b.lan.onInboxRequest = (request) async {
        if (request.method == 'POST' && request.uri.path == '/v3/changes') {
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
          if (removed) postsAfterRemoval++;
        }
        try {
          await original(request);
        } finally {
          if (entered.isCompleted && !handled.isCompleted) handled.complete();
        }
      };
      final running = a.inbox.syncNow();
      await entered.future.timeout(const Duration(seconds: 10));
      await a.inbox.removeDevice(b.lan.identity.id);
      removed = true;
      release.complete();
      await running;
      // Cancellation now returns before this already-entered server handler.
      // Observe its completion before checking that no later batch was sent.
      await handled.future.timeout(const Duration(seconds: 10));
      expect(a.lan.sessions.containsKey(b.lan.identity.id), isFalse);
      expect(b.inbox.store.find(first.item.id), isNull);
      expect(b.inbox.store.find(second.item.id), isNull);
      expect(postsAfterRemoval, 1);
    },
  );
}
