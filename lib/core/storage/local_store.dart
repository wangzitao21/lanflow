import 'dart:convert';
import 'dart:io';
import 'storage_layout.dart';

class LocalStore {
  LocalStore(this.directory);
  final Directory directory;
  Directory get deviceDirectory => StorageLayout.device(directory);
  Future<void> _pending = Future.value();

  Future<Map<String, dynamic>> load() async {
    await StorageLayout.prepareDevice(directory);
    var hadState = false;
    for (final name in ['state.json', 'state.backup.json']) {
      final file = File('${deviceDirectory.path}/$name');
      if (!await file.exists()) continue;
      hadState = true;
      try {
        final value = jsonDecode(await file.readAsString());
        if (value is Map<String, dynamic>) {
          return StorageLayout.updateLegacyPaths(directory, value);
        }
      } on FormatException {
        continue;
      }
    }
    if (hadState) throw const FormatException('本地记录和备份均无法读取，请保留数据以便恢复');
    return {};
  }

  Future<void> save(Map<String, dynamic> state) {
    final encoded = jsonEncode(state);
    final next = _pending.catchError((Object _) {}).then((_) async {
      await deviceDirectory.create(recursive: true);
      final target = File('${deviceDirectory.path}/state.json');
      final temp = File('${deviceDirectory.path}/state.pending.json');
      final backup = File('${deviceDirectory.path}/state.backup.json');
      await temp.writeAsString(encoded, flush: true);
      if (await target.exists()) {
        if (await backup.exists()) await backup.delete();
        await target.rename(backup.path);
      }
      await temp.rename(target.path);
    });
    _pending = next;
    return next;
  }
}
