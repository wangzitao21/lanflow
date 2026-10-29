import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../network/models.dart';

class StorageLocation {
  StorageLocation(this.bootstrap);
  final Directory bootstrap;
  static const _locator = 'storage-location.json';
  static final _excluded = {
    for (final prefix in ['', 'system', '系统'])
      for (final name in [
        _locator,
        '$_locator.backup',
        '$_locator.pending',
        '$_locator.backup.pending',
      ])
        prefix.isEmpty ? name : p.join(prefix, name),
  };
  static const _dataDirectories = {
    'system',
    'media',
    'files',
    '系统',
    '媒体',
    '文件',
    'inbox',
    'received',
    'downloads',
  };
  File get _file => File(p.join(bootstrap.path, 'system', _locator));

  static const _databases = [
    'system/messages.sqlite3',
    '系统/messages.sqlite3',
    'inbox/messages.sqlite3',
    'messages.sqlite3',
    'inbox.sqlite3',
  ];
  static const _identities = [
    'system/device/identity.json',
    'system/设备/identity.json',
    '系统/device/identity.json',
    '系统/设备/identity.json',
    'identity.json',
  ];

  static Future<bool> _hasFile(Directory root, List<String> names) async {
    var found = false;
    for (final name in names) {
      final path = p.joinAll([root.path, ...name.split('/')]);
      final type = await FileSystemEntity.type(path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file) {
        throw FileSystemException('数据文件无法读取，原文件已保留', path);
      }
      found = true;
    }
    return found;
  }

