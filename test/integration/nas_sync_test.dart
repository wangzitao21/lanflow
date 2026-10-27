import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/network/identity.dart';

import '../support/test_device.dart';

String hubExecutable() {
  final name = Platform.isWindows ? 'lanflow-hub.exe' : 'lanflow-hub';
  final candidates = [
    if (Platform.environment['LANFLOW_TEST_HUB'] case final String path) path,
    'build/native/$name',
    'build/rust/debug/$name',
  ];
  return candidates.firstWhere(
    (path) => File(path).existsSync(),
    orElse: () => throw StateError(
      'Run scripts/package.ps1 -Target check to build and test in Debian, '
      'or set LANFLOW_TEST_HUB.',
    ),
  );
}

class _Nas {
  _Nas(this.directory);
  final Directory directory;
  Process? process;
  int port = 0;
  String code = '';
  Future<void> start() async {
    await directory.create(recursive: true);
    final identity = await Identity.load(directory);
    final cert = File('${directory.path}/certificate.pem');
    final key = File('${directory.path}/private-key.pem');
    await cert.writeAsString(identity.certificate);
    await key.writeAsString(identity.privateKey);
    final ready = Completer<void>();
    final errors = StringBuffer();
    process = await Process.start(hubExecutable(), [
      '--data',
      directory.path,
      '--host',
      '127.0.0.1',
      '--port',
      '0',
      '--certificate',
      cert.path,
      '--private-key',
      key.path,
    ]);
    process!.stderr.transform(utf8.decoder).listen(errors.write);
    process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('LanFlow NAS ready')) {
            port = int.parse(line.split(' ').last);
          }
          if (line.startsWith('lanflow1:')) {
            code = line;
            if (!ready.isCompleted) ready.complete();
          }
        });
    unawaited(
      process!.exitCode.then((exit) {
        if (!ready.isCompleted) {
          ready.completeError(StateError('NAS exited $exit: $errors'));
        }
      }),
    );
    await ready.future.timeout(const Duration(seconds: 15));
  }

  String get address => '127.0.0.1:$port';
  Future<void> stop() async {
    process?.kill();
    await process?.exitCode;
    process = null;
  }
}

