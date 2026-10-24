import 'dart:io';

import 'package:file_selector/file_selector.dart' as selector;
import 'package:flutter/services.dart';

/// Shared entry point for opening attachments. Windows uses the runner's STA
/// picker so shell initialization and its modal wait do not occupy Flutter's
/// platform thread; other platforms keep their supported selector backend.
class AppFilePicker {
  static const _channel = MethodChannel('lanflow/file_picker');
  static bool _opening = false;

  static Future<List<selector.XFile>> openFiles({
    List<selector.XTypeGroup> acceptedTypeGroups = const [],
    String? initialDirectory,
    String? confirmButtonText,
  }) => _open(
    multiple: true,
    acceptedTypeGroups: acceptedTypeGroups,
    initialDirectory: initialDirectory,
    confirmButtonText: confirmButtonText,
  );

  static Future<selector.XFile?> openFile({
    List<selector.XTypeGroup> acceptedTypeGroups = const [],
    String? initialDirectory,
    String? confirmButtonText,
  }) async => (await _open(
    multiple: false,
    acceptedTypeGroups: acceptedTypeGroups,
    initialDirectory: initialDirectory,
    confirmButtonText: confirmButtonText,
  )).firstOrNull;

  static Future<List<selector.XFile>> _open({
    required bool multiple,
    required List<selector.XTypeGroup> acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    // A duplicate click must not import the eventual selection twice.
    if (_opening) return const [];
    _opening = true;
    try {
      if (Platform.isWindows) {
        for (final group in acceptedTypeGroups) {
          if (!group.allowsAny && (group.extensions?.isEmpty ?? true)) {
            throw ArgumentError('Windows file types require extensions');
          }
        }
        try {
          final paths = await _channel.invokeListMethod<String>('openFiles', {
            'multiple': multiple,
            'initialDirectory': initialDirectory,
            'confirmButtonText': confirmButtonText,
            'filters': [
              for (final group in acceptedTypeGroups)
                {
                  'label': group.label ?? '',
                  'extensions': group.extensions ?? <String>[],
                },
            ],
          });
          return [for (final path in paths ?? <String>[]) selector.XFile(path)];
        } on MissingPluginException {
          // Test hosts and an older runner during development may not expose
          // the application channel. The normal platform backend still works.
        } on PlatformException catch (error) {
          if (error.code == 'PICKER_BUSY') return const [];
          rethrow;
        }
      }
      if (multiple) {
        return await selector.openFiles(
          acceptedTypeGroups: acceptedTypeGroups,
          initialDirectory: initialDirectory,
          confirmButtonText: confirmButtonText,
        );
      }
      final file = await selector.openFile(
        acceptedTypeGroups: acceptedTypeGroups,
        initialDirectory: initialDirectory,
        confirmButtonText: confirmButtonText,
      );
      return file == null ? const [] : [file];
    } finally {
      _opening = false;
    }
  }

  static Future<void> cancelOpenFiles() async {
    if (!Platform.isWindows || !_opening) return;
    try {
      await _channel.invokeMethod<void>('cancelOpenFiles');
    } on MissingPluginException {
      // Older platform backends expose only their own dialog Cancel button.
    }
  }
}
