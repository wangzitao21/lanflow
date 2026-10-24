import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_api.dart';
import 'package:lanflow/core/inbox/sync_watch.dart';

import '../support/test_device.dart';

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Notification did not arrive');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  for (final supportsIdleWait in [true, false]) {
    test(
      'notification wait negotiates idle support: $supportsIdleWait',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'lanflow-idle-watch-',
        );
        final sender = await TestDevice.create('${root.path}/sender', 'sender');
        final receiver = await TestDevice.create(
          '${root.path}/receiver',
          'receiver',
        );
        final release = Completer<void>();
        final changed = Completer<void>();
        final requests = <Uri>[];
        SyncWatch? watch;
        Future<void>? running;
        var changes = 0;
        try {
          receiver.lan.onPrompt = (_) async => true;
          final peer = await sender.lan.addAddress(
            '127.0.0.1:${receiver.lan.self.port}',
          );
          await sender.lan.connect(peer);
          receiver.lan.onInboxRequest = (request) async {
            requests.add(request.uri);
            final index = requests.length;
            if (index == 2) await changed.future;
            if (index >= 3) await release.future;
            await inboxReply(request, 200, {
              'cursor': index == 1 ? 42 : 43,
              'changed': true,
              if (supportsIdleWait) 'waitForChange': true,
            });
          };
          watch = SyncWatch(
            endpoint: sender.inbox.endpoints.single,
            isForeground: () => false,
            onChange: () => changes++,
            onConnection: (_, _) {},
            onUnsupported: () => fail('Compatible notification endpoint'),
          );
          running = watch.run();
          await _until(() => requests.length == 2);
          expect(changes, 1);
          expect(requests.first.queryParameters['after'], '-1');
          expect(requests.last.queryParameters['after'], '42');
          expect(
            requests.last.queryParameters['wait'],
            supportsIdleWait ? 'change' : '120',
          );
          await Future<void>.delayed(const Duration(milliseconds: 200));
          expect(requests.length, 2);
          changed.complete();
          await _until(() => changes == 2 && requests.length == 3);
          watch.close();
          await running.timeout(const Duration(seconds: 3));
        } finally {
          watch?.close();
          if (!changed.isCompleted) changed.complete();
          if (!release.isCompleted) release.complete();
          await running;
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
}
