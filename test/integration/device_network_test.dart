import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/inbox/inbox_api.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/platform/native_core.dart';
import '../support/test_device.dart';

Future<void> until(bool Function() done, [String phase = '']) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Device network did not converge: $phase');
    }
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
}

void main() {
  late Directory root;
  final devices = <TestDevice>[];
  setUp(
    () async =>
        root = await Directory.systemTemp.createTemp('lanflow-network-'),
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
  Future<TestDevice> create(String name, {bool automatic = true}) async {
    final d = await TestDevice.create(
      '${root.path}/$name',
      name,
      automaticSync: automatic,
    );
    devices.add(d);
    return d;
  }

  Future<void> pair(TestDevice a, TestDevice b) async {
    b.lan.onPrompt = (_) async => true;
    final peer = await a.lan
        .addAddress('127.0.0.1:${b.lan.self.port}')
        .timeout(const Duration(seconds: 8));
    await a.lan.connect(peer).timeout(const Duration(seconds: 12));
  }

  test(
    'one pairing joins three devices and offline text, edits and files catch up automatically',
    () async {
      final computer = await create('computer');
      final phone = await create('phone');
      final other = await create('other-phone');
      await pair(computer, phone);
      // The last phone is only paired with the first phone, never the computer.
      await pair(other, phone);
      await until(
        () => devices.every((d) => d.lan.sessions.length == 2),
        'bindings',
      );
      final note = (await other.inbox.addText('最初的消息'))!;
      await until(
        () => devices.every((d) => d.inbox.store.find(note.item.id) != null),
        'first message',
      );
      other.inbox.setNetworkAvailable(false);
      other.lan.setReceivingPaused(true);
      await computer.inbox.editMessage(
        computer.inbox.store.find(note.item.id)!.item,
        text: '电脑上修改的消息',
      );
      final file = File('${root.path}/example.bin');
      await file.writeAsBytes(List.generate(70000, (i) => i % 251));
      final attachment = await phone.inbox.addFile(file.path);
      await until(
        () => computer.inbox.store.find(attachment.item.id) != null,
        'file delivered to computer',
      );
      other.lan.setReceivingPaused(false);
      other.inbox.setNetworkAvailable(true);
      await until(
        () =>
            other.inbox.store.find(note.item.id)?.item.text == '电脑上修改的消息' &&
            other.inbox.store.find(attachment.item.id) != null,
        'offline catchup',
      );
      expect(
        await other.inbox.store.blob(attachment.item.digest).readAsBytes(),
        await file.readAsBytes(),
      );
      await until(
        () => devices.every(
          (d) => d.inbox.syncProblems.isEmpty && !d.inbox.syncing,
        ),
        'idle',
      );
      expect(
        other.inbox.items.where((e) => e.item.id == note.item.id),
        hasLength(1),
      );
      expect(
        other.inbox.store.find(note.item.id)!.item.createdAt,
        note.item.createdAt,
      );
    },
  );

  test(
    'retry repairs stale session credentials without another pairing prompt',
    () async {
      final a = await create('a', automatic: false);
      final b = await create('b', automatic: false);
      await pair(a, b);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      b.lan.onPrompt = (_) =>
          throw StateError('Must not ask for pairing again');
      final key = 'device:${b.lan.identity.id}';
      final old = a.lan.sessions[b.lan.identity.id]!;
      a.lan.sessions[b.lan.identity.id] = PeerSession(
        sendToken: randomToken(),
        receiveToken: old.receiveToken,
      );
      final note = (await a.inbox.addText('凭据修复后自动送达'))!;
      await a.inbox.retrySync(key);
      expect(b.inbox.store.find(note.item.id)?.item.text, '凭据修复后自动送达');
      expect(a.inbox.syncProblems, isEmpty);
      expect(a.inbox.store.find(note.item.id)!.copies, contains(key));
    },
  );

  test(
    'joining two existing networks connects every member without extra confirmation',
    () async {
      final a = await create('group-a');
      final b = await create('group-b');
      final c = await create('group-c');
      final d = await create('group-d');
      await pair(a, b);
      await pair(c, d);
      a.lan.onPrompt = (_) => throw StateError('No additional confirmation');
      d.lan.onPrompt = (_) => throw StateError('No additional confirmation');
      await pair(b, c);
      await until(
        () => devices.every((device) => device.lan.sessions.length == 3),
        'joined networks',
      );
      final message = (await d.inbox.addText('两组设备自动打通'))!;
      await until(
        () => devices.every(
          (device) => device.inbox.store.find(message.item.id) != null,
        ),
        'joined network delivery',
      );
    },
  );

  test(
    'network membership survives restart and forgotten devices are not silently reintroduced',
    () async {
      final a = await create('persist-a');
      var b = await create('persist-b');
      final c = await create('persist-c');
      await pair(a, b);
      await pair(c, b);
      await until(
        () => devices.every((device) => device.lan.sessions.length == 2),
        'initial network',
      );
      await b.close();
      final message = (await c.inbox.addText('重启后补发'))!;
      b = await create('persist-b');
      await until(
        () => b.inbox.store.find(message.item.id) != null,
        'restarted receiver',
      );
      expect(b.lan.sessions, hasLength(2));
      await a.inbox.removeDevice(c.lan.identity.id);
      await a.lan.refreshDeviceNetwork(a.lan.peers[b.lan.identity.id]!);
      expect(a.lan.sessions.containsKey(c.lan.identity.id), isFalse);
    },
  );

  test(
    'retry reads durable jobs even when the displayed transfer list is stale',
    () async {
      final a = await create('retry-a', automatic: false);
      final b = await create('retry-b', automatic: false);
      await pair(a, b);
      final handler = b.lan.onInboxRequest!;
      var fail = true;
      b.lan.onInboxRequest = (request) async {
        if (fail && request.method == 'PUT') {
          await request.drain<void>();
          await inboxReply(request, 503, {'error': '暂时忙'});
          return;
        }
        await handler(request);
      };
      final source = File('${root.path}/retry.bin');
      await source.writeAsString('retry bytes');
      final file = await a.inbox.addFile(source.path);
      await a.inbox.syncNow();
      expect(a.inbox.transferTasks.any((t) => t.state == 'failed'), isTrue);
      a.inbox.transferTasks = [];
      fail = false;
      await a.inbox.retrySync('device:${b.lan.identity.id}');
      expect(b.inbox.store.find(file.item.id), isNotNull);
      expect(a.inbox.transferTasks, isEmpty);
      expect(a.inbox.syncProblems, isEmpty);
    },
  );

  test(
    'edited message survives restart and updates search and its favorite view',
    () async {
      final a = await create('edits', automatic: false);
      final note = (await a.inbox.addText('old searchable text'))!;
      await a.inbox.setFavorites([note.item.id], true);
      await a.inbox.editMessage(note.item, text: 'new searchable text');
      expect(a.inbox.favoriteEntries.single.item.text, 'new searchable text');
      final result = await NativeCore.run({
        'op': 'search_messages',
        'root': a.inbox.store.directory.path,
        'query': 'new searchable',
      });
      expect(result['ids'], contains(note.item.id));
      final seq = a.inbox.store.find(note.item.id)!.sequence;
      await a.close();
      final restarted = await create('edits', automatic: false);
      expect(
        restarted.inbox.store.find(note.item.id)!.item.text,
        'new searchable text',
      );
      expect(restarted.inbox.store.find(note.item.id)!.sequence, seq);
    },
  );

  test(
    'attachment names and captions can be edited on a receiving device without changing bytes',
    () async {
      final a = await create('file-a', automatic: false);
      final b = await create('file-b', automatic: false);
      await pair(a, b);
      final source = File('${root.path}/original.bin');
      await source.writeAsBytes([0, 1, 2, 255]);
      final original = await a.inbox.addFile(source.path);
      await a.inbox.syncNow();
      await b.inbox.editMessage(
        b.inbox.store.find(original.item.id)!.item,
        text: '附件说明',
        name: '新文件名.bin',
      );
      await b.inbox.syncNow();
      final edited = a.inbox.store.find(original.item.id)!.item;
      expect(edited.name, '新文件名.bin');
      expect(edited.text, '附件说明');
      expect(edited.digest, original.item.digest);
      expect(edited.createdAt, original.item.createdAt);
      expect(await (await a.inbox.store.fileForExport(edited)).readAsBytes(), [
        0,
        1,
        2,
        255,
      ]);
      expect(a.inbox.syncProblems, isEmpty);
      expect(b.inbox.syncProblems, isEmpty);
    },
  );
}
