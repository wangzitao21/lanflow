import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:lanflow/platform/native_core.dart';
import '../support/test_device.dart';

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Probe timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test('100 text records use two acknowledged batches', () async {
    final root = await Directory.systemTemp.createTemp('lanflow-audit-text-');
    final devices = <TestDevice>[];
    try {
      final a = await TestDevice.create('${root.path}/a', 'sender');
      final b = await TestDevice.create('${root.path}/b', 'receiver');
      devices.addAll([a, b]);
      b.lan.onPrompt = (_) async => true;
      await a.lan.connect(
        await a.lan.addAddress('127.0.0.1:${b.lan.self.port}'),
      );
      await a.inbox.syncNow();
      for (var i = 0; i < 100; i++) {
        await a.inbox.addText('audit metadata record $i');
      }
      var posts = 0;
      var active = 0;
      var peak = 0;
      final original = b.lan.onInboxRequest!;
      b.lan.onInboxRequest = (request) async {
        final metadata =
            request.method == 'POST' &&
            request.uri.path.startsWith('/v3/changes');
        if (metadata) {
          posts++;
          active++;
          if (active > peak) peak = active;
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        try {
          await original(request);
        } finally {
          if (metadata) active--;
        }
      };
      final watch = Stopwatch()..start();
      await a.inbox.syncNow();
      debugPrint(
        'AUDIT_TEXT records=100 posts=$posts maxConcurrentPosts=$peak injectedDelayPerPostMs=20 elapsedMs=${watch.elapsedMilliseconds}',
      );
      expect(posts, 2);
      expect(peak, 1);
      expect(b.inbox.items.length, 100);
    } finally {
      for (final device in devices.reversed) {
        await device.close();
        device.inbox.dispose();
        device.lan.dispose();
      }
      await root.delete(recursive: true);
    }
  });

  test(
    'a blocked endpoint leaves healthy endpoints free to deliver new work',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-audit-blocking-',
      );
      final devices = <TestDevice>[];
      final entered = Completer<void>();
      final release = Completer<void>();
      try {
        final a = await TestDevice.create(
          '${root.path}/a',
          'sender',
          automaticSync: true,
        );
        final b = await TestDevice.create('${root.path}/b', 'healthy');
        final c = await TestDevice.create('${root.path}/c', 'slow');
        devices.addAll([a, b, c]);
        for (final target in [b, c]) {
          target.lan.onPrompt = (_) async => true;
          await a.lan.connect(
            await a.lan.addAddress('127.0.0.1:${target.lan.self.port}'),
          );
        }
        await until(
          () =>
              a.inbox.statuses.length >= 2 &&
              a.inbox.statuses.values.every((s) => s.lastSuccess != null) &&
              !a.inbox.syncing,
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final original = c.lan.onInboxRequest!;
        c.lan.onInboxRequest = (request) async {
          if (request.method == 'GET' &&
              request.uri.path == '/v3/changes' &&
              !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
          await original(request);
        };
        a.inbox.requestSync(
          endpoint: 'device:${c.lan.identity.id}',
          immediate: true,
        );
        await entered.future.timeout(const Duration(seconds: 5));
        final watch = Stopwatch()..start();
        final message = (await a.inbox.addText(
          'new message while another endpoint is blocked',
        ))!;
        await Future<void>.delayed(const Duration(seconds: 2));
        final blocked = b.inbox.store.find(message.item.id) == null;
        final healthyBusy =
            a.inbox.statuses['device:${b.lan.identity.id}']!.busy;
        debugPrint(
          'AUDIT_HEAD_OF_LINE blockedAfterMs=${watch.elapsedMilliseconds} healthyBusy=$healthyBusy deliveryBlocked=$blocked',
        );
        expect(blocked, isFalse);
        expect(healthyBusy, isFalse);
        release.complete();
        await until(() => b.inbox.store.find(message.item.id) != null);
        debugPrint(
          'AUDIT_HEAD_OF_LINE deliveredAfterMs=${watch.elapsedMilliseconds}',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        for (final device in devices.reversed) {
          await device.close();
          device.inbox.dispose();
          device.lan.dispose();
        }
        await root.delete(recursive: true);
      }
    },
  );

  test('continuous file chunks reuse metadata and the remote offset', () async {
    final root = await Directory.systemTemp.createTemp('lanflow-audit-chunks-');
    final devices = <TestDevice>[];
    try {
      final a = await TestDevice.create('${root.path}/a', 'sender');
      final b = await TestDevice.create('${root.path}/b', 'receiver');
      devices.addAll([a, b]);
      b.lan.onPrompt = (_) async => true;
      await a.lan.connect(
        await a.lan.addAddress('127.0.0.1:${b.lan.self.port}'),
      );
      await a.inbox.syncNow();
      final file = File('${root.path}/payload.bin');
      await file.writeAsBytes(List.filled(16 * 1024 * 1024, 29));
      final entry = await a.inbox.addFile(file.path);
      final counts = <String, int>{};
      final original = b.lan.onInboxRequest!;
      b.lan.onInboxRequest = (request) async {
        final route = request.uri.path.startsWith('/v2/blobs/')
            ? '/v2/blobs'
            : request.uri.path;
        final key = '${request.method} $route';
        counts[key] = (counts[key] ?? 0) + 1;
        await original(request);
      };
      var rounds = 0;
      final watch = Stopwatch()..start();
      while (b.inbox.store.find(entry.item.id) == null && rounds < 10) {
        rounds++;
        final endpoint = a.inbox.endpoints.single;
        final state =
            await NativeCore.run({
                  'op': 'sync',
                  'root': a.inbox.store.directory.path,
                  'knownRevision': a.inbox.store.revision,
                  'continuousFiles': true,
                  'endpoint': {
                    ...endpoint.toJson(),
                    'key': endpoint.key,
                    'deviceId': a.lan.identity.id,
                  },
                })
                as Map;
        a.inbox.store.applySnapshot(Map<String, dynamic>.from(state));
      }
      debugPrint(
        'AUDIT_CHUNKS rounds=$rounds elapsedMs=${watch.elapsedMilliseconds} requests=$counts',
      );
      expect(b.inbox.store.find(entry.item.id), isNotNull);
      expect(rounds, 1);
      expect(counts['GET /v3/changes'], 1);
      expect(counts['GET /v3/deletions'], 1);
      expect(counts['HEAD /v2/blobs'], 1);
      expect(counts['PUT /v2/blobs'], 4);
    } finally {
      for (final device in devices.reversed) {
        await device.close();
        device.inbox.dispose();
        device.lan.dispose();
      }
      await root.delete(recursive: true);
    }
  });
}
