import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../support/test_device.dart';

Future<void> waitUntil(bool Function() condition) async {
  final limit = DateTime.now().add(const Duration(seconds: 12));
  while (!condition()) {
    if (DateTime.now().isAfter(limit)) {
      fail('Expected a content change notification');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

void main() {
  test('bound peers receive changes without periodic history checks', () async {
    final root = await Directory.systemTemp.createTemp('lanflow-notify-');
    final first = await TestDevice.create(
      '${root.path}/first',
      '电脑',
      automaticSync: true,
    );
    final second = await TestDevice.create(
      '${root.path}/second',
      '手机',
      automaticSync: true,
    );
    try {
      var requests = 0, watches = 0;
      for (final device in [first, second]) {
        final original = device.lan.onInboxRequest!;
        device.lan.onInboxRequest = (request) {
          requests++;
          if (request.uri.path == '/v3/watch') watches++;
          return original(request);
        };
      }
      second.lan.onPrompt = (_) async => true;
      final peer = await first.lan.addAddress(
        '127.0.0.1:${second.lan.self.port}',
      );
      await first.lan.connect(peer);
      final note = (await first.inbox.addText('拿到资料后通过变化通知同步'))!;
      await waitUntil(
        () =>
            second.inbox.store.find(note.item.id) != null &&
            first.inbox.copyStatus(note) == '已同步 1/1',
      );
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(
        watches,
        0,
        reason: 'Direct peers push changes without idle polls',
      );
      expect(first.lan.inboxRevision, first.inbox.store.changeCursor);
      first.inbox.setForeground(false);
      second.inbox.setForeground(false);
      final settled = first.inbox.statuses.values.single.lastSuccess;
      final idleRequests = requests;
      await first.inbox.setAppearance('dark');
      first.inbox.setDraft('An unsent draft stays local');
      await first.inbox.flushLocalWrites();
      // Cross the old foreground notification-renewal interval. Local-only
      // changes must not send requests or start another content sync either.
      await Future<void>.delayed(const Duration(seconds: 27));
      expect(requests, idleRequests);
      expect(first.inbox.statuses.values.single.lastSuccess, settled);
      expect(first.inbox.syncing, isFalse);
      final reply = (await second.inbox.addText('返回的内容也自动抵达'))!;
      await waitUntil(() => first.inbox.store.find(reply.item.id) != null);
      await second.inbox.setFavorites([reply.item.id], true);
      await waitUntil(() => first.inbox.isFavorite(reply.item.id));
      await second.inbox.deleteItem(reply.item);
      await waitUntil(() => first.inbox.store.find(reply.item.id) == null);
      await first.inbox.removeDevice(second.lan.identity.id);
      final local = (await first.inbox.addText('移除后只保留在本机'))!;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(second.inbox.store.find(local.item.id), isNull);
    } finally {
      await first.close();
      await second.close();
      first.inbox.dispose();
      first.lan.dispose();
      second.inbox.dispose();
      second.lan.dispose();
      await root.delete(recursive: true);
    }
  });

  test(
    'a restarted device catches up messages sent while it was off',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-event-catchup-',
      );
      final first = await TestDevice.create(
        '${root.path}/first',
        'first',
        automaticSync: true,
      );
      var second = await TestDevice.create(
        '${root.path}/second',
        'second',
        automaticSync: true,
      );
      try {
        second.lan.onPrompt = (_) async => true;
        final peer = await first.lan.addAddress(
          '127.0.0.1:${second.lan.self.port}',
        );
        await first.lan.connect(peer);
        final before = (await first.inbox.addText('Before disconnect'))!;
        await waitUntil(
          () =>
              second.inbox.store.find(before.item.id) != null &&
              first.inbox.copyStatus(before) == '已同步 1/1' &&
              !first.inbox.syncing,
        );
        await second.close();
        second.inbox.dispose();
        second.lan.dispose();
        first.inbox.requestSync();
        await waitUntil(
          () =>
              first.inbox.statuses.values.any((s) => s.failures > 0) &&
              !first.inbox.syncing,
        );
        expect(
          first.inbox.statuses.values.single.retryAfter,
          isNull,
          reason:
              'An offline check with nothing pending must not keep retrying',
        );
        final missed = (await first.inbox.addText(
          'While the other device is off',
        ))!;
        await waitUntil(
          () => first.inbox.statuses.values.any(
            (s) => s.failures > 1 && s.retryAfter != null,
          ),
        );
        second = await TestDevice.create(
          '${root.path}/second',
          'second',
          automaticSync: true,
        );
        await waitUntil(() => second.inbox.store.find(missed.item.id) != null);
        expect(second.inbox.store.find(before.item.id), isNotNull);
      } finally {
        await first.close();
        await second.close();
        first.inbox.dispose();
        first.lan.dispose();
        second.inbox.dispose();
        second.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
