import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:lanflow/platform/native_core.dart';

abstract final class StorageLayout {
  static Directory system(Directory root) =>
      Directory(p.join(root.path, 'system'));
  static Directory device(Directory root) =>
      Directory(p.join(root.path, 'system', 'device'));
  static Directory incoming(Directory root) =>
      Directory(p.join(root.path, 'system', 'cache', 'incoming'));
  static Directory previews(Directory root) =>
      Directory(p.join(root.path, 'system', 'cache', 'previews'));
  static Directory received(Directory root) =>
      Directory(p.join(root.path, 'system', 'cache', 'legacy_received'));
  static String pending(Directory root, String digest) =>
      p.join(root.path, 'system', 'pending', digest);

  static Future<void> prepare(Directory root) async {
    await NativeCore.run({'op': 'prepare_storage', 'root': root.path});
  }

  static Future<void> prepareDevice(Directory root) async {
    await NativeCore.run({'op': 'prepare_device_storage', 'root': root.path});
  }

  static Map<String, dynamic> updateLegacyPaths(
    Directory root,
    Map<String, dynamic> value,
  ) {
    final state = value;
    String relocate(String path) {
      // Translate only managed prefixes. A user file named "设备" or "打开"
      // inside the cache must retain its original name.
      final prefixes = <String, String>{};
      for (final oldSystem in ['系统', 'system', 'inbox']) {
        for (final pair in {
          '缓存/旧版接收': 'cache/legacy_received',
          '缓存/接收': 'cache/incoming',
          '缓存/打开': 'cache/previews',
          'cache/旧版接收': 'cache/legacy_received',
          'cache/接收': 'cache/incoming',
          'cache/打开': 'cache/previews',
          '设备': 'device',
          '缓存': 'cache',
          '待整理': 'pending',
          '旧版': 'legacy',
          '恢复的文件': 'recovered',
          'blobs': 'pending',
          'incoming': 'cache/incoming',
          'open': 'cache/previews',
        }.entries) {
          prefixes[p.joinAll([root.path, oldSystem, ...pair.key.split('/')])] =
              p.joinAll([root.path, 'system', ...pair.value.split('/')]);
        }
        if (oldSystem != 'system') {
          prefixes[p.join(root.path, oldSystem)] = system(root).path;
        }
      }
      for (final pair in {
        '媒体': 'media',
        '文件': 'files',
        'blobs': 'system/pending',
        'incoming': 'system/cache/incoming',
        'open': 'system/cache/previews',
        'received': 'system/legacy/received',
        'downloads': 'system/legacy/downloads',
      }.entries) {
        prefixes[p.join(root.path, pair.key)] = p.joinAll([
          root.path,
          ...pair.value.split('/'),
        ]);
      }
      for (final prefix in prefixes.entries) {
        if (p.equals(prefix.key, path)) return prefix.value;
        if (p.isWithin(prefix.key, path)) {
          return p.join(prefix.value, p.relative(path, from: prefix.key));
        }
      }
      return path;
    }

    for (final message in state['messages'] as List? ?? []) {
      if (message['path'] is String) {
        message['path'] = relocate(message['path'] as String);
      }
    }
    final receive = state['receiveDirectory'];
    if (receive is String && relocate(receive) != receive) {
      state['receiveDirectory'] = received(root).path;
    }
    return state;
  }
}
