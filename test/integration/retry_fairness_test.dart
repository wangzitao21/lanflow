import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_api.dart';

import '../support/test_device.dart';

Future<void> waitUntil(bool Function() condition, {DateTime? deadline}) async {
  final limit = deadline ?? DateTime.now().add(const Duration(seconds: 12));
  while (!condition()) {
    if (!DateTime.now().isBefore(limit)) {
      fail('The expected transfer state did not arrive before the deadline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  test(
    'automatic file backoff does not delay new text or healthy attachments',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-retry-fairness-',
      );
      final devices = <TestDevice>[];
      try {
        final sender = await TestDevice.create(
          '${root.path}/sender',
          'Sender',
          automaticSync: true,
        );
        devices.add(sender);
        final receiver = await TestDevice.create(
          '${root.path}/receiver',
          'Receiver',
        );
        devices.add(receiver);
        receiver.lan.onPrompt = (_) async => true;
        final peer = await sender.lan.addAddress(
          '127.0.0.1:${receiver.lan.self.port}',
        );
        await sender.lan.connect(peer);
        await waitUntil(
          () =>
              sender.inbox.statuses.values.any(
                (status) => status.lastSuccess != null,
              ) &&
              !sender.inbox.syncing,
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));

        final original = receiver.lan.onInboxRequest!;
        String? failingDigest;
        var failures = 0;
        receiver.lan.onInboxRequest = (request) async {
          if (request.method == 'PUT' &&
              request.uri.path.startsWith('/v2/blobs/') &&
              (failingDigest == null ||
                  request.uri.path.endsWith(failingDigest!))) {
            failingDigest ??= request.uri.path.split('/').last;
            failures++;
            await request.drain<void>();
            await inboxReply(request, 503, {
              'error': 'Temporary file-specific failure',
            });
            return;
          }
          await original(request);
        };
        final brokenSource = File('${root.path}/waiting.bin');
        await brokenSource.writeAsString('temporarily unavailable attachment');
        final waiting = await sender.inbox.addFile(brokenSource.path);
        await waitUntil(
          () =>
              sender.inbox.transferTasks.any(
                (task) =>
                    task.item.id == waiting.item.id && task.state == 'failed',
              ) &&
              !sender.inbox.syncing,
        );
        final status =
            sender.inbox.statuses['device:${receiver.lan.identity.id}']!;
        final retryAt = status.retryAfter!;
        expect(
          status.failures,
          0,
          reason: 'The endpoint remains healthy when only one file fails',
        );
        expect(retryAt.isAfter(DateTime.now()), isTrue);
        expect(failures, 1);

        final text = (await sender.inbox.addText(
          'Deliver this during the file backoff',
        ))!;
        final healthySource = File('${root.path}/healthy.bin');
        await healthySource.writeAsBytes([7, 4, 2, 1]);
        final healthy = await sender.inbox.addFile(healthySource.path);
        // No force sync or retry action is allowed here: ordinary automatic
        // scheduling must deliver both before the failed file is eligible again.
        await waitUntil(
          () =>
              receiver.inbox.store.find(text.item.id) != null &&
              receiver.inbox.store.find(healthy.item.id) != null,
          deadline: retryAt,
        );
        expect(DateTime.now().isBefore(retryAt), isTrue);
        expect(
          failures,
          1,
          reason: 'The failed file keeps its own durable deadline',
        );
        expect(
          await receiver.inbox.store.blob(healthy.item.digest).readAsBytes(),
          [7, 4, 2, 1],
        );
        // Receiver publication precedes its HTTP acknowledgement and the
        // sender's completion transaction. Wait for that receipt before
        // checking the sender's active list and durable completed history.
        await waitUntil(
          () =>
              healthy.copies.contains('device:${receiver.lan.identity.id}') &&
              !sender.inbox.syncing,
        );
        await sender.inbox.refreshTransfers();
        expect(sender.inbox.transferTasks.single.item.id, waiting.item.id);
        expect(sender.inbox.transferTasks.single.state, 'failed');
        final history = await sender.inbox.store.transferHistory();
        expect(
          (history['items'] as List).any(
            (item) => item['item']['id'] == healthy.item.id,
          ),
          isTrue,
        );
      } finally {
        for (final device in devices.reversed) {
          await device.close();
          device.inbox.dispose();
          device.lan.dispose();
        }
        await root.delete(recursive: true);
      }
    },
  );
}
