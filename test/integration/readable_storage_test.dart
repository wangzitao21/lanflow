import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/test_device.dart';

void main() {
  test(
    'media and other files retain original names and bytes in a three-folder layout',
    () async {
      final temp = await Directory.systemTemp.createTemp('lanflow-readable-');
      final root = Directory(p.join(temp.path, 'data'));
      final device = await TestDevice.create(root.path, '资料设备');
      try {
        final cases = [
          ('旅行照片.png', 'media', List<int>.generate(18000, (i) => i % 251)),
          ('旅行视频.mp4', 'media', List<int>.generate(24000, (i) => i % 239)),
          ('项目资料.zip', 'files', List<int>.generate(10000, (i) => i % 233)),
        ];
        for (final entry in cases) {
          final source = File(p.join(temp.path, entry.$1));
          await source.writeAsBytes(entry.$3);
          final sent = await device.inbox.addFile(source.path);
          final saved = File(p.join(root.path, entry.$2, entry.$1));
          expect(await saved.readAsBytes(), entry.$3);
          expect(
            p.equals(
              device.inbox.store.blob(sent.item.digest).path,
              saved.path,
            ),
            isTrue,
          );
          expect(sent.item.name, entry.$1);
          expect(await source.readAsBytes(), entry.$3);
        }
        await device.inbox.addText('消息保存在 SQLite 中');
        expect(
          await File(p.join(root.path, 'system', 'messages.sqlite3')).exists(),
          isTrue,
        );
        expect(
          (await root.list().map((entry) => p.basename(entry.path)).toList())
              .toSet(),
          {'system', 'media', 'files'},
        );
        expect(
          await Directory(
            p.join(root.path, 'system', 'pending'),
          ).list().isEmpty,
          isTrue,
        );
        final stats = await device.inbox.store.storageStats(
          clearPreviews: true,
        );
        expect(stats['blobs'], 52000);
        for (final entry in cases) {
          expect(
            await File(p.join(root.path, entry.$2, entry.$1)).readAsBytes(),
            entry.$3,
          );
        }
      } finally {
        await device.close();
        device.inbox.dispose();
        device.lan.dispose();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'upgrading the old root preserves identity, history and drafts and can restart repeatedly',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'lanflow-layout-upgrade-',
      );
      final root = Directory(p.join(temp.path, 'data'));
      final original = await TestDevice.create(root.path, '旧资料设备');
      final image = File(p.join(temp.path, '原图.png'));
      await image.writeAsBytes([137, 80, 78, 71, 11, 22, 33, 44]);
      final sent = await original.inbox.addFile(image.path);
      await original.inbox.stageFile(image.path);
      original.inbox.setDraft('尚未发送的内容');
      final identity = original.lan.identity.id;
      await original.close();
      original.inbox.dispose();
      original.lan.dispose();
      final settings = Directory(p.join(root.path, 'system', 'device'));
      await for (final file in settings.list()) {
        await file.rename(p.join(root.path, p.basename(file.path)));
      }
      await settings.delete();
      await Directory(
        p.join(root.path, 'system'),
      ).rename(p.join(root.path, 'inbox'));
      final received = File(p.join(root.path, 'received', '旧版附件.txt'));
      await received.parent.create();
      await received.writeAsString('保留旧版接收的原文件');
      try {
        for (var attempt = 0; attempt < 2; attempt++) {
          final updated = await TestDevice.create(root.path, '旧资料设备');
          try {
            expect(updated.lan.identity.id, identity);
            expect(updated.inbox.store.draft, '尚未发送的内容');
            expect(updated.inbox.store.draftAttachments.single.name, '原图.png');
            expect(updated.inbox.items.single.item.id, sent.item.id);
            expect(
              await updated.inbox.store.blob(sent.item.digest).readAsBytes(),
              await image.readAsBytes(),
            );
            expect(
              (await root
                      .list()
                      .map((entry) => p.basename(entry.path))
                      .toList())
                  .toSet(),
              {'system', 'media', 'files'},
            );
            expect(
              await File(
                p.join(root.path, 'system', 'legacy', 'received', '旧版附件.txt'),
              ).readAsString(),
              '保留旧版接收的原文件',
            );
          } finally {
            await updated.close();
            updated.inbox.dispose();
            updated.lan.dispose();
          }
        }
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );
}
