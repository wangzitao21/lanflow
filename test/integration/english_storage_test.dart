import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/storage/storage_layout.dart';
import 'package:lanflow/core/storage/storage_location.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'only managed path prefixes change, never the original attachment name',
    () {
      final root = Directory(
        p.join(Directory.systemTemp.path, 'lanflow-paths'),
      );
      final paths = {
        '系统/缓存/旧版接收/设备': 'system/cache/legacy_received/设备',
        '系统/缓存/打开/123456789/接收': 'system/cache/previews/123456789/接收',
        '系统/旧版/received/缓存/媒体.txt': 'system/legacy/received/缓存/媒体.txt',
        'inbox/incoming/部分附件.part': 'system/cache/incoming/部分附件.part',
        '媒体/旅行照片.png': 'media/旅行照片.png',
        '文件/项目资料.zip': 'files/项目资料.zip',
        'received/打开': 'system/legacy/received/打开',
        'system/cache/打开/123456789/旧版': 'system/cache/previews/123456789/旧版',
      };
      for (final entry in paths.entries) {
        final state = StorageLayout.updateLegacyPaths(root, {
          'messages': [
            {
              'path': p.joinAll([root.path, ...entry.key.split('/')]),
            },
          ],
        });
        expect(
          (state['messages'] as List).single['path'],
          p.joinAll([root.path, ...entry.value.split('/')]),
        );
      }
      final external = p.join(root.parent.path, 'user-documents', '媒体', '设备');
      final state = StorageLayout.updateLegacyPaths(root, {
        'messages': [
          {'path': external},
        ],
      });
      expect((state['messages'] as List).single['path'], external);
    },
  );

  test(
    'legacy locator upgrades to English and retains a valid fallback across restarts',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-locator-english-',
      );
      final bootstrap = Directory(p.join(root.path, 'bootstrap'));
      final target = await Directory(p.join(root.path, 'actual-data')).create();
      final legacy = await Directory(
        p.join(bootstrap.path, '系统'),
      ).create(recursive: true);
      final preserved = File(p.join(legacy.path, 'unrelated.data'));
      await preserved.writeAsString('preserve unrelated data');
      await File(
        p.join(legacy.path, 'storage-location.json'),
      ).writeAsString('invalid');
      await File(
        p.join(legacy.path, 'storage-location.json.backup'),
      ).writeAsString(jsonEncode({'path': target.path}));
      try {
        final location = StorageLocation(bootstrap);
        expect((await location.resolve()).path, target.path);
        expect(
          await File(
            p.join(bootstrap.path, 'system', 'storage-location.json'),
          ).exists(),
          isTrue,
        );
        expect(
          await File(
            p.join(legacy.path, 'storage-location.json.backup'),
          ).exists(),
          isFalse,
        );
        expect(await preserved.readAsString(), 'preserve unrelated data');
        await File(
          p.join(bootstrap.path, 'system', 'storage-location.json'),
        ).writeAsString('corrupt');
        expect((await StorageLocation(bootstrap).resolve()).path, target.path);
      } finally {
        await root.delete(recursive: true);
      }
    },
  );

  test(
    'unavailable selected disk never silently switches to bootstrap data',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'lanflow-locator-missing-',
      );
      final system = await Directory(p.join(root.path, 'system')).create();
      await File(
        p.join(system.path, 'storage-location.json'),
      ).writeAsString(jsonEncode({'path': p.join(root.path, 'missing-disk')}));
      try {
        await expectLater(
          StorageLocation(root).resolve(),
          throwsA(isA<FileSystemException>()),
        );
      } finally {
        await root.delete(recursive: true);
      }
    },
  );
}
