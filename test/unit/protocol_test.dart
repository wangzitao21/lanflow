import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/files/file_utils.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/storage/local_store.dart';

void main() {
  test(
    'reject forged device IDs, invalid ports, and incompatible discovery versions',
    () {
      final valid = {
        'version': 1,
        'id': 'a' * 32,
        'fingerprint': 'a' * 64,
        'name': 'Windows',
        'platform': 'windows',
        'port': 53318,
      };
      expect(
        Peer.fromJson(valid, address: '192.168.1.2').address,
        '192.168.1.2',
      );
      for (final invalid in [
        {'port': 0},
        {'port': 65536},
        {'version': 2},
        {'id': 'b' * 32},
        {'name': ''},
      ]) {
        expect(
          () => Peer.fromJson({...valid, ...invalid}),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'sanitize remote file names against traversal and Windows reserved names',
    () {
      expect(safeFileName('../../report.pdf'), 'report.pdf');
      expect(safeFileName(r'C:\secret\image.png'), 'image.png');
      expect(safeFileName('CON.txt'), '_CON.txt');
      expect(safeFileName('a:b?.pdf'), 'a_b_.pdf');
      expect(safeFileName('..'), 'file');
      expect(safeFileName('trailing. '), 'trailing');
      final longName = '${'a' * 180}.pdf';
      expect(safeFileName(longName), longName);
      expect(safeFileName('${'🙂' * 80}.png').endsWith('.png'), isTrue);
      expect(safeFileName('${'🙂' * 80}.png'), isNot(contains('\uFFFD')));
    },
  );

  test(
    'unfinished transfers restore as interrupted rather than successful',
    () {
      final message = ChatMessage(
        id: 'abc',
        peerId: 'peer',
        outgoing: true,
        kind: MessageKind.file,
        createdAt: DateTime.now(),
        delivery: Delivery.transferring,
      );
      final restored = ChatMessage.fromJson(message.toJson());
      expect(restored.delivery, Delivery.failed);
      expect(restored.error, contains('中断'));
    },
  );

  test(
    'storage recovers the prior snapshot if the newest JSON is corrupt',
    () async {
      final directory = await Directory.systemTemp.createTemp('lanflow-state-');
      try {
        final store = LocalStore(directory);
        await store.save({'name': 'first'});
        await store.save({'name': 'second'});
        await File(
          '${store.deviceDirectory.path}/state.json',
        ).writeAsString('{truncated');
        expect((await store.load())['name'], 'first');
        await File(
          '${store.deviceDirectory.path}/state.json',
        ).writeAsString('[]');
        expect((await store.load())['name'], 'first');
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
