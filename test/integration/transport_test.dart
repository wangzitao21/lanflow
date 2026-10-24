import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/storage/local_store.dart';

void main() {
  late Directory sandbox;
  late LanController first;
  late LanController second;
  late Peer remote;
  var pairPrompts = 0;
  var filePrompts = 0;

  setUpAll(() async {
    sandbox = await Directory.systemTemp.createTemp('lanflow-transport-');
    first = LanController(
      store: LocalStore(Directory('${sandbox.path}/a')),
      receiveDirectory: Directory('${sandbox.path}/a/received'),
      enableDiscovery: false,
      preferredPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      initialName: 'Windows test',
    );
    second = LanController(
      store: LocalStore(Directory('${sandbox.path}/b')),
      receiveDirectory: Directory('${sandbox.path}/b/received'),
      enableDiscovery: false,
      preferredPort: 0,
      bindAddress: InternetAddress.loopbackIPv4,
      initialName: 'Android test',
    );
    second.onPrompt = (prompt) async {
      if (prompt.code != null) {
        pairPrompts++;
      } else {
        filePrompts++;
      }
      return true;
    };
    first.onPrompt = (_) async => true;
    await first.start();
    await second.start();
    expect(first.ready, isTrue, reason: first.error);
    expect(second.ready, isTrue, reason: second.error);
    remote = await first.addAddress('127.0.0.1:${second.self.port}');
  });

  tearDownAll(() async {
    await first.close();
    await second.close();
    first.dispose();
    second.dispose();
    await sandbox.delete(recursive: true);
  });

  test(
    'TLS identity lookup, pairing confirmation, and bidirectional Unicode text',
    () async {
      expect(remote.fingerprint, second.identity.fingerprint);
      await first.connect(remote).timeout(const Duration(seconds: 10));
      await first.sendText(remote, '你好 Android 👋\n第二行');
      expect(pairPrompts, 1);
      expect(first.messages.last.delivery, Delivery.complete);
      expect(second.messages.last.text, '你好 Android 👋\n第二行');
      expect(
        verificationCode(
          first.identity.fingerprint,
          second.identity.fingerprint,
        ),
        verificationCode(
          second.identity.fingerprint,
          first.identity.fingerprint,
        ),
      );
      final back = second.peers[first.identity.id]!;
      await second.sendText(back, 'Windows 收到 ✅');
      expect(first.messages.last.text, 'Windows 收到 ✅');
      expect(first.messages.last.outgoing, isFalse);
    },
  );

  test(
    'stream images, videos, arbitrary files, and empty files with byte-for-byte integrity',
    () async {
      for (final entry in [
        ('sample.png', 8193),
        ('movie.mp4', 3 * 1024 * 1024 + 7),
        ('archive.bin', 33333),
        ('empty.dat', 0),
      ]) {
        final source = File('${sandbox.path}/${entry.$1}');
        final bytes = Uint8List.fromList(
          List<int>.generate(entry.$2, (i) => (i * 17 + 23) % 256),
        );
        await source.writeAsBytes(bytes);
        await first.sendFile(remote, source.path);
        final sent = first.messages.last;
        expect(sent.delivery, Delivery.complete, reason: sent.error);
        final received = second.messages.last;
        expect(received.delivery, Delivery.complete, reason: received.error);
        expect(received.size, entry.$2);
        expect(received.transferred, entry.$2);
        expect(await File(received.path!).readAsBytes(), bytes);
        expect(received.kind, sent.kind);
      }
      expect(filePrompts, 0);
      expect(pairPrompts, 1);
    },
  );

  test(
    'authenticated message IDs deduplicate a retried acknowledgement',
    () async {
      final before = second.messages.length;
      final message = first.messages.firstWhere(
        (m) => m.kind == MessageKind.text && m.outgoing,
      );
      message.delivery = Delivery.failed;
      await first.retry(message);
      expect(message.delivery, Delivery.complete);
      expect(second.messages.length, before);
    },
  );

  test('bound devices receive files even with no confirmation UI', () async {
    second.onPrompt = (_) async => false;
    final source = File('${sandbox.path}/rejected.bin');
    await source.writeAsString('not accepted');
    final before = second.messages.length;
    await first.sendFile(remote, source.path);
    expect(first.messages.last.delivery, Delivery.complete);
    expect(second.messages.length, before + 1);
    second.onPrompt = (_) async => true;
  });

  test('unpaired callers cannot inject messages', () async {
    final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
    try {
      final request = await client.postUrl(
        Uri.parse('https://127.0.0.1:${second.self.port}/v1/text'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode({'id': randomToken(18), 'text': 'unauthorized'}),
      );
      final response = await request.close();
      expect(response.statusCode, 401);
      await response.drain<void>();
    } finally {
      client.close(force: true);
    }
  });

  test('pause receiving rejects new messages without adding history', () async {
    second.setReceivingPaused(true);
    final count = second.messages.length;
    await first.sendText(remote, 'paused');
    expect(first.messages.last.delivery, Delivery.failed);
    expect(second.messages.length, count);
    second.setReceivingPaused(false);
  });

  test('tampered certificate fingerprint fails closed', () async {
    final impostor = Peer(
      id: remote.id,
      name: remote.name,
      platform: remote.platform,
      address: remote.address,
      port: remote.port,
      fingerprint: '0' * 64,
    );
    final count = second.messages.length;
    await first.sendText(impostor, 'must not arrive');
    expect(first.messages.last.delivery, Delivery.failed);
    expect(second.messages.length, count);
  });

  test('wrong file checksum is rejected and partial data is removed', () async {
    final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
    void authenticate(HttpClientRequest request) {
      request.headers.set('X-Lanflow-Device', first.identity.id);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${first.sessions[remote.id]!.sendToken}',
      );
    }

    try {
      final offer = await client.postUrl(
        Uri.parse('https://127.0.0.1:${second.self.port}/v1/offer'),
      );
      authenticate(offer);
      offer.headers.contentType = ContentType.json;
      offer.write(
        jsonEncode({
          'id': randomToken(18),
          'name': '../../escape.bin',
          'kind': 'file',
          'size': 3,
          'sha256': sha256.convert([4, 5, 6]).toString(),
        }),
      );
      final accepted = await offer.close();
      expect(accepted.statusCode, 200);
      final data =
          jsonDecode(await utf8.decoder.bind(accepted).join())
              as Map<String, dynamic>;
      final upload = await client.putUrl(
        Uri.parse(
          'https://127.0.0.1:${second.self.port}/v1/upload/${data['token']}',
        ),
      );
      authenticate(upload);
      upload.contentLength = 3;
      upload.add([1, 2, 3]);
      final result = await upload.close();
      expect(result.statusCode, 400);
      await result.drain<void>();
      expect(second.messages.last.delivery, Delivery.failed);
      expect(second.messages.last.path, isNull);
      expect(second.messages.last.name, 'escape.bin');
      expect(
        (await second.receiveDirectory.list().toList()).where(
          (file) => file.path.endsWith('.part'),
        ),
        isEmpty,
      );
    } finally {
      client.close(force: true);
    }
  });

  test('trusted sessions and messages survive local persistence', () async {
    await first.store.save({
      'name': first.name,
      'sessions': first.sessions.map((k, v) => MapEntry(k, v.toJson())),
      'messages': first.messages.map((m) => m.toJson()).toList(),
    });
    final restored = await first.store.load();
    expect(restored['name'], first.name);
    expect((restored['sessions'] as Map).keys, contains(remote.id));
    expect((restored['messages'] as List).length, first.messages.length);
  });
}
