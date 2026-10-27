import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_api.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import '../support/test_device.dart';

void main() {
  late Directory root;
  final devices = <TestDevice>[];
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('lanflow-conflicts-'),
  );
  tearDown(() async {
    for (final device in devices.reversed) {
      await device.close();
      device.inbox.dispose();
      device.lan.dispose();
    }
    devices.clear();
    await root.delete(recursive: true);
  });
  Future<TestDevice> create(String name) async {
    final device = await TestDevice.create('${root.path}/$name', name);
    devices.add(device);
    return device;
  }

  Future<void> pair(TestDevice a, TestDevice b) async {
    b.lan.onPrompt = (_) async => true;
    await a.lan.connect(await a.lan.addAddress('127.0.0.1:${b.lan.self.port}'));
  }

  Future<void> syncAll() async {
    for (var pass = 0; pass < 2; pass++) {
      for (final device in devices) {
        await device.inbox.syncNow();
      }
    }
  }

  test(
    'attachment name and caption conflicts preserve the original bytes',
    () async {
      final a = await create('Alpha');
      final b = await create('Beta');
      await pair(a, b);
      final file = File('${root.path}/original.bin');
      await file.writeAsBytes([0, 1, 2, 255]);
      final entry = await a.inbox.addFile(file.path);
      await syncAll();
      await a.inbox.editMessage(
        entry.item,
        text: 'Alpha caption',
        name: 'Alpha.bin',
      );
      await b.inbox.editMessage(
        b.inbox.store.find(entry.item.id)!.item,
        text: 'Beta caption',
        name: 'Beta.bin',
      );
      await syncAll();
      final conflict = a.inbox.syncProblems.single;
      expect(conflict.versions.map((v) => v.name).toSet(), {
        'Alpha.bin',
        'Beta.bin',
      });
      await a.inbox.resolveConflict(
        conflict,
        text: 'Chosen caption',
        name: 'Chosen.bin',
      );
      await syncAll();
      for (final device in devices) {
        final updated = device.inbox.store.find(entry.item.id)!.item;
        expect(updated.name, 'Chosen.bin');
        expect(updated.digest, entry.item.digest);
        expect(
          await (await device.inbox.store.fileForExport(updated)).readAsBytes(),
          [0, 1, 2, 255],
        );
        expect(device.inbox.syncProblems, isEmpty);
      }
    },
  );

  test(
    'concurrent versions survive restart and choosing one resolves every device',
    () async {
      final a = await create('Alpha');
      final b = await create('Beta');
      await pair(a, b);
      final entry = (await a.inbox.addText('original'))!;
      await syncAll();
      await a.inbox.editMessage(entry.item, text: 'from Alpha');
      await b.inbox.editMessage(
        b.inbox.store.find(entry.item.id)!.item,
        text: 'from Beta',
      );
      await syncAll();
      for (final device in devices) {
        final conflict = device.inbox.syncProblems.single;
        expect(conflict.versions.map((v) => v.text).toSet(), {
          'from Alpha',
          'from Beta',
        });
        expect(conflict.versions.map((v) => v.editorName).toSet(), {
          'Alpha',
          'Beta',
        });
        expect(
          device.inbox.copyStatus(device.inbox.store.find(entry.item.id)!),
          '内容冲突，待选择',
        );
      }
      await b.close();
      b.inbox.dispose();
      b.lan.dispose();
      devices.remove(b);
      final restarted = await create('Beta');
      final conflict = restarted.inbox.syncProblems.single;
      final selected = conflict.versions.firstWhere(
        (v) => v.text == 'from Alpha',
      );
      await restarted.inbox.resolveConflict(conflict, versionId: selected.id);
      await syncAll();
      for (final device in devices) {
        expect(device.inbox.syncProblems, isEmpty);
        expect(device.inbox.store.find(entry.item.id)!.item.text, 'from Alpha');
        expect(device.inbox.connectionProblems, isEmpty);
      }
    },
  );

  test(
    'sequential cross-device edits stay automatic while a stale editor preserves both versions',
    () async {
      final a = await create('Alpha');
      final b = await create('Beta');
      await pair(a, b);
      final entry = (await a.inbox.addText('original'))!;
      await syncAll();
      await a.inbox.editMessage(entry.item, text: 'first');
      await syncAll();
      await b.inbox.editMessage(
        b.inbox.store.find(entry.item.id)!.item,
        text: 'second',
      );
      await syncAll();
      expect(a.inbox.syncProblems, isEmpty);
      expect(b.inbox.syncProblems, isEmpty);
      final stale = a.inbox.store.find(entry.item.id)!.item;
      await b.inbox.editMessage(
        b.inbox.store.find(entry.item.id)!.item,
        text: 'third from Beta',
      );
      await syncAll();
      await a.inbox.editMessage(stale, text: 'unsaved Alpha draft');
      await syncAll();
      expect(a.inbox.syncProblems.single.versions.map((v) => v.text).toSet(), {
        'third from Beta',
        'unsaved Alpha draft',
      });
      await a.inbox.resolveConflict(
        a.inbox.syncProblems.single,
        text: 'combined by user',
        name: '',
      );
      await syncAll();
      expect(b.inbox.store.find(entry.item.id)!.item.text, 'combined by user');
      expect(b.inbox.syncProblems, isEmpty);
    },
  );

  test(
    'deleting all versions propagates and late offline edits cannot revive them',
    () async {
      final a = await create('Alpha');
      final b = await create('Beta');
      final c = await create('Gamma');
      await pair(a, b);
      await pair(c, b);
      final entry = (await a.inbox.addText('original'))!;
      await syncAll();
      await a.inbox.editMessage(entry.item, text: 'Alpha edit');
      await b.inbox.editMessage(
        b.inbox.store.find(entry.item.id)!.item,
        text: 'Beta edit',
      );
      await c.inbox.editMessage(
        c.inbox.store.find(entry.item.id)!.item,
        text: 'late Gamma edit',
      );
      c.inbox.setNetworkAvailable(false);
      c.lan.setReceivingPaused(true);
      await a.inbox.syncNow();
      expect(a.inbox.syncProblems, hasLength(1));
      await a.inbox.deleteConflict(a.inbox.syncProblems.single);
      c.lan.setReceivingPaused(false);
      c.inbox.setNetworkAvailable(true);
      await syncAll();
      for (final device in devices) {
        expect(device.inbox.store.find(entry.item.id), isNull);
        expect(device.inbox.syncProblems, isEmpty);
      }
    },
  );

  test(
    'a removed transfer remains removed until an explicit sync reset',
    () async {
      final a = await create('Alpha');
      final b = await create('Beta');
      await pair(a, b);
      final handler = b.lan.onInboxRequest!;
      var failUpload = true;
      var attempts = 0;
      b.lan.onInboxRequest = (request) async {
        if (request.method == 'PUT') {
          attempts++;
          if (failUpload) {
            await request.drain<void>();
            await inboxReply(request, 503, {'error': 'busy'});
            return;
          }
        }
        await handler(request);
      };
      final file = File('${root.path}/content.bin');
      await file.writeAsBytes([1, 2, 3, 4]);
      final entry = await a.inbox.addFile(file.path);
      await a.inbox.syncNow();
      final task = a.inbox.transferTasks.single;
      expect(task.state, 'failed');
      await a.inbox.controlTransfer(task, 'delete');
      failUpload = false;
      final before = attempts;
      await a.inbox.syncNow();
      expect(attempts, before);
      expect(a.inbox.transferTasks, isEmpty);
      expect(a.inbox.store.find(entry.item.id), isNotNull);
      await a.inbox.resetSync('device:${b.lan.identity.id}');
      await a.inbox.syncNow();
      expect(attempts, greaterThan(before));
      expect(b.inbox.store.find(entry.item.id), isNotNull);
    },
  );

  test(
    'connection settings can be corrected offline without removing messages or pairing',
    () async {
      final a = await create('Alpha');
      final b = await create('Beta');
      await pair(a, b);
      final entry = (await a.inbox.addText('keep me'))!;
      final id = b.lan.identity.id;
      final session = a.lan.sessions[id];
      a.inbox.setNetworkAvailable(false);
      await a.inbox.updateDeviceAddress(id, '192.168.9.88:54321');
      expect(a.lan.peers[id]!.address, '192.168.9.88');
      expect(a.lan.peers[id]!.port, 54321);
      expect(a.lan.sessions[id], same(session));
      final saved = await a.lan.store.load();
      expect(
        (saved['peers'] as List).singleWhere((p) => p['id'] == id)['address'],
        '192.168.9.88',
      );
      final hub = SyncEndpoint(
        id: 'nas-settings-test',
        name: 'Old NAS',
        url: Uri.parse('https://192.168.9.11:53320'),
        fingerprint: 'a' * 64,
        token: 'b' * 43,
        isHub: true,
      );
      a.inbox.store.hubs.add(hub);
      await a.inbox.updateHub(
        hub,
        address: '192.168.9.12:53320',
        name: 'New NAS',
      );
      expect(a.inbox.store.hubs.single.name, 'New NAS');
      expect(a.inbox.store.hubs.single.url.host, '192.168.9.12');
      expect(a.inbox.store.hubs.single.token, hub.token);
      await a.inbox.removeHub(a.inbox.store.hubs.single);
      await a.inbox.removeDevice(id);
      expect(a.inbox.store.find(entry.item.id), isNotNull);
      expect(a.inbox.syncProblems, isEmpty);
    },
  );
}
