import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/platform/native_core.dart';
import 'package:path/path.dart' as p;

import '../support/test_device.dart';

void main() {
  test(
    'closing waits for the entire multi-attachment send and removes every sent draft',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-close-draft-send-',
      );
      final data = p.join(root.path, 'data');
      final device = await TestDevice.create(data, '发送中的草稿');
      final source = File(p.join(root.path, 'attachment.bin'));
      await source.writeAsBytes(List<int>.generate(4000, (i) => i % 251));
      Future<void>? sending;
      try {
        for (var index = 0; index < 12; index++) {
          await device.inbox.stageFile(source.path);
        }
        var completed = false;
        sending = device.inbox.sendDraftAttachments().then(
          (_) => completed = true,
        );
        await device.close();
        final completedBeforeClose = completed;
        await sending;
        expect(
          completedBeforeClose,
          isTrue,
          reason:
              'A closed controller must not keep sending into its old storage root.',
        );
        final reopened = await TestDevice.create(data, '发送中的草稿');
        try {
          expect(reopened.inbox.items.length, 12);
          expect(reopened.inbox.store.draftAttachments, isEmpty);
        } finally {
          await reopened.close();
          reopened.inbox.dispose();
          reopened.lan.dispose();
        }
      } finally {
        await sending;
        await NativeCore.run({'op': 'close', 'root': data});
        device.inbox.dispose();
        device.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'a shared batch already accepted finishes all files before closing',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-close-shared-',
      );
      final data = p.join(root.path, 'data');
      final device = await TestDevice.create(data, '共享批次');
      final source = File(p.join(root.path, 'shared.bin'));
      await source.writeAsBytes(
        List<int>.generate(1024 * 1024, (i) => i % 251),
      );
      Future<void>? sharing;
      try {
        var completed = false;
        sharing = device.inbox
            .addShared({
              'id': 'closing-share',
              'text': '分享中的文字',
              'files': List.generate(
                4,
                (index) => {'path': source.path, 'name': 'share-$index.bin'},
              ),
            })
            .then((_) => completed = true);
        await device.close();
        final completedBeforeClose = completed;
        await sharing;
        expect(completedBeforeClose, isTrue);
        final reopened = await TestDevice.create(data, '共享批次');
        try {
          expect(reopened.inbox.items.length, 5);
        } finally {
          await reopened.close();
          reopened.inbox.dispose();
          reopened.lan.dispose();
        }
      } finally {
        await sharing;
        await NativeCore.run({'op': 'close', 'root': data});
        device.inbox.dispose();
        device.lan.dispose();
        await root.delete(recursive: true);
      }
    },
  );
}