void main() {
  test(
    'NAS retains concurrent edits and relays the user resolution to new devices',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-nas-conflict-',
      );
      final nas = _Nas(Directory('${root.path}/nas'));
      final devices = <TestDevice>[];
      Future<TestDevice> create(String name) async {
        final device = await TestDevice.create('${root.path}/$name', name);
        devices.add(device);
        await device.inbox.addHub(nas.address, nas.code, 'NAS');
        return device;
      }

      try {
        await nas.start();
        final a = await create('Alpha');
        final entry = (await a.inbox.addText('original'))!;
        await a.inbox.syncNow();
        final b = await create('Beta');
        await b.inbox.syncNow();
        await a.inbox.editMessage(entry.item, text: 'Alpha version');
        await b.inbox.editMessage(
          b.inbox.store.find(entry.item.id)!.item,
          text: 'Beta version',
        );
        await a.inbox.syncNow();
        await b.inbox.syncNow();
        await a.inbox.syncNow();
        expect(a.inbox.syncProblems.single.versions, hasLength(2));
        expect(b.inbox.syncProblems.single.versions, hasLength(2));
        final conflict = a.inbox.syncProblems.single;
        await a.inbox.resolveConflict(
          conflict,
          versionId: conflict.versions
              .firstWhere((v) => v.text == 'Beta version')
              .id,
        );
        await a.inbox.syncNow();
        await b.inbox.syncNow();
        final c = await create('Gamma');
        await c.inbox.syncNow();
        for (final device in devices) {
          expect(
            device.inbox.store.find(entry.item.id)!.item.text,
            'Beta version',
          );
          expect(device.inbox.syncProblems, isEmpty);
        }
      } finally {
        for (final device in devices.reversed) {
          await device.close();
          device.inbox.dispose();
          device.lan.dispose();
        }
        await nas.stop();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'NAS content notifications wake an idle client without periodic sync',
    () async {
      final root = await Directory.systemTemp.createTemp('lanflow-nas-notify-');
      final nas = _Nas(Directory('${root.path}/nas'));
      final source = await TestDevice.create('${root.path}/source', '来源');
      final receiver = await TestDevice.create(
        '${root.path}/receiver',
        '接收',
        automaticSync: true,
      );
      final linked = await TestDevice.create(
        '${root.path}/linked',
        '仅连接接收端',
        automaticSync: true,
      );
      Future<void> waitUntil(bool Function() condition) async {
        final deadline = DateTime.now().add(const Duration(seconds: 12));
        while (!condition()) {
          if (DateTime.now().isAfter(deadline)) {
            fail('NAS notification did not arrive');
          }
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      }

      try {
        linked.lan.onPrompt = (_) async => true;
        final peer = await receiver.lan.addAddress(
          '127.0.0.1:${linked.lan.self.port}',
        );
        await receiver.lan.connect(peer);
        await nas.start();
        await source.inbox.addHub(nas.address, nas.code, '测试 NAS');
        await receiver.inbox.addHub(nas.address, nas.code, '测试 NAS');
        await waitUntil(
          () =>
              receiver
                      .inbox
                      .statuses[receiver.inbox.store.hubs.single.key]
                      ?.lastSuccess !=
                  null &&
              !receiver.inbox.syncing,
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        final idle = receiver
            .inbox
            .statuses[receiver.inbox.store.hubs.single.key]!
            .lastSuccess;
        await Future<void>.delayed(const Duration(seconds: 4));
        expect(
          receiver
              .inbox
              .statuses[receiver.inbox.store.hubs.single.key]!
              .lastSuccess,
          idle,
        );
        final note = (await source.inbox.addText('NAS 有变化才唤醒同步'))!;
        await source.inbox.syncNow();
        await waitUntil(() => receiver.inbox.store.find(note.item.id) != null);
        await waitUntil(() => linked.inbox.store.find(note.item.id) != null);
        expect(
          receiver
              .inbox
              .statuses[receiver.inbox.store.hubs.single.key]!
              .notificationsSupported,
          isTrue,
        );
        await receiver.inbox.removeHub(receiver.inbox.store.hubs.single);
        expect(receiver.inbox.store.find(note.item.id), isNotNull);
      } finally {
        await receiver.close();
        await source.close();
        await linked.close();
        await nas.stop();
        receiver.inbox.dispose();
        receiver.lan.dispose();
        source.inbox.dispose();
        source.lan.dispose();
        linked.inbox.dispose();
        linked.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'real TLS NAS stores while PC is off; a phone bridges home and office after restarts',
    () async {
      final root = await Directory.systemTemp.createTemp('lanflow-nas-sync-');
      final home = _Nas(Directory('${root.path}/home-nas'));
      final office = _Nas(Directory('${root.path}/office-nas'));
      final devices = <TestDevice>[];
      Future<TestDevice> create(String id) async {
        final device = await TestDevice.create('${root.path}/$id', id);
        devices.add(device);
        return device;
      }

      try {
        await home.start();
        await office.start();
        var phone = await create('phone');
        await phone.inbox.addText('在家刷到的视频 https://example.com/watch');
        final category = await phone.inbox.createConversation('稍后看');
        final source = File('${root.path}/video.mp4');
        final bytes = List<int>.generate(1024 * 1024 + 7, (i) => i % 251);
        await source.writeAsBytes(bytes);
        final entry = await phone.inbox.addFile(source.path);
        await phone.inbox.addHub(home.address, home.code, '家里 NAS');
        await phone.inbox.syncNow();
        expect(phone.inbox.statuses.values.single.error, isNull);
        expect(phone.inbox.copyStatus(entry), '已同步 1/1');
        await phone.close();

        final homePc = await create('home-pc');
        await homePc.inbox.addHub(home.address, home.code, '家里 NAS');
        await homePc.inbox.syncNow();
        expect(homePc.inbox.items, hasLength(2));
        expect(
          homePc.inbox.conversations.any(
            (c) => c.id == category.id && c.name == '稍后看',
          ),
          isTrue,
        );
        expect(homePc.inbox.itemsIn(category.id).single.item.id, entry.item.id);
        expect(
          await homePc.inbox.store.blob(entry.item.digest).readAsBytes(),
          bytes,
        );
        await homePc.inbox.addText('电脑处理后的补充想法');
        await homePc.inbox.syncNow();
        await homePc.close();

        phone = await create('phone');
        await phone.inbox.syncNow();
        expect(phone.inbox.items, hasLength(3));
        await home.stop();
        await phone.inbox.addHub(office.address, office.code, '单位 NAS');
        await phone.inbox.addText('到了单位继续处理');
        await phone.inbox.syncNow();
        expect(
          phone.inbox.statuses.values.where((s) => s.online),
          hasLength(1),
        );
        await phone.close();
        await office.stop();
        await office.start();

        final workPc = await create('office-pc');
        await workPc.inbox.addHub(office.address, office.code, '单位 NAS');
        await workPc.inbox.syncNow();
        expect(workPc.inbox.items, hasLength(4));
        expect(
          await workPc.inbox.store.blob(entry.item.digest).readAsBytes(),
          bytes,
        );
        await workPc.inbox.addText('单位电脑留下的批注');
        await workPc.inbox.syncNow();

        phone = await create('phone');
        await phone.inbox.addHub(office.address, office.code, '单位 NAS');
        await phone.inbox.syncNow();
        expect(phone.inbox.items, hasLength(5));
        await home.start();
        await phone.inbox.addHub(home.address, home.code, '家里 NAS');
        await phone.inbox.syncNow();
        await phone.inbox.syncNow();
        final homeAgain = await create('home-pc');
        await homeAgain.inbox.addHub(home.address, home.code, '家里 NAS');
        await homeAgain.inbox.syncNow();
        expect(homeAgain.inbox.items, hasLength(5));
        expect(
          homeAgain.inbox.conversations.any((c) => c.id == category.id),
          isTrue,
        );
        expect(
          homeAgain.inbox.store.find(entry.item.id)!.item.conversationId,
          category.id,
        );
        expect(
          homeAgain.inbox.items.map((e) => e.item.id).toSet(),
          hasLength(5),
        );

        final wrong =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(
                      base64Url.normalize(home.code.substring(9)),
                    ),
                  ),
                )
                as Map<String, dynamic>;
        wrong['fingerprint'] = '0' * 64;
        final wrongCode =
            'lanflow1:${base64Url.encode(utf8.encode(jsonEncode(wrong))).replaceAll('=', '')}';
        await expectLater(
          homeAgain.inbox.addHub(home.address, wrongCode, '伪装 NAS'),
          throwsA(isA<HandshakeException>()),
        );
      } finally {
        for (final device in devices) {
          await device.close();
          device.inbox.dispose();
          device.lan.dispose();
        }
        await home.stop();
        await office.stop();
        await root.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
