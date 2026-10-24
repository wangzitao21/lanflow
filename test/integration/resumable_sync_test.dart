import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_api.dart';

import '../support/test_device.dart';

void main() {
  late Directory root;
  final devices = <TestDevice>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanflow-resume-');
  });
  tearDown(() async {
    for (final device in devices.reversed) {
      await device.close();
      device.inbox.dispose();
      device.lan.dispose();
    }
    devices.clear();
    await root.delete(recursive: true);
  });
  Future<TestDevice> device(String name) async {
    final value = await TestDevice.create('${root.path}/$name', name);
    devices.add(value);
    return value;
  }

  Future<void> bind(TestDevice client, TestDevice server) async {
    server.lan.onPrompt = (_) async => true;
    final peer = await client.lan.addAddress(
      '127.0.0.1:${server.lan.self.port}',
    );
    await client.lan.connect(peer);
  }

  Future<File> source(String name, {int bytes = 9 * 1024 * 1024 + 17}) async {
    final file = File('${root.path}/$name');
    await file.writeAsBytes(
      Uint8List.fromList(
        List<int>.generate(bytes, (i) => (i * 31 + i ~/ 1024) % 256),
      ),
    );
    return file;
  }

  test('offline targets still expose durable queued attachments', () async {
    final phone = await device('offline-source');
    final pc = await device('offline-target');
    await bind(phone, pc);
    await pc.close();
    final file = await source('offline.bin', bytes: 128);
    final entry = await phone.inbox.addFile(file.path);
    await phone.inbox.syncNow();
    expect(phone.inbox.transferTasks.single.item.id, entry.item.id);
    expect(phone.inbox.transferTasks.single.transferred, 0);
    expect(phone.inbox.statuses.values.single.error, isNotNull);
  });

  test(
    'unbinding hides transfers without losing resumable progress on rebind',
    () async {
      final phone = await device('unbind-source');
      final pc = await device('unbind-target');
      await bind(phone, pc);
      final input = await source('unbind.bin');
      final entry = await phone.inbox.addFile(input.path);
      await phone.inbox.syncNow();
      final progress = phone.inbox.transferTasks.single.transferred;
      expect(progress, 4 * 1024 * 1024);
      phone.lan.forgetPeer(pc.lan.identity.id);
      for (var i = 0; i < 50 && phone.inbox.transferTasks.isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(phone.inbox.transferTasks, isEmpty);
      expect(
        (await phone.inbox.store.transfers()).single['transferred'],
        progress,
      );
      pc.lan.forgetPeer(phone.lan.identity.id);
      await bind(phone, pc);
      await phone.inbox.syncNow();
      expect(phone.inbox.transferTasks.single.transferred, 8 * 1024 * 1024);
      await phone.inbox.syncNow();
      expect(pc.inbox.store.find(entry.item.id), isNotNull);
      expect(phone.inbox.transferTasks, isEmpty);
    },
  );

  test(
    'failed attachments back off without starving later files or text',
    () async {
      final phone = await device('failure-source');
      final pc = await device('failure-target');
      await bind(phone, pc);
      for (var i = 0; i < 4; i++) {
        final file = File('${root.path}/broken-$i.bin');
        await file.writeAsString('不可用附件 $i');
        final entry = await phone.inbox.addFile(file.path);
        await phone.inbox.store.blob(entry.item.digest).delete();
      }
      final good = await source('good.bin', bytes: 1024);
      final entry = await phone.inbox.addFile(good.path);
      await phone.inbox.addText('附件失败也能收到这条文字');
      await phone.inbox.syncNow();
      expect(pc.inbox.items.single.item.text, '附件失败也能收到这条文字');
      await phone.inbox.syncNow();
      expect(pc.inbox.store.find(entry.item.id), isNotNull);
      expect(phone.inbox.transferTasks.length, 4);
      expect(
        phone.inbox.transferTasks.every((task) => task.state == 'failed'),
        isTrue,
      );
    },
  );

  test(
    'explicit sync retry repairs failed files without resuming paused transfers',
    () async {
      final phone = await device('retry-source');
      final pc = await device('retry-target');
      await bind(phone, pc);
      final brokenFile = await source('repair.bin', bytes: 1024);
      final broken = await phone.inbox.addFile(brokenFile.path);
      await phone.inbox.store.blob(broken.item.digest).delete();
      final largeFile = await source('stay-paused.bin');
      final large = await phone.inbox.addFile(largeFile.path);
      await phone.inbox.syncNow();
      final failed = phone.inbox.transferTasks.firstWhere(
        (task) => task.item.id == broken.item.id,
      );
      expect(failed.state, 'failed');
      final paused = phone.inbox.transferTasks.firstWhere(
        (task) => task.item.id == large.item.id,
      );
      await phone.inbox.controlTransfer(paused, 'pause');
      expect(
        phone.inbox.syncProblems.map((target) => target.key),
        contains(failed.endpoint),
      );
      await phone.inbox.store
          .blob(broken.item.digest)
          .writeAsBytes(await brokenFile.readAsBytes());
      await phone.inbox.retrySync(failed.endpoint);
      expect(
        pc.inbox.items.where((entry) => entry.item.id == broken.item.id),
        hasLength(1),
      );
      expect(phone.inbox.syncProblems, isEmpty);
      final remaining = phone.inbox.transferTasks.single;
      expect(remaining.item.id, large.item.id);
      expect(remaining.state, 'paused');
      expect(remaining.transferred, paused.transferred);
    },
  );

  test(
    'upload resumes after restart; paused files do not block text or permit a peer pull',
    () async {
      var phone = await device('phone');
      final pc = await device('pc');
      await bind(phone, pc);
      final input = await source('upload.bin');
      final entry = await phone.inbox.addFile(input.path);
      await phone.inbox.addText('文字先到');
      await phone.inbox.syncNow();
      expect(pc.inbox.items.any((e) => e.item.text == '文字先到'), isTrue);
      expect(pc.inbox.store.find(entry.item.id), isNull);
      final task = phone.inbox.transferTasks.single;
      expect(task.transferred, 4 * 1024 * 1024);
      await phone.inbox.controlTransfer(task, 'pause');
      await pc.inbox.syncNow();
      expect(pc.inbox.store.find(entry.item.id), isNull);
      expect(pc.inbox.transferTasks.single.state, 'failed');
      await phone.close();
      phone = await device('phone');
      await phone.lan.addAddress('127.0.0.1:${pc.lan.self.port}');
      expect(phone.inbox.transferTasks.single.state, 'paused');
      await phone.inbox.addText('大文件暂停时的新消息');
      await phone.inbox.syncNow();
      expect(pc.inbox.items.any((e) => e.item.text == '大文件暂停时的新消息'), isTrue);
      expect(phone.inbox.transferTasks.single.transferred, task.transferred);
      await phone.inbox.store.transferAction(
        phone.inbox.transferTasks.single,
        'retry',
      );
      await phone.inbox.syncNow();
      expect(phone.inbox.transferTasks.single.transferred, 8 * 1024 * 1024);
      await phone.inbox.syncNow();
      expect(phone.inbox.transferTasks, isEmpty);
      expect(pc.inbox.store.find(entry.item.id), isNotNull);
      expect(
        await pc.inbox.store.blob(entry.item.digest).readAsBytes(),
        await input.readAsBytes(),
      );
      await phone.inbox.syncNow();
      expect(pc.inbox.items.where((e) => e.item.id == entry.item.id).length, 1);
    },
  );

  test(
    'download cursor and partial file survive a restart while newer text arrives',
    () async {
      final pc = await device('source');
      var phone = await device('reader');
      final input = await source('download.bin');
      final entry = await pc.inbox.addFile(input.path);
      await bind(phone, pc);
      await phone.inbox.syncNow();
      expect(phone.inbox.transferTasks.single.direction, 'download');
      expect(phone.inbox.transferTasks.single.transferred, 4 * 1024 * 1024);
      await phone.close();
      phone = await device('reader');
      await phone.lan.addAddress('127.0.0.1:${pc.lan.self.port}');
      await pc.inbox.addText('下载期间也能接收文字');
      await phone.inbox.syncNow();
      expect(phone.inbox.items.any((e) => e.item.text == '下载期间也能接收文字'), isTrue);
      expect(phone.inbox.transferTasks.single.transferred, 8 * 1024 * 1024);
      await phone.inbox.syncNow();
      expect(phone.inbox.transferTasks, isEmpty);
      expect(phone.inbox.store.find(entry.item.id), isNotNull);
      expect(
        await phone.inbox.store.blob(entry.item.digest).readAsBytes(),
        await input.readAsBytes(),
      );
    },
  );

  test(
    'cancelled transfers stay cancelled after restart and can be explicitly retried',
    () async {
      var phone = await device('cancel-source');
      final pc = await device('cancel-target');
      await bind(phone, pc);
      final file = await source('cancel.bin', bytes: 5 * 1024 * 1024);
      final item = await phone.inbox.addFile(file.path);
      await phone.inbox.syncNow();
      await phone.inbox.controlTransfer(
        phone.inbox.transferTasks.single,
        'cancel',
      );
      await phone.close();
      phone = await device('cancel-source');
      await phone.lan.addAddress('127.0.0.1:${pc.lan.self.port}');
      await phone.inbox.syncNow();
      expect(phone.inbox.transferTasks.single.state, 'cancelled');
      expect(pc.inbox.store.find(item.item.id), isNull);
      await phone.inbox.store.transferAction(
        phone.inbox.transferTasks.single,
        'retry',
      );
      await phone.inbox.syncNow();
      expect(pc.inbox.store.find(item.item.id), isNotNull);
    },
  );

  test(
    'recently deleted restores files across devices without reviving tombstoned identities',
    () async {
      final phone = await device('restore-phone');
      final pc = await device('restore-pc');
      await bind(phone, pc);
      final input = await source('restore.bin', bytes: 1024);
      final original = await phone.inbox.addFile(input.path);
      await phone.inbox.syncNow();
      await phone.inbox.deleteItem(original.item);
      await phone.inbox.syncNow();
      final deleted = await phone.inbox.store.recentlyDeleted();
      expect(deleted.single.available, isTrue);
      expect(
        (await pc.inbox.store.recentlyDeleted()).single.item.id,
        original.item.id,
      );
      await phone.inbox.restoreItem(deleted.single.item);
      final restored = phone.inbox.items.single;
      expect(restored.item.id, isNot(original.item.id));
      await phone.inbox.syncNow();
      await pc.inbox.restoreItem(original.item);
      await pc.inbox.store.add(original.item);
      expect(pc.inbox.items.single.item.id, restored.item.id);
      expect(
        await pc.inbox.store.blob(restored.item.digest).readAsBytes(),
        await input.readAsBytes(),
      );
    },
  );

  test(
    'legacy whole-file peers remain compatible in both directions',
    () async {
      final modern = await device('modern');
      final legacy = await device('legacy');
      final originalHandler = legacy.lan.onInboxRequest!;
      legacy.lan.onInboxRequest = (request) async {
        if (!request.uri.path.startsWith('/v2/blobs/')) {
          await originalHandler(request);
          return;
        }
        final digest = request.uri.path.substring('/v2/blobs/'.length);
        final file = legacy.inbox.store.blob(digest);
        if (request.method == 'PUT') {
          expect(request.headers.value('Content-Range'), isNull);
          await legacy.inbox.store.storeBlob(
            request,
            request.contentLength,
            digest: digest,
          );
          await inboxReply(request, 200, {'sha256': digest});
        } else if (await file.exists()) {
          request.response.contentLength = await file.length();
          if (request.method == 'GET') {
            expect(request.headers.value(HttpHeaders.rangeHeader), isNull);
            await request.response.addStream(file.openRead());
          }
          await request.response.close();
        } else {
          request.response.statusCode = 404;
          await request.response.close();
        }
      };
      await bind(modern, legacy);
      final file = await source('legacy.bin', bytes: 5 * 1024 * 1024);
      final uploaded = await modern.inbox.addFile(file.path);
      await modern.inbox.syncNow();
      expect(legacy.inbox.store.find(uploaded.item.id), isNotNull);
      final second = await source(
        'legacy-return.bin',
        bytes: 5 * 1024 * 1024 + 1,
      );
      final downloaded = await legacy.inbox.addFile(second.path);
      await modern.inbox.syncNow();
      expect(modern.inbox.store.find(downloaded.item.id), isNotNull);
      expect(modern.inbox.transferTasks, isEmpty);
    },
  );

  test(
    'device range API validates offsets and recovers a fully flushed final chunk',
    () async {
      final a = await device('api-source');
      final b = await device('api-target');
      await bind(a, b);
      final bytes = utf8.encode('chunked-api-content');
      final digest = sha256.convert(bytes).toString();
      final peer = a.lan.peers[b.lan.identity.id]!;
      final client =
          HttpClient(context: SecurityContext(withTrustedRoots: false))
            ..badCertificateCallback = (cert, _, _) =>
                sha256.convert(cert.der).toString() == peer.fingerprint;
      addTearDown(() => client.close(force: true));
      Future<HttpClientResponse> request(
        String method, {
        String? range,
        List<int>? data,
      }) async {
        final req = await client.openUrl(
          method,
          Uri.parse(
            'https://127.0.0.1:${b.lan.self.port}/v2/blobs/$digest?size=${bytes.length}',
          ),
        );
        req.headers.set('X-Lanflow-Device', a.lan.identity.id);
        req.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${a.lan.sessions[peer.id]!.sendToken}',
        );
        if (range != null) {
          req.headers.set(method == 'PUT' ? 'Content-Range' : 'Range', range);
        }
        if (data != null) {
          req.contentLength = data.length;
          req.add(data);
        }
        return req.close();
      }

      var response = await request(
        'PUT',
        range: 'bytes 0-4/${bytes.length}',
        data: bytes.sublist(0, 5),
      );
      expect(response.statusCode, 200);
      await response.drain<void>();
      response = await request('HEAD');
      expect(response.headers.value('X-Lanflow-Offset'), '5');
      await response.drain<void>();
      response = await request(
        'PUT',
        range: 'bytes 0-4/${bytes.length}',
        data: bytes.sublist(0, 5),
      );
      expect(response.statusCode, 409);
      await response.drain<void>();
      // Emulate a crash after fsync but before committing the completed blob.
      final part = File(
        '${b.inbox.store.directory.path}/system/cache/incoming/$digest.${bytes.length}.upload.part',
      );
      await part.writeAsBytes(bytes, flush: true);
      response = await request('HEAD');
      expect(response.statusCode, 200);
      await response.drain<void>();
      response = await request('GET', range: 'bytes=5-9');
      expect(response.statusCode, 206);
      expect(
        response.headers.value('Content-Range'),
        'bytes 5-9/${bytes.length}',
      );
      expect(
        await response.fold<List<int>>([], (all, data) => all..addAll(data)),
        bytes.sublist(5, 10),
      );
    },
  );
}
