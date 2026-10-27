import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_api.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';

import '../support/test_device.dart';

Future<void> until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 12));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Watch recovery timed out');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  for (final partial in [false, true]) {
    test(
      partial
          ? 'committed NAS pages reach another device despite a later page failure'
          : 'a live NAS watch does not suppress retry after a failed content request',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'lanflow-watch-recovery-',
        );
        final source = await TestDevice.create(
          '${root.path}/source',
          'NAS source',
        );
        final receiver = await TestDevice.create(
          '${root.path}/receiver',
          'Reader',
          automaticSync: true,
        );
        final linked = await TestDevice.create('${root.path}/linked', 'Linked');
        final server = await HttpServer.bindSecure(
          InternetAddress.loopbackIPv4,
          0,
          source.lan.identity.context,
        );
        var failContent = false;
        var failures = 0;
        var stopping = false;
        final watches = <Completer<void>>{};
        server.listen((request) async {
          try {
            if (request.uri.path == '/v3/watch') {
              final after = int.parse(request.uri.queryParameters['after']!);
              final changed = Completer<void>();
              watches.add(changed);
              try {
                if (after == source.inbox.store.changeCursor) {
                  await Future.any([
                    source.inbox.store.waitForChanges(after),
                    changed.future,
                  ]);
                }
                if (!stopping) {
                  await inboxReply(request, 200, {
                    'cursor': source.inbox.store.changeCursor,
                    'waitForChange': true,
                  });
                }
              } finally {
                watches.remove(changed);
              }
            } else if (request.uri.path == '/v3/deletions') {
              await inboxReply(
                request,
                200,
                await source.inbox.store.deletions(
                  int.parse(request.uri.queryParameters['after'] ?? '0'),
                ),
              );
            } else if (request.method == 'GET') {
              final after = int.parse(
                request.uri.queryParameters['after'] ?? '0',
              );
              if (failContent && (!partial || after > 0)) {
                failures++;
                if (!partial) failContent = false;
                await inboxReply(request, partial ? 503 : 504, {
                  'error': 'injected content failure',
                });
              } else {
                await inboxReply(
                  request,
                  200,
                  await source.inbox.store.changes(
                    after,
                    capabilities: request.uri.queryParameters['capabilities'],
                  ),
                );
              }
            } else {
              final event = await readInboxJson(request);
              if (request.uri.path == '/v3/changes/batch') {
                final events = (event['events'] as List)
                    .map((e) => Map<String, dynamic>.from(e as Map))
                    .toList();
                await source.inbox.store.applyChanges(events);
                await inboxReply(request, 200, {
                  'ok': true,
                  'ids': events.map((e) => e['id']).toList(),
                });
              } else {
                await source.inbox.store.applyChange(event);
                await inboxReply(request, 200, {'ok': true});
              }
            }
          } on Object {
            // Cancellation may close the response while the test shuts down.
          }
        });
        final hub = SyncEndpoint(
          id: source.lan.identity.id,
          name: 'Test NAS',
          url: Uri.parse('https://127.0.0.1:${server.port}'),
          fingerprint: source.lan.identity.fingerprint,
          token: 'a' * 43,
          isHub: true,
        );
        try {
          linked.lan.onPrompt = (_) async => true;
          final peer = await receiver.lan.addAddress(
            '127.0.0.1:${linked.lan.self.port}',
          );
          await receiver.lan.connect(peer);
          await until(
            () =>
                receiver.inbox.statuses.values.any(
                  (s) => s.lastSuccess != null,
                ) &&
                !receiver.inbox.syncing,
          );
          InboxEntry? first;
          InboxEntry? last;
          if (partial) {
            for (var i = 0; i < 55; i++) {
              final entry = (await source.inbox.addText('page note $i'))!;
              first ??= entry;
              last = entry;
            }
            failContent = true;
          }
          receiver.inbox.store.hubs.add(hub);
          await receiver.inbox.syncNow();
          if (!partial) {
            await until(
              () =>
                  receiver.inbox.statuses[hub.key]?.lastSuccess != null &&
                  !receiver.inbox.syncing,
            );
            await Future<void>.delayed(const Duration(milliseconds: 150));
            failContent = true;
            first = (await source.inbox.addText('retry this notification'))!;
            last = first;
          }
          await until(() => failures > 0);
          if (partial) {
            await until(() => linked.inbox.store.find(first!.item.id) != null);
            expect(receiver.inbox.store.find(last!.item.id), isNull);
            failContent = false;
          }
          await until(() => receiver.inbox.store.find(last!.item.id) != null);
          await until(() => linked.inbox.store.find(last!.item.id) != null);
          expect(receiver.inbox.syncProblems, isEmpty);
        } finally {
          stopping = true;
          for (final watch in watches.toList()) {
            if (!watch.isCompleted) watch.complete();
          }
          await server.close(force: true);
          for (final device in [receiver, linked, source]) {
            await device.close();
            device.inbox.dispose();
            device.lan.dispose();
          }
          await root.delete(recursive: true);
        }
      },
    );
  }
}
