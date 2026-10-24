import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_api.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/network_state.dart';

import '../support/test_device.dart';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Network transition did not settle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _RequestGate {
  final entered = Completer<void>();
  final release = Completer<void>();
  void open() {
    if (!release.isCompleted) release.complete();
  }
}

void main() {
  test(
    'a route handoff bypasses old sockets and identical snapshots leave work running',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-network-transition-',
      );
      final sender = await TestDevice.create(
        '${root.path}/sender',
        'sender',
        automaticSync: true,
      );
      // Only the sender may initiate sync, so a reverse pull cannot mask a stalled send.
      final receiver = await TestDevice.create(
        '${root.path}/receiver',
        'receiver',
      );
      final gates = <_RequestGate>[];
      try {
        receiver.lan.onPrompt = (_) async => true;
        final peer = await sender.lan.addAddress(
          '127.0.0.1:${receiver.lan.self.port}',
        );
        await sender.lan.connect(peer);
        sender.inbox.setNetworkState(
          const NetworkState(
            fingerprint: 'wifi-a',
            localNetworkAvailable: true,
          ),
        );
        await sender.inbox.syncNow();
        await Future<void>.delayed(const Duration(milliseconds: 250));
        await _until(() => !sender.inbox.syncing);

        final original = receiver.lan.onInboxRequest!;
        var gate = _RequestGate();
        gates.add(gate);
        var reads = 0;
        receiver.lan.onInboxRequest = (request) async {
          if (request.method == 'GET' && request.uri.path == '/v3/changes') {
            reads++;
            final current = gate;
            if (!current.entered.isCompleted) {
              current.entered.complete();
              await current.release.future;
            }
          }
          await original(request);
        };
        sender.inbox.requestSync(immediate: true);
        await gate.entered.future.timeout(const Duration(seconds: 3));
        final pending = (await sender.inbox.addText(
          'Send promptly after the network handoff',
        ))!;
        final delivery = Stopwatch()..start();
        const nextNetwork = NetworkState(
          fingerprint: 'wifi-b',
          localNetworkAvailable: true,
        );
        sender.inbox.setNetworkState(nextNetwork);
        await _until(() => receiver.inbox.store.find(pending.item.id) != null);
        expect(delivery.elapsed, lessThan(const Duration(seconds: 2)));
        expect(
          gate.release.isCompleted,
          isFalse,
          reason: 'Delivery must not wait for the old connection',
        );
        expect(reads, greaterThanOrEqualTo(2));
        gate.open();
        await _until(() => !sender.inbox.syncing);
        await Future<void>.delayed(const Duration(milliseconds: 250));

        gate = _RequestGate();
        gates.add(gate);
        sender.inbox.requestSync(immediate: true);
        await gate.entered.future.timeout(const Duration(seconds: 3));
        final healthyReads = reads;
        sender.inbox.setNetworkState(nextNetwork);
        sender.inbox.setNetworkState(nextNetwork);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(
          reads,
          healthyReads,
          reason: 'Duplicate OS events must not restart a healthy request',
        );
        expect(sender.inbox.syncing, isTrue);
        gate.open();
        await _until(() => !sender.inbox.syncing);
      } finally {
        for (final gate in gates) {
          gate.open();
        }
        await sender.close();
        await receiver.close();
        sender.inbox.dispose();
        sender.lan.dispose();
        receiver.inbox.dispose();
        receiver.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'network recovery opens one NAS watch and duplicate snapshots preserve it',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-network-watch-',
      );
      final client = await TestDevice.create(
        '${root.path}/client',
        'client',
        automaticSync: true,
      );
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        client.lan.identity.context,
      );
      final release = Completer<void>();
      var handshakes = 0;
      var waits = 0;
      server.listen((request) async {
        try {
          if (request.uri.path == '/v3/watch') {
            if (request.uri.queryParameters['after'] == '-1') {
              handshakes++;
            } else {
              waits++;
              await release.future;
            }
            await inboxReply(request, 200, {
              'cursor': 0,
              'changed': false,
              'waitForChange': true,
            });
          } else if (request.method == 'GET') {
            await inboxReply(request, 200, {
              'protocol': 3,
              'items': [],
              'cursor': 0,
              'more': false,
              'capabilities': ['favorites', 'favoriteSnapshots'],
            });
          } else {
            await request.drain<void>();
            await inboxReply(request, 200, {'ok': true});
          }
        } on Object {
          // Closing a watch during the simulated handoff closes its HTTP response.
        }
      });
      try {
        client.inbox.store.hubs.add(
          SyncEndpoint(
            id: 'a' * 32,
            name: 'NAS',
            url: Uri.parse('https://127.0.0.1:${server.port}'),
            fingerprint: client.lan.identity.fingerprint,
            token: 'a' * 43,
            isHub: true,
          ),
        );
        client.inbox.setNetworkState(
          const NetworkState(available: false, fingerprint: 'offline'),
        );
        const connected = NetworkState(
          fingerprint: 'wifi',
          localNetworkAvailable: true,
        );
        client.inbox.setNetworkState(connected);
        await _until(() => waits == 1);
        expect(handshakes, 1);
        for (var count = 0; count < 3; count++) {
          client.inbox.setNetworkState(connected);
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(handshakes, 1);
        expect(waits, 1);
        client.inbox.setNetworkState(
          const NetworkState(available: false, fingerprint: 'offline-again'),
        );
        client.inbox.setNetworkState(connected);
        await _until(() => waits == 2);
        expect(handshakes, 2);
      } finally {
        await client.close();
        release.complete();
        await server.close(force: true);
        client.inbox.dispose();
        client.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
