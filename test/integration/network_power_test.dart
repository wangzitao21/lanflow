import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/network/network_state.dart';

import '../support/test_device.dart';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Pending message did not arrive');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test(
    'unreachable LAN work waits locally and resumes immediately without slowing background delivery',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-power-network-',
      );
      final sender = await TestDevice.create(
        '${root.path}/sender',
        'sender',
        automaticSync: true,
      );
      final receiver = await TestDevice.create(
        '${root.path}/receiver',
        'receiver',
        automaticSync: true,
      );
      try {
        receiver.lan.onPrompt = (_) async => true;
        final peer = await sender.lan.addAddress(
          '127.0.0.1:${receiver.lan.self.port}',
        );
        await sender.lan.connect(peer);
        await sender.inbox.syncNow();
        await _until(() => !sender.inbox.syncing && !receiver.inbox.syncing);
        await Future<void>.delayed(const Duration(milliseconds: 250));
        sender.inbox.setForeground(false);
        receiver.inbox.setForeground(false);
        peer.address = '192.168.50.2';
        sender.inbox.setNetworkState(
          const NetworkState(
            fingerprint: 'cellular',
            localNetworkAvailable: false,
          ),
        );
        final waiting = (await sender.inbox.addText(
          'Keep this until a usable LAN returns',
        ))!;
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(receiver.inbox.store.find(waiting.item.id), isNull);
        expect(sender.inbox.transferring, isFalse);
        expect(sender.inbox.statuses.values.single.failures, 0);
        peer.address = '127.0.0.1';
        final resume = Stopwatch()..start();
        sender.inbox.setNetworkState(
          const NetworkState(fingerprint: 'wifi', localNetworkAvailable: true),
        );
        await _until(() => receiver.inbox.store.find(waiting.item.id) != null);
        expect(
          resume.elapsed,
          lessThan(const Duration(seconds: 2)),
          reason:
              'Transport must not wait for the three-second background display sampler',
        );
        await _until(() => !sender.inbox.syncing && !receiver.inbox.syncing);
        final send = Stopwatch()..start();
        final oldFailure = sender.inbox.statuses.values.single;
        oldFailure.failures = 6;
        oldFailure.retryAfter = DateTime.now().add(const Duration(minutes: 15));
        final next = (await sender.inbox.addText(
          'Deliver immediately in the background',
        ))!;
        await _until(() => receiver.inbox.store.find(next.item.id) != null);
        expect(send.elapsed, lessThan(const Duration(seconds: 2)));
      } finally {
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
}
