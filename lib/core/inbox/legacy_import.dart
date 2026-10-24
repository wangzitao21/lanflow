part of 'inbox_controller.dart';

// Import saved history and content arriving from older paired devices.
extension _LegacyImport on InboxController {
  Future<void> _migrateLegacy() {
    if (_closed || !ready || !lan.ready) return Future.value();
    _migrateAgain = true;
    if (_legacyImportTask != null) return _legacyImportTask!;
    final task = _trackLocal(_importLegacy);
    _legacyImportTask = task;
    return task.whenComplete(() => _legacyImportTask = null);
  }

  Future<void> _importLegacy() async {
    if (_closed || _migrating || !ready || !lan.ready) return;
    _migrating = true;
    var changed = false;
    var failed = false;
    try {
      do {
        _migrateAgain = false;
        for (final message in lan.messages.toList()) {
          if (_closed) return;
          final legacyKey = '${message.id}:${message.outgoing}';
          if (store.migrated.contains(legacyKey)) continue;
          if (message.kind != MessageKind.text &&
              message.delivery != Delivery.complete) {
            continue;
          }
          final id = sha256
              .convert(utf8.encode('legacy:${lan.identity.id}:$legacyKey'))
              .toString();
          if (await store.loadEntry(id) == null) {
            var digest = '';
            if (message.kind != MessageKind.text) {
              if (message.path == null || !await File(message.path!).exists()) {
                continue;
              }
              final file = File(message.path!);
              digest = await store.storeBlob(
                file.openRead(),
                await file.length(),
              );
            }
            await store.add(
              InboxItem(
                id: id,
                originId: message.outgoing ? lan.identity.id : message.peerId,
                originName: message.outgoing
                    ? lan.name
                    : lan.peers[message.peerId]?.name ?? '我的设备',
                createdAt: message.createdAt,
                kind: message.kind,
                text: message.text,
                name: message.name,
                size: message.size,
                digest: digest,
              ),
            );
            changed = true;
          }
          store.migrated.add(legacyKey);
          await store.save();
        }
      } while (_migrateAgain && !_closed);
    } on Object catch (e) {
      error = '旧记录导入未完成：$e';
      failed = true;
    } finally {
      _migrating = false;
      if (changed || failed) _changed();
      if (changed && automaticSync) requestSync();
    }
  }
}
