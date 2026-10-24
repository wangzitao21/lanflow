import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/storage/local_store.dart';
import 'package:lanflow/core/storage/storage_layout.dart';
import 'package:lanflow/platform/native_core.dart';
import 'package:lanflow/runtime.dart';
import 'package:path/path.dart' as p;

import '../support/test_device.dart';

class _GatedStore extends InboxStore {
  _GatedStore(super.directory);
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> load({void Function(int loaded, int total)? onProgress}) async {
    entered.complete();
    await release.future;
    await super.load(onProgress: onProgress);
  }
}

Future<LanController> _lan(Directory root) async {
  final lan = LanController(
    store: LocalStore(root),
    receiveDirectory: StorageLayout.received(root),
    enableDiscovery: false,
    preferredPort: 0,
    bindAddress: InternetAddress.loopbackIPv4,
    initialName: '启动边界测试',
  );
  await lan.start();
  expect(lan.ready, isTrue, reason: lan.error);
  return lan;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'failed-close recovery applies removed bindings and pause before opening network services',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-recovery-network-',
      );
      final data = Directory(p.join(root.path, 'data'));
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var connections = 0;
      final subscription = server.listen((socket) {
        connections++;
        socket.destroy();
      });
      final previous = await RuntimeSession.open(
        data,
        enableDiscovery: false,
        preferredPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      await previous.start(acceptShares: false);
      final peerId = 'c' * 32;
      previous.lan.peers[peerId] = Peer(
        id: peerId,
        name: 'removed peer',
        platform: 'windows',
        address: '127.0.0.1',
        port: server.port,
        fingerprint: 'c' * 64,
        inboxVersion: 3,
      );
      previous.lan.sessions[peerId] = PeerSession(
        receiveToken: 'probe-receive',
        sendToken: 'probe-send',
      );
      await previous.lan.retrySave();
      final blocker = Directory(
        p.join(data.path, 'system', 'device', 'state.pending.json'),
      );
      await blocker.create();
      previous.lan.forgetPeer(peerId);
      previous.lan.setReceivingPaused(true);
      await expectLater(previous.close(), throwsA(isA<FileSystemException>()));
      // The recovery adapter must retain pending in-memory preferences even
      // when the persisted settings are still older than this retired session.
      final favoritePreferences = FavoritePreferences(
        layout: 'list',
        filter: 'video',
        sort: 'titleDesc',
        onlyPinned: true,
        pinned: {'pending-favorite-id': 100},
      );
      previous.inbox.store.favoritePreferences = favoritePreferences;
      connections = 0;
      RuntimeSession? recovered;
      try {
        recovered = await RuntimeSession.open(
          data,
          recoverFrom: previous,
          enableDiscovery: false,
          preferredPort: 0,
          bindAddress: InternetAddress.loopbackIPv4,
        );
        await recovered.network;
        // Check the LAN controller before InboxController.start can attach any
        // protocol handler: stale credentials must never become live here.
        expect(recovered.lan.ready, isTrue);
        expect(recovered.lan.receivingPaused, isTrue);
        expect(recovered.lan.sessions.containsKey(peerId), isFalse);
        expect(recovered.lan.onInboxRequest, isNull);
        await recovered.start(acceptShares: false);
        expect(recovered.inbox.favoritePreferences, favoritePreferences);
        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(connections, 0);
        expect(recovered.inbox.endpoints, isEmpty);
      } finally {
        if (await blocker.exists()) await blocker.delete();
        await recovered?.close();
        recovered?.dispose();
        previous.dispose();
        await subscription.cancel();
        await server.close();
        await root.delete(recursive: true);
      }
    },
  );

  for (final eager in [false, true]) {
    test(
      'closing during history startup drains accepted reads (eager=$eager)',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'lanflow-paged-start-close-',
        );
        final data = Directory(p.join(root.path, 'data'));
        var snapshot =
            await NativeCore.run({'op': 'open', 'root': data.path}) as Map;
        for (var index = 0; index < 1005; index++) {
          snapshot =
              await NativeCore.run({
                    'op': 'add',
                    'root': data.path,
                    'knownRevision': snapshot['revision'],
                    'item': {
                      'id': 'startup-item-${index.toString().padLeft(12, '0')}',
                      'originId': 'startup-device-0001',
                      'originName': '启动测试',
                      'createdAt': '2026-01-01T00:00:00Z',
                      'kind': 'text',
                      'text': '分页记录 $index',
                      'name': '',
                      'size': 0,
                      'sha256': '',
                    },
                  })
                  as Map;
        }
        await NativeCore.run({'op': 'close', 'root': data.path});
        final lan = await _lan(data);
        final store = InboxStore(data, eagerHistory: eager);
        final inbox = InboxController(
          lan: lan,
          store: store,
          automaticSync: false,
        );
        Future<void>? closing;
        inbox.addListener(() {
          if (inbox.loadingRecords >= (eager ? 1000 : 200) && closing == null) {
            closing = inbox.close();
          }
        });
        try {
          await inbox.start();
          expect(closing, isNotNull);
          await closing;
          expect(store.entries.length, eager ? 1005 : 200);
          expect(store.messageCount, 1005);
          expect(inbox.ready, isFalse);
          expect(lan.onInboxRequest, isNull);
          await lan.close();
          await NativeCore.run({
            'op': 'maintenance_cleanup',
            'root': data.path,
            'clearTrash': false,
          });
          await data.rename(p.join(root.path, 'closed-data'));
          await inbox.start();
          expect(await data.exists(), isFalse);
        } finally {
          await inbox.close();
          await closing;
          await lan.close();
          inbox.dispose();
          lan.dispose();
          await root.delete(recursive: true);
        }
      },
    );
  }

  test(
    'close waits for startup to settle and no old storage root reopens afterward',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-start-close-',
      );
      final data = Directory(p.join(root.path, 'data'));
      final lan = await _lan(data);
      final store = _GatedStore(data);
      final inbox = InboxController(
        lan: lan,
        store: store,
        automaticSync: false,
      );
      final starting = inbox.start();
      await store.entered.future;
      var closed = false;
      final closing = inbox.close().then((_) => closed = true);
      try {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(closed, isFalse);
        store.release.complete();
        await Future.wait([starting, closing]);
        expect(lan.onInboxRequest, isNull);
        await lan.close();
        // This operation refuses an open native registry entry, so it also
        // detects a late startup reopening the DB after close returned.
        await NativeCore.run({
          'op': 'maintenance_cleanup',
          'root': data.path,
          'clearTrash': false,
        });
        await data.rename(p.join(root.path, 'closed-data'));
        await inbox.start();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(await data.exists(), isFalse);
      } finally {
        if (!store.release.isCompleted) store.release.complete();
        await starting;
        await closing;
        await lan.close();
        inbox.dispose();
        lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'closing during an awaited platform startup call cannot restart service setup later',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-runtime-start-close-',
      );
      final data = Directory(p.join(root.path, 'data'));
      final entered = Completer<void>();
      final release = Completer<void>();
      final lateCalls = <String>[];
      var closed = false;
      final channel = const MethodChannel('lanflow/desktop');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (closed) lateCalls.add(call.method);
            if (call.method == 'setLanguage' && !entered.isCompleted) {
              entered.complete();
              await release.future;
            }
            return null;
          });
      final runtime = await RuntimeSession.open(
        data,
        enableDiscovery: false,
        preferredPort: 0,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      final starting = runtime.start(acceptShares: false);
      Future<void>? closing;
      try {
        await entered.future.timeout(const Duration(seconds: 10));
        closing = runtime.close().then((_) => closed = true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        release.complete();
        await Future.wait([starting, closing]);
        expect(
          lateCalls,
          isEmpty,
          reason: 'Platform setup must not resume after the session closes.',
        );
        expect(runtime.lan.onInboxRequest, isNull);
        await NativeCore.run({
          'op': 'maintenance_cleanup',
          'root': data.path,
          'clearTrash': false,
        });
        await data.rename(p.join(root.path, 'closed-data'));
        await runtime.start();
        expect(await data.exists(), isFalse);
      } finally {
        if (!release.isCompleted) release.complete();
        await starting;
        await closing;
        await runtime.close();
        runtime.dispose();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        await root.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'a setting changed while startup is pending preserves existing drafts and preferences',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-start-settings-',
      );
      final data = Directory(p.join(root.path, 'data'));
      final original = await TestDevice.create(data.path, '原设备');
      original.inbox.setDraft('启动之前保存的草稿');
      await original.inbox.setComposerFraction(.4);
      await original.inbox.setConversationPinned(
        original.inbox.conversationId,
        true,
      );
      await original.close();
      original.inbox.dispose();
      original.lan.dispose();
      final lan = await _lan(data);
      final store = _GatedStore(data);
      final inbox = InboxController(
        lan: lan,
        store: store,
        automaticSync: false,
      );
      final starting = inbox.start();
      await store.entered.future;
      final setting = inbox.setLanguage('en');
      try {
        // Give an unsafe early save time to commit before the original metadata
        // is read; a safe implementation waits for startup instead.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        store.release.complete();
        await Future.wait([starting, setting]);
        expect(store.draft, '启动之前保存的草稿');
        expect(store.composerFraction, .4);
        expect(store.preference(inbox.conversationId).pinnedAt, isNotNull);
        expect(inbox.language.value, 'en');
        await inbox.close();
        await lan.close();
        final reopened = await TestDevice.create(data.path, '原设备');
        try {
          expect(reopened.inbox.store.draft, '启动之前保存的草稿');
          expect(reopened.inbox.language.value, 'en');
        } finally {
          await reopened.close();
          reopened.inbox.dispose();
          reopened.lan.dispose();
        }
      } finally {
        if (!store.release.isCompleted) store.release.complete();
        await starting;
        await setting;
        await inbox.close();
        await lan.close();
        inbox.dispose();
        lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