  // Inspect without opening SQLite or creating a replacement device identity.
  static Future<bool> containsData(Directory root) async {
    await StorageLocation(root)._checkLocatorDirectory();
    final database = await _hasFile(root, _databases);
    final identity = await _hasFile(root, _identities);
    if (database && identity) return true;
    var partial =
        database ||
        identity ||
        await _hasFile(root, [
          'state.json',
          'state.backup.json',
          'system/device/state.json',
          'system/device/state.backup.json',
        ]);
    for (final name in _dataDirectories) {
      final directory = Directory(p.join(root.path, name));
      if (await FileSystemEntity.type(directory.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('数据目录包含链接，原文件已保留');
      }
      if (!await directory.exists()) continue;
      await for (final entry in directory.list(followLinks: false)) {
        final relative = p.relative(entry.path, from: root.path);
        if (!_excluded.contains(relative) &&
            relative != p.join('system', '.layout.lock')) {
          partial = true;
        }
      }
    }
    if (partial) {
      throw FileSystemException('所选位置的数据不完整，不能创建空白资料覆盖', root.path);
    }
    return false;
  }

  Future<Directory> resolve({
    Directory? initialRoot,
    Future<List<Directory>> Function()? recoveryRoots,
  }) async {
    await _checkLocatorDirectory();
    var hadLocator = false;
    for (final name in [
      p.join('system', _locator),
      p.join('system', '$_locator.backup'),
      p.join('系统', _locator),
      p.join('系统', '$_locator.backup'),
      _locator,
      '$_locator.backup',
    ]) {
      final file = File(p.join(bootstrap.path, name));
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) continue;
      if (type != FileSystemEntityType.file) {
        throw FileSystemException('存储位置配置无法读取，请保留原数据', file.path);
      }
      hadLocator = true;
      Map value;
      try {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map ||
            decoded['path'] is! String ||
            !p.isAbsolute(decoded['path'] as String) ||
            (decoded['initialized'] != null &&
                decoded['initialized'] is! bool)) {
          throw const FormatException('存储位置配置无效');
        }
        value = decoded;
      } on FormatException {
        continue;
      }
      final root = Directory(p.normalize(value['path'] as String));
      if (!await root.exists()) {
        throw FileSystemException('存储位置暂时不可用，请连接磁盘后重试', root.path);
      }
      if (initialRoot != null &&
          !p.equals(root.path, initialRoot.absolute.path)) {
        throw const FileSystemException('启动路径与已保存的存储位置不同，请在设置中更改位置');
      }
      final hasData = await containsData(root);
      if (value['initialized'] == true && !hasData) {
        throw FileSystemException('原存储位置的数据缺失，请恢复原数据后重试', root.path);
      }
      // Repair all copies, including a recovered backup, before opening data.
      await activate(root);
      await confirm();
      return root;
    }
    if (hadLocator) throw const FormatException('存储位置配置无法读取，请保留原数据');
    // An interrupted write is evidence of an earlier selection, not first use.
    for (final relative in _excluded.where(
      (name) => name.endsWith('.pending'),
    )) {
      if (await FileSystemEntity.type(p.join(bootstrap.path, relative)) !=
          FileSystemEntityType.notFound) {
        throw const FileSystemException('存储位置保存未完成，请恢复位置配置后重试');
      }
    }
    final candidates = <Directory>[];
    for (final candidate in [bootstrap, ...?await recoveryRoots?.call()]) {
      if (await containsData(candidate) &&
          !candidates.any(
            (known) => p.equals(known.absolute.path, candidate.absolute.path),
          )) {
        candidates.add(candidate);
      }
    }
    if (initialRoot != null &&
        !candidates.any(
          (known) => p.equals(known.absolute.path, initialRoot.absolute.path),
        )) {
      // An explicit first-run path is persisted in the normal configuration
      // directory, so removing the environment variable cannot switch datasets.
      await containsData(initialRoot);
      candidates.add(initialRoot);
    }
    if (candidates.length > 1) {
      throw const FileSystemException('发现多个数据位置，请确认原存储位置，原数据均已保留');
    }
    final root = candidates.isEmpty ? bootstrap : candidates.single;
    await root.create(recursive: true);
    await activate(root);
    await confirm();
    return root;
  }

  Future<void> activate(Directory root) async {
    await _checkLocatorDirectory();
    await _file.parent.create(recursive: true);
    final pending = File('${_file.path}.pending');
    final backup = File('${_file.path}.backup');
    await pending.writeAsString(
      jsonEncode({
        'path': p.normalize(root.absolute.path),
        'initialized':
            await _hasFile(root, _databases) &&
            await _hasFile(root, _identities),
      }),
      flush: true,
    );
    if (await _file.exists()) {
      if (await backup.exists()) await backup.delete();
      await _file.rename(backup.path);
    }
    try {
      await pending.rename(_file.path);
    } on Object {
      if (!await _file.exists() && await backup.exists()) {
        await backup.rename(_file.path);
      }
      rethrow;
    }
  }

  Future<void> confirm() async {
    await _checkLocatorDirectory();
    final pending = File('${_file.path}.backup.pending');
    await pending.writeAsString(await _file.readAsString(), flush: true);
    final backup = File('${_file.path}.backup');
    if (await backup.exists()) await backup.delete();
    await pending.rename(backup.path);
    // Keep another committed pair outside system/. Losing that directory must
    // not turn a previously selected disk into a fresh default installation.
    for (final name in [_locator, '$_locator.backup']) {
      final copy = File(p.join(bootstrap.path, name));
      final pendingCopy = File('${copy.path}.pending');
      await pendingCopy.writeAsString(await _file.readAsString(), flush: true);
      if (await copy.exists()) await copy.delete();
      await pendingCopy.rename(copy.path);
    }
    for (final prefix in ['系统']) {
      for (final name in [
        _locator,
        '$_locator.backup',
        '$_locator.pending',
        '$_locator.backup.pending',
      ]) {
        final old = File(p.join(bootstrap.path, prefix, name));
        if (await old.exists()) await old.delete();
      }
    }
    final oldSystem = Directory(p.join(bootstrap.path, '系统'));
    if (await oldSystem.exists() && await oldSystem.list().isEmpty) {
      await oldSystem.delete();
    }
  }

  Future<void> _checkLocatorDirectory() async {
    for (final path in [
      bootstrap.path,
      p.join(bootstrap.path, 'system'),
      p.join(bootstrap.path, '系统'),
    ]) {
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('数据目录包含链接，原文件已保留');
      }
    }
    for (final relative in _excluded) {
      if (await FileSystemEntity.type(
            p.join(bootstrap.path, relative),
            followLinks: false,
          ) ==
          FileSystemEntityType.link) {
        throw const FormatException('数据目录包含链接，原文件已保留');
      }
    }
  }

  Future<Directory> validate(
    Directory source,
    String destination, {
    bool allowExisting = false,
  }) async {
    if (!p.isAbsolute(destination)) throw const FormatException('请选择完整的存储路径');
    final requested = Directory(p.normalize(destination));
    if (await FileSystemEntity.type(requested.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('请选择实际文件夹，不要选择快捷方式或链接');
    }
    await requested.parent.create(recursive: true);
    final target = Directory(
      p.join(
        await requested.parent.resolveSymbolicLinks(),
        p.basename(requested.path),
      ),
    );
    if (await FileSystemEntity.type(target.path, followLinks: false) ==
        FileSystemEntityType.file) {
      throw const FormatException('所选位置已有文件，请选择空文件夹，原文件不会被覆盖');
    }
    final origin = await source.resolveSymbolicLinks();
    if (p.equals(origin, target.path) ||
        p.isWithin(origin, target.path) ||
        p.isWithin(target.path, origin)) {
      throw const FormatException('新位置必须与当前数据文件夹分开，不能互相包含');
    }
    if (!allowExisting &&
        await target.exists() &&
        !await target.list().isEmpty) {
      throw const FormatException('所选位置已有文件，请选择空文件夹，原文件不会被覆盖');
    }
    return target;
  }

  Future<StorageMove> prepare({
    required Directory source,
    required String destination,
    required bool migrate,
    void Function(int completed, int total)? onProgress,
  }) async {
    final target = await validate(source, destination);
    final id = randomToken(12);
    final stage = Directory('${target.path}.moving-$id');
    await stage.create();
    final move = StorageMove(source, target, stage, bootstrap, id, migrate);
    await File(
      p.join(stage.path, '.lanflow-move'),
    ).writeAsString(id, flush: true);
    try {
      if (migrate) {
        final files = <File>[];
        await for (final entity in source.list(
          recursive: true,
          followLinks: false,
        )) {
          final relative = p.relative(entity.path, from: source.path);
          if (_excluded.contains(relative) ||
              relative == p.join('system', '.layout.lock')) {
            continue;
          }
          final first = p.split(relative).first;
          if (!{
            ..._dataDirectories,
            'identity.json',
            'state.json',
            'state.backup.json',
            'state.pending.json',
          }.contains(first)) {
            continue;
          }
          if (entity is Link) {
            throw const FormatException('数据目录包含链接，迁移已取消，原数据保留');
          }
          if (entity is Directory) {
            await Directory(
              p.join(stage.path, relative),
            ).create(recursive: true);
          } else if (entity is File) {
            files.add(entity);
          }
        }
        var total = 0;
        for (final file in files) {
          total += await file.length();
        }
        var completed = 0;
        onProgress?.call(0, total);
        for (final file in files) {
          final relative = p.relative(file.path, from: source.path);
          final copy = File(p.join(stage.path, relative));
          await copy.parent.create(recursive: true);
          await file.copy(copy.path);
          final originalHash = await sha256.bind(file.openRead()).first;
          final copiedHash = await sha256.bind(copy.openRead()).first;
          if (originalHash != copiedHash) {
            throw const FileSystemException('迁移校验未通过，原数据保留');
          }
          move._files[relative] = originalHash.toString();
          completed += await file.length();
          onProgress?.call(completed, total);
        }
      }
      if (await target.exists()) {
        await target.delete(); // Only an empty, validated directory.
      }
      await stage.rename(target.path);
      move._prepared = true;
      return move;
    } on Object {
      await move.discard();
      rethrow;
    }
  }
}

