import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../platform/native_core.dart';
import '../network/models.dart';
import 'storage_location.dart';

/// The caller suspends its session before creating a backup so device settings,
/// drafts, and attachments are captured alongside a consistent SQLite snapshot.
abstract final class StorageBackup {
  static const _manifest = 'lanflow-backup.json';
  static const _format = 'lanflow-backup';
  static const _maxFile = 100 * 1024 * 1024 * 1024;
  static const _maxManifest = 32 * 1024 * 1024;

  static Future<void> create(Directory source, String destination) async {
    if (!p.isAbsolute(destination)) throw const FormatException('请选择完整的备份路径');
    final file = File(destination);
    await file.parent.create(recursive: true);
    final target = File(
      p.join(await file.parent.resolveSymbolicLinks(), p.basename(file.path)),
    );
    final origin = await source.resolveSymbolicLinks();
    if (p.equals(origin, target.path) || p.isWithin(origin, target.path)) {
      throw const FormatException('请将备份保存到数据文件夹以外的位置');
    }
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FormatException('备份文件已存在，请选择新的文件名');
    }
    final temporary = await Directory(
      target.parent.path,
    ).createTemp('.lanflow-backup-');
    final pending = File(p.join(temporary.path, 'backup.zip'));
    final snapshot = File(p.join(temporary.path, 'messages.sqlite3'));
    try {
      await NativeCore.run({
        'op': 'backup_database',
        'root': source.path,
        'path': snapshot.path,
      });
      final sourcePath = source.path;
      final snapshotPath = snapshot.path;
      final pendingPath = pending.path;
      await Isolate.run(() => _encode(sourcePath, snapshotPath, pendingPath));
      final handle = await pending.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      // Recheck after the long write: an existing backup is never replaced.
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FormatException('备份文件已存在，请选择新的文件名');
      }
      await pending.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }

  static bool _included(String name) {
    final parts = name.split('/');
    if (!const {'system', 'media', 'files'}.contains(parts.first)) return false;
    if (parts.first != 'system') return true;
    if (parts.length == 2 &&
        (parts[1].startsWith('storage-location.json') ||
            parts[1] == '.layout.lock' ||
            parts[1].startsWith('messages.sqlite3'))) {
      return false;
    }
    if (name == 'system/cache' || name.startsWith('system/cache/')) {
      return name == 'system/cache/legacy_received' ||
          name.startsWith('system/cache/legacy_received/');
    }
    // Recovered external edits are user data, even when their original filename
    // ends in .tmp. Only internal working files should be excluded below.
    if (name.startsWith('system/recovered/')) return true;
    return !name.endsWith('.tmp');
  }

  static Future<void> _encode(
    String source,
    String snapshot,
    String destination,
  ) async {
    final files = <String, File>{'system/messages.sqlite3': File(snapshot)};
    await for (final entity in Directory(
      source,
    ).list(recursive: true, followLinks: false)) {
      final name = p.split(p.relative(entity.path, from: source)).join('/');
      if (!_included(name)) continue;
      if (entity is Link) throw const FormatException('数据目录包含链接，备份未完成');
      if (entity is File) files[name] = entity;
    }
    final manifest = <String, Object?>{
      'format': _format,
      'schema': 1,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'sourceRoot': Directory(source).absolute.path,
      'files': <String, Object?>{},
    };
    final entries = manifest['files'] as Map<String, Object?>;
    final encoder = ZipFileEncoder()
      ..create(destination, level: ZipFileEncoder.store);
    try {
      for (final entry in files.entries) {
        _safeName(entry.key);
        final size = await entry.value.length();
        if (size > _maxFile) throw const FormatException('备份中有超出大小限制的文件');
        final hash = await sha256.bind(entry.value.openRead()).first;
        entries[entry.key] = {'size': size, 'sha256': hash.toString()};
        await encoder.addFile(entry.value, entry.key, ZipFileEncoder.store);
      }
      encoder.addArchiveFile(
        ArchiveFile.string(_manifest, jsonEncode(manifest)),
      );
    } finally {
      await encoder.close();
    }
    // Detect external edits or truncated writes before publishing the backup.
    _readArchive(destination);
  }

  static Future<StorageRestore> restore({
    required String archivePath,
    required Directory source,
    required String destination,
    required StorageLocation location,
  }) async {
    final target = await location.validate(source, destination);
    final id = randomToken(12);
    final stage = Directory('${target.path}.restoring-$id');
    await stage.create();
    final restore = StorageRestore._(target, stage, id);
    await File(
      p.join(stage.path, '.lanflow-restore'),
    ).writeAsString(id, flush: true);
    try {
      final stagePath = stage.path;
      restore.sourceRoot = await Isolate.run(
        () => _readArchive(archivePath, stagePath),
      );
      await NativeCore.run({'op': 'verify_database', 'root': stage.path});
      if (await target.exists()) await target.delete();
      await stage.rename(target.path);
      restore._prepared = true;
      return restore;
    } on Object {
      await restore.discard();
      rethrow;
    }
  }

  static void _safeName(String name) {
    final parts = name.split('/');
    if (name.isEmpty ||
        name.contains('\\') ||
        name.contains(':') ||
        name.contains('\u0000') ||
        p.posix.isAbsolute(name) ||
        parts.any(
          (part) =>
              part.isEmpty ||
              part == '.' ||
              part == '..' ||
              part.endsWith('.') ||
              part.endsWith(' ') ||
              RegExp(
                r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
                caseSensitive: false,
              ).hasMatch(part),
        )) {
      throw const FormatException('备份包含无效路径，原数据保留');
    }
    if (name != _manifest &&
        !const {'system', 'media', 'files'}.contains(parts.first)) {
      throw const FormatException('备份包含未知的数据目录');
    }
  }

  static String _readArchive(String archivePath, [String? stage]) {
    final input = InputFileStream(archivePath);
    try {
      final directory = ZipDirectory()..read(input);
      final files = <String, ZipFile>{};
      final normalized = <String>{};
      if (directory.fileHeaders.length > 200000) {
        throw const FormatException('备份文件数量超出限制');
      }
      for (final header in directory.fileHeaders) {
        final name = header.filename;
        _safeName(name);
        final type = (header.externalFileAttributes >> 16) & 0xf000;
        if ((type != 0 && type != 0x8000) ||
            header.file == null ||
            header.file!.filename != name ||
            header.generalPurposeBitFlag & 1 != 0 ||
            !const {0, 8}.contains(header.compressionMethod) ||
            header.uncompressedSize < 0 ||
            header.uncompressedSize > _maxFile ||
            !normalized.add(name.toLowerCase())) {
          throw const FormatException('备份包含重复文件、链接或不支持的内容');
        }
        files[name] = header.file!;
      }
      final manifestFile = files.remove(_manifest);
      if (manifestFile == null ||
          manifestFile.uncompressedSize > _maxManifest) {
        throw const FormatException('不是有效的 LanFlow 备份');
      }
      final manifestOutput = OutputMemoryStream();
      manifestFile.decompress(manifestOutput);
      final manifest = jsonDecode(utf8.decode(manifestOutput.getBytes()));
      if (manifest is! Map ||
          manifest['format'] != _format ||
          manifest['schema'] != 1 ||
          manifest['sourceRoot'] is! String ||
          manifest['files'] is! Map) {
        throw const FormatException('备份格式不受支持');
      }
      final entries = manifest['files'] as Map;
      if (entries.length != files.length ||
          !entries.containsKey('system/messages.sqlite3') ||
          !entries.containsKey('system/device/identity.json') ||
          !entries.containsKey('system/device/state.json')) {
        throw const FormatException('备份缺少必要的数据');
      }
      for (final entry in files.entries) {
        final expected = entries[entry.key];
        if (expected is! Map ||
            expected['size'] != entry.value.uncompressedSize ||
            expected['sha256'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(expected['sha256'] as String)) {
          throw const FormatException('备份校验信息不完整');
        }
        OutputFileStream? file;
        if (stage != null) {
          final path = p.joinAll([stage, ...entry.key.split('/')]);
          if (!p.isWithin(stage, path)) throw const FormatException('备份包含无效路径');
          Directory(p.dirname(path)).createSync(recursive: true);
          file = OutputFileStream(path);
        }
        final output = _DigestOutput(entry.value.uncompressedSize, file);
        try {
          entry.value.decompress(output);
          if (output.finish() != expected['sha256']) {
            throw const FormatException('备份内容校验失败，原数据保留');
          }
        } finally {
          file?.closeSync();
        }
      }
      return manifest['sourceRoot'] as String;
    } finally {
      input.closeSync();
    }
  }
}

