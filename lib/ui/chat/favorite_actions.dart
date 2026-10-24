import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:lanflow/core/files/message_export.dart';
import 'package:lanflow/core/inbox/inbox_controller.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/platform/platform_bridge.dart';

class FavoriteActions {
  const FavoriteActions(this.inbox, {this.openAttachment});
  final InboxController inbox;
  final Future<void> Function(File file)? openAttachment;

  Future<void> copy(FavoriteEntry entry) => Clipboard.setData(
    ClipboardData(text: entry.item.isFile ? entry.item.name : entry.item.text),
  );

  Future<void> openFile(FavoriteEntry entry) async {
    final file = await inbox.favoriteFileForOpening(entry);
    if (openAttachment != null) return openAttachment!(file);
    await PlatformBridge.openFile(file.path);
  }

  Future<bool> saveFile(FavoriteEntry entry) async {
    final original = await inbox.favoriteFileForExport(entry);
    if (Platform.isAndroid) {
      return PlatformBridge.exportFile(original.path, entry.item.name);
    }
    final destination = await getSaveLocation(suggestedName: entry.item.name);
    if (destination == null) return false;
    await original.copy(destination.path);
    return true;
  }

  Future<bool> export(Iterable<FavoriteEntry> favorites) async {
    final entries = favorites.toList();
    if (entries.isEmpty) return false;
    String? destination;
    if (!Platform.isAndroid) {
      destination = (await getSaveLocation(
        suggestedName: 'LanFlow-favorites.zip',
      ))?.path;
      if (destination == null) return false;
    }
    final temporary = await Directory.systemTemp.createTemp(
      'lanflow-favorites-export-',
    );
    try {
      final records = <Map<String, dynamic>>[];
      for (final entry in entries) {
        records.add({
          ...entry.item.toJson(),
          'originalMessageId': entry.originalMessageId,
          'savedAt': entry.savedAt.toUtc().toIso8601String(),
          if (entry.item.isFile)
            'sourcePath': (await inbox.favoriteFileForExport(entry)).path,
        });
      }
      final archive = await exportMessages(records, temporary);
      if (Platform.isAndroid) {
        return await PlatformBridge.exportFile(
          archive.path,
          'LanFlow-favorites.zip',
        );
      }
      await archive.copy(destination!);
      return true;
    } finally {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    }
  }
}