class StorageMove {
  StorageMove(
    this.source,
    this.target,
    this.stage,
    this.bootstrap,
    this.id,
    this.migrate,
  );
  final Directory source, target, stage, bootstrap;
  final String id;
  final bool migrate;
  final Map<String, String> _files = {};
  bool _prepared = false;
  bool _activated = false;

  Future<void> discard() async {
    if (_activated) return;
    final owned = _prepared ? target : stage;
    final marker = File(p.join(owned.path, '.lanflow-move'));
    if (p.equals(owned.path, source.path) ||
        !await marker.exists() ||
        await marker.readAsString() != id) {
      return;
    }
    // This tree was created by this transaction; never recurse over source data.
    await owned.delete(recursive: true);
  }

  Future<bool> finish() async {
    _activated = true;
    final marker = File(p.join(target.path, '.lanflow-move'));
    if (await marker.exists()) await marker.delete();
    if (!migrate) return true;
    var removedAll = true;
    for (final entry in _files.entries) {
      final old = File(p.join(source.path, entry.key));
      try {
        if (await old.exists()) {
          if ((await sha256.bind(old.openRead()).first).toString() !=
              entry.value) {
            removedAll = false;
            continue;
          }
          await old.delete();
        }
      } on FileSystemException {
        removedAll = false;
      }
    }
    if (!await source.exists()) return removedAll;
    final directories = await source
        .list(recursive: true, followLinks: false)
        .where(
          (entry) =>
              entry is Directory &&
              StorageLocation._dataDirectories.contains(
                p.split(p.relative(entry.path, from: source.path)).first,
              ),
        )
        .cast<Directory>()
        .toList();
    directories.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final directory in directories) {
      try {
        if (await directory.list().isEmpty) await directory.delete();
      } on FileSystemException {
        removedAll = false;
      }
    }
    if (!p.equals(source.absolute.path, bootstrap.absolute.path)) {
      try {
        if (await source.list().isEmpty) await source.delete();
      } on FileSystemException {
        removedAll = false;
      }
    }
    return removedAll;
  }
}