class StorageRestore {
  StorageRestore._(this.target, this.stage, this.id);
  final Directory target, stage;
  final String id;
  late final String sourceRoot;
  bool _prepared = false, _committed = false;

  Future<void> commit() async {
    _committed = true;
    final marker = File(p.join(target.path, '.lanflow-restore'));
    if (await marker.exists()) await marker.delete();
  }

  Future<void> discard() async {
    if (_committed) return;
    final owned = _prepared ? target : stage;
    final marker = File(p.join(owned.path, '.lanflow-restore'));
    if (await FileSystemEntity.type(owned.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        !await marker.exists() ||
        await marker.readAsString() != id) {
      return;
    }
    await owned.delete(recursive: true);
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _DigestOutput extends OutputStream {
  _DigestOutput(this.expected, this.output)
    : super(byteOrder: ByteOrder.littleEndian) {
    _hash = sha256.startChunkedConversion(_result);
  }
  final int expected;
  final OutputStream? output;
  final _result = _DigestSink();
  late final ByteConversionSink _hash;
  int _length = 0;
  @override
  int get length => _length;
  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final size = length ?? bytes.length;
    if (_length + size > expected) throw const FormatException('备份文件大小不符');
    final values = size == bytes.length ? bytes : bytes.sublist(0, size);
    _hash.add(values);
    output?.writeBytes(values);
    _length += size;
  }

  @override
  void writeByte(int value) => writeBytes([value]);
  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final bytes = stream.readBytes(64 * 1024).toUint8List();
      if (bytes.isEmpty) break;
      writeBytes(bytes);
    }
  }

  String finish() {
    _hash.close();
    if (_length != expected) throw const FormatException('备份文件不完整');
    return _result.value.toString();
  }

  @override
  void flush() => output?.flush();
  @override
  void clear() => throw UnsupportedError('A backup verifier cannot be reset');
  @override
  Uint8List subset(int start, [int? end]) =>
      throw UnsupportedError('A backup verifier does not buffer content');
}
