import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/inbox/inbox_models.dart';

import '../support/test_device.dart';

void main() {
  late Directory root;
  final devices = <TestDevice>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanflow-inbox-');
  });
  tearDown(() async {
    for (final device in devices) {
      await device.close();
      device.inbox.dispose();
      device.lan.dispose();
    }
    devices.clear();
    await root.delete(recursive: true);
  });
  Future<TestDevice> device(String id) async {
    final value = await TestDevice.create('${root.path}/$id', id);
    devices.add(value);
    return value;
  }

  Future<void> bind(TestDevice a, TestDevice b) async {
    final peer = await a.lan.addAddress('127.0.0.1:${b.lan.self.port}');
    await a.lan.connect(peer);
  }

  test(
    'categories broadcast to every device; drafts and appearance remain local across restarts',
    () async {
      var phone = await device('category-phone');
      final pc = await device('category-pc');
      final tablet = await device('category-tablet');
      for (final receiver in [pc, tablet]) {
        receiver.lan.onPrompt = (_) async => true;
        await bind(phone, receiver);
      }
      final legacy = (await phone.inbox.addText('默认会话的消息'))!;
      phone.inbox.setDraft('默认草稿');
      final work = await phone.inbox.createConversation('工作');
      final note = (await phone.inbox.addText('分类消息发给所有设备'))!;
      final source = File('${root.path}/category.bin');
      await source.writeAsBytes([1, 2, 3, 4]);
      final file = await phone.inbox.addFile(source.path);
      phone.inbox.setDraft('工作草稿');
      await phone.inbox.pasteImage(Uint8List.fromList([137, 80, 78, 71]));
      await phone.inbox.setAppearance('dark');
      await phone.inbox.setComposerFraction(.4);
      await phone.inbox.syncNow();
      for (final receiver in [pc, tablet]) {
        expect(
          receiver.inbox.conversations.any(
            (c) => c.id == work.id && c.name == '工作',
          ),
          isTrue,
        );
        expect(
          receiver.inbox.itemsIn(work.id).map((e) => e.item.id),
          containsAll([note.item.id, file.item.id]),
        );
        expect(
          receiver.inbox.itemsIn(defaultConversationId).single.item.id,
          legacy.item.id,
        );
        expect(
          await receiver.inbox.store.blob(file.item.digest).readAsBytes(),
          [1, 2, 3, 4],
        );
        expect(receiver.inbox.appearance.value, 'light');
      }
      await phone.close();
      phone = await device('category-phone');
      expect(phone.inbox.conversationId, work.id);
      expect(phone.inbox.store.draft, '工作草稿');
      expect(phone.inbox.store.draftAttachments.single.conversationId, work.id);
      expect(phone.inbox.appearance.value, 'dark');
      expect(phone.inbox.store.composerFraction, .4);
      phone.inbox.selectConversation(defaultConversationId);
      expect(phone.inbox.store.draft, '默认草稿');
      expect(phone.inbox.store.draftAttachments, isEmpty);
      await phone.inbox.addShared({
        'id': 'category-share',
        'text': '外部分享始终进默认收件箱',
      });
      expect(
        phone.inbox.items.first.item.conversationId,
        defaultConversationId,
      );
      await phone.inbox.deleteItem(note.item);
      await phone.inbox.syncNow();
      expect(
        pc.inbox.itemsIn(work.id).any((e) => e.item.id == note.item.id),
        isFalse,
      );
    },
  );

  test(
    'deletion reaches offline devices and never resurrects after stale replay',
    () async {
      final phone = await device('delete-phone');
      final pc = await device('delete-pc');
      pc.lan.onPrompt = (_) async => true;
      await bind(phone, pc);
      final note = (await phone.inbox.addText('删除后不能被离线设备恢复'))!;
      await phone.inbox.syncNow();
      expect(pc.inbox.items.single.item.id, note.item.id);
      await pc.close();
      await phone.inbox.deleteItem(note.item);
      expect(phone.inbox.items, isEmpty);
      final resumed = await device('delete-pc');
      await resumed.lan.addAddress('127.0.0.1:${phone.lan.self.port}');
      final snapshots = <Set<String>>[];
      phone.inbox.addListener(
        () => snapshots.add(phone.inbox.items.map((e) => e.item.id).toSet()),
      );
      await resumed.inbox.syncNow();
      await phone.inbox.syncNow();
      expect(resumed.inbox.items, isEmpty);
      expect(snapshots.every((items) => !items.contains(note.item.id)), isTrue);
      await resumed.inbox.store.add(note.item);
      expect(resumed.inbox.items, isEmpty);
      await resumed.close();
      final again = await device('delete-pc');
      expect(again.inbox.items, isEmpty);
      expect(again.inbox.store.deleted, contains(note.item.id));
    },
  );

  test(
    'device rename and avatar propagate without changing or losing historical messages',
    () async {
      final phone = await device('profile-phone');
      final pc = await device('profile-pc');
      pc.lan.onPrompt = (_) async => true;
      await bind(phone, pc);
      final note = (await phone.inbox.addText('消息属于同一台设备'))!;
      await phone.inbox.syncNow();
      final seen = <bool>[];
      pc.inbox.addListener(
        () => seen.add(pc.inbox.items.any((e) => e.item.id == note.item.id)),
      );
      const avatar =
          'iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGMQaXr2H4QZYAwAUxQJ7UIG+7IAAAAASUVORK5CYII=';
      await phone.inbox.updateProfile('随身手机', avatar: avatar);
      await phone.inbox.syncNow();
      await pc.inbox.syncNow();
      expect(pc.inbox.deviceName(note.item.originId), '随身手机');
      expect(pc.inbox.deviceAvatar(note.item.originId), avatar);
      expect(pc.inbox.items.single.item.text, note.item.text);
      expect(seen.every((present) => present), isTrue);
    },
  );

  test(
    'newly reappearing devices receive queued messages without the old ten-second delay',
    () async {
      final phone = await TestDevice.create(
        '${root.path}/live-phone',
        'phone',
        automaticSync: true,
      );
      devices.add(phone);
      final pc = await device('live-pc');
      pc.lan.onPrompt = (_) async => true;
      await bind(phone, pc);
      await pc.close();
      final note = (await phone.inbox.addText('电脑再次上线时立即补传'))!;
      // Establish the offline backoff before rediscovery, independently of
      // machine speed and whether the automatic sync timer has fired yet.
      await phone.inbox.syncNow();
      expect(
        phone.inbox.statuses['device:${pc.lan.identity.id}']!.retryAfter,
        isNotNull,
      );
      final states = <bool>[];
      phone.inbox.addListener(
        () =>
            states.add(phone.inbox.items.any((e) => e.item.id == note.item.id)),
      );
      final resumed = await device('live-pc');
      final timer = Stopwatch()..start();
      await phone.lan.addAddress('127.0.0.1:${resumed.lan.self.port}');
      while (resumed.inbox.store.find(note.item.id) == null &&
          timer.elapsed < const Duration(seconds: 3)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(resumed.inbox.store.find(note.item.id), isNotNull);
      expect(states.every((present) => present), isTrue);
      expect(timer.elapsed, lessThan(const Duration(seconds: 3)));
    },
  );

  test(
    'offline text, file contents, and image drafts survive restart and source deletion',
    () async {
      var phone = await device('phone');
      await phone.inbox.addText('还没回到家，先记下这个想法');
      final source = File('${root.path}/original.mp4');
      final bytes = Uint8List.fromList(List.generate(320003, (i) => i % 251));
      await source.writeAsBytes(bytes);
      final fileEntry = await phone.inbox.addFile(source.path);
      await source.delete();
      await phone.inbox.pasteImage(Uint8List.fromList([137, 80, 78, 71]));
      phone.inbox.setDraft('尚未发送的文字');
      await phone.close();
      phone = await device('phone');
      expect(phone.inbox.items, hasLength(2));
      expect(phone.inbox.store.draft, '尚未发送的文字');
      expect(phone.inbox.store.draftAttachments, hasLength(1));
      expect(
        await phone.inbox.store.blob(fileEntry.item.digest).readAsBytes(),
        bytes,
      );
      await phone.inbox.sendDraftAttachments();
      expect(phone.inbox.items, hasLength(3));
      expect(phone.inbox.store.draftAttachments, isEmpty);
    },
  );

  test(
    'one inbox fans out to all bound devices with zero content confirmations and no duplicates',
    () async {
      final phone = await device('phone');
      final home = await device('home');
      final office = await device('office');
      var pairPrompts = 0;
      for (final receiver in [home, office]) {
        receiver.lan.onPrompt = (prompt) async {
          expect(
            prompt.code,
            isNotNull,
            reason: 'Content must not create a confirmation dialog',
          );
          pairPrompts++;
          return true;
        };
        await bind(phone, receiver);
      }
      final note = await phone.inbox.addText('所有自己的设备都应该收到');
      final expected = <String, List<int>>{};
      for (final spec in [
        ('photo.png', 8193),
        ('video.mp4', 250003),
        ('report.zip', 33003),
        ('empty.bin', 0),
      ]) {
        final bytes = List<int>.generate(spec.$2, (i) => i % 251);
        final source = File('${root.path}/${spec.$1}');
        await source.writeAsBytes(bytes);
        final entry = await phone.inbox.addFile(source.path);
        expected[entry.item.digest] = bytes;
      }
      await phone.inbox.syncNow();
      await home.inbox.syncNow();
      await office.inbox.syncNow();
      await phone.inbox.syncNow();
      expect(pairPrompts, 2);
      for (final target in [phone, home, office]) {
        expect(
          target.inbox.items,
          hasLength(5),
          reason: target.inbox.statuses.values.map((e) => e.error).join(','),
        );
        expect(
          target.inbox.store.find(note!.item.id)?.item.text,
          note.item.text,
        );
        for (final entry in expected.entries) {
          expect(
            await target.inbox.store.blob(entry.key).readAsBytes(),
            entry.value,
          );
        }
      }
      await home.close();
      await phone.inbox.addText('电脑关机时先保存');
      await phone.inbox.syncNow();
      expect(phone.inbox.items, hasLength(6));
      final resumed = await device('home');
      await resumed.lan.addAddress('127.0.0.1:${phone.lan.self.port}');
      await resumed.inbox.syncNow();
      expect(resumed.inbox.items, hasLength(6));
      expect(
        pairPrompts,
        2,
        reason: 'A restart must not require pairing again',
      );
    },
  );

  test(
    'Android share replay is idempotent for text and multiple files',
    () async {
      final phone = await device('phone');
      final files = <Map<String, String>>[];
      for (final name in ['截图.png', '视频.mp4']) {
        final file = File('${root.path}/$name');
        await file.writeAsString(name);
        files.add({'path': file.path, 'name': name});
      }
      final payload = {
        'id': 'android-share-id',
        'text': '好玩的视频 https://example.com/video',
        'files': files,
      };
      await phone.inbox.addShared(payload);
      await phone.inbox.addShared(payload);
      expect(phone.inbox.items, hasLength(3));
      await phone.close();
      final resumed = await device('phone');
      await resumed.inbox.addShared(payload);
      expect(resumed.inbox.items, hasLength(3));
    },
  );

  test(
    'inbox routes reject unbound clients, corrupt files and conflicting IDs',
    () async {
      final a = await device('a');
      final b = await device('b');
      b.lan.onPrompt = (_) async => true;
      await bind(a, b);
      final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
      Future<int> request(
        String method,
        String path,
        List<int> bytes, {
        bool authorized = true,
      }) async {
        final request = await client.openUrl(
          method,
          Uri.parse('https://127.0.0.1:${b.lan.self.port}$path'),
        );
        if (authorized) {
          request.headers.set('X-Lanflow-Device', a.lan.identity.id);
          request.headers.set(
            'Authorization',
            'Bearer ${a.lan.sessions[b.lan.identity.id]!.sendToken}',
          );
        }
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      }

      try {
        final item = (await a.inbox.addText('原始内容'))!.item;
        expect(
          await request(
            'POST',
            '/v2/items',
            utf8.encode(jsonEncode(item.toJson())),
            authorized: false,
          ),
          401,
        );
        final digest = sha256.convert([1, 2, 3]).toString();
        expect(await request('PUT', '/v2/blobs/$digest', [4, 5, 6]), 400);
        expect(await b.inbox.store.hasBlob(digest), isFalse);
        expect(
          await Directory(
            '${b.inbox.store.directory.path}/system/cache/incoming',
          ).list().toList(),
          isEmpty,
        );
        await a.inbox.syncNow();
        expect(
          await request(
            'POST',
            '/v2/items',
            utf8.encode(jsonEncode({...item.toJson(), 'text': '修改已有记录'})),
          ),
          409,
        );
        expect(b.inbox.items.single.item.text, '原始内容');
      } finally {
        client.close(force: true);
      }
    },
  );

  test(
    'a file item is never committed before its bytes are complete',
    () async {
      final a = await device('a');
      final item = InboxItem(
        id: 'abcdefghijklmnop',
        originId: a.lan.identity.id,
        originName: 'a',
        createdAt: DateTime.now(),
        kind: (await a.inbox.addFile(
          (await File('${root.path}/x.png').writeAsString('x')).path,
        )).item.kind,
        name: 'missing.png',
        size: 9,
        digest: 'a' * 64,
      );
      await expectLater(a.inbox.store.add(item), throwsFormatException);
      expect(a.inbox.store.find(item.id), isNull);
    },
  );
}
