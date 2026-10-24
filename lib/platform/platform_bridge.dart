import 'dart:io';

import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import 'share_import_progress.dart';
import 'package:lanflow/core/network/network_state.dart';

enum ShareDisposition { sent, cancelled, deferred }

class PlatformBridge {
  static const _channel = MethodChannel('lanflow/platform');
  static const _clipboard = MethodChannel('lanflow/clipboard');
  static const _desktop = MethodChannel('lanflow/desktop');
  static Future<void> Function()? _prepareQuit;
  static Future<void> Function()? _fallbackQuit;
  static void setQuitHandler(
    Future<void> Function() handler, {
    bool fallback = false,
  }) {
    if (!Platform.isWindows) return;
    if (fallback) _fallbackQuit = handler;
    _prepareQuit = handler;
    _desktop.setMethodCallHandler((call) async {
      if (call.method != 'prepareToQuit') throw MissingPluginException();
      await prepareToQuit();
      return true;
    });
  }

  static Future<bool> prepareToQuit({
    Future<void> Function()? excluding,
  }) async {
    final handler = _prepareQuit;
    if (handler == null || identical(handler, excluding)) return false;
    await handler();
    return true;
  }

  static void clearQuitHandler(Future<void> Function() handler) {
    if (identical(_prepareQuit, handler)) _prepareQuit = _fallbackQuit;
  }

  static Future<void> setLanguage(String language) async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    await (Platform.isWindows ? _desktop : _channel).invokeMethod<void>(
      'setLanguage',
      language == 'en' ? 'en' : 'zh',
    );
  }

  static Future<void> setSyncPaused(bool paused) async {
    if (!Platform.isWindows && !Platform.isAndroid) return;
    await (Platform.isWindows ? _desktop : _channel).invokeMethod<void>(
      'setSyncPaused',
      paused,
    );
  }

  static Future<void> setDarkMode(bool dark) async {
    if (Platform.isWindows) {
      await _desktop.invokeMethod<void>('setDarkMode', dark);
    }
  }

  static Future<void> hideToTray() async {
    if (Platform.isWindows) await _desktop.invokeMethod<void>('hideToTray');
  }

  static Future<void> openUrl(String value) async {
    final uri = Uri.tryParse(
      value.startsWith('www.') ? 'https://$value' : value,
    );
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty) {
      throw const FormatException('链接地址无效');
    }
    await (Platform.isWindows ? _desktop : _channel).invokeMethod<void>(
      'openUrl',
      uri.toString(),
    );
  }

  static Future<void> showInFolder(String path) async {
    await (Platform.isWindows ? _desktop : _channel).invokeMethod<void>(
      'showInFolder',
      path,
    );
  }

  static Future<void> openFile(String path) async {
    if (Platform.isWindows) {
      await _desktop.invokeMethod<void>('openFile', path);
      return;
    }
    final result = await OpenFilex.open(path);
    if (result.type != ResultType.done) {
      throw const FileSystemException('暂时无法打开，请另存文件后选择应用');
    }
  }

  static Future<Uint8List?> readClipboardImage() async {
    if (!Platform.isWindows) return null;
    return _clipboard.invokeMethod<Uint8List>('readImage');
  }

  static Future<void> Function(Map<String, dynamic>)? _onShare;
  static void Function(bool)? onNetworkChanged;
  static void Function(NetworkState)? onNetworkStateChanged;
  static bool _networkStateSupported = false;
  static int _networkEvent = 0;

  static Future<void> requestDiscoveryWindow({
    Duration duration = const Duration(seconds: 5),
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('requestDiscoveryWindow', {
        'duration': duration.inMilliseconds,
      });
    } on MissingPluginException {
      // Older native hosts manage their own discovery lock.
    } on PlatformException {
      // Manual addresses and unicast delivery remain available.
    }
  }

  static Future<void> setForeground(bool foreground) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('setForeground', foreground);
    } on MissingPluginException {
      /* Older native hosts have no power hints. */
    }
  }

  static Future<ShareDisposition> Function(
    Map<String, dynamic>,
    Future<void> Function(Map<String, dynamic>),
  )?
  presentShare;

  static Future<void> returnToShareSource() async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('returnToShareSource');
    }
  }

  static void Function(Object)? _onShareError;
  static bool _draining = false;
  static bool _again = false;
  static bool _sharesPaused = false;
  static final shareImports = ShareImportTracker();

  static void _shareProgress(ShareImportProgress progress) =>
      shareImports.update(progress);

  static Future<bool> cancelShare(String id) async {
    final cancelled =
        await _channel.invokeMethod<bool>('cancelShare', id) ?? false;
    if (cancelled) {
      _shareProgress(ShareImportProgress(id: id, phase: 'cancelled'));
    }
    return cancelled;
  }

  static Future<void> suspendShares() async {
    _sharesPaused = true;
    while (_draining) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _onShare = null;
  }

  static Future<void> listenShares(
    Future<void> Function(Map<String, dynamic>) onShare,
    void Function(Object) onError,
  ) async {
    if (!Platform.isAndroid) return;
    _sharesPaused = false;
    _onShare = onShare;
    _onShareError = onError;
    final updatesDuringSnapshot = shareImports.beginSnapshot();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'networkStateChanged' && call.arguments is Map) {
        _networkEvent++;
        _networkStateSupported = true;
        onNetworkStateChanged?.call(
          NetworkState.fromMap(call.arguments as Map),
        );
      }
      if (call.method == 'networkChanged' && !_networkStateSupported) {
        _networkEvent++;
        onNetworkChanged?.call(call.arguments == true);
      }
      if (call.method == 'sharesChanged') await drainShares();
      if (call.method == 'shareProgress' && call.arguments is Map) {
        final progress = ShareImportProgress.fromJson(call.arguments as Map);
        _shareProgress(progress);
      }
      if (call.method == 'shareError') {
        _onShareError?.call(StateError(call.arguments as String));
      }
    });
    await _readNetworkState();
    try {
      final progress =
          await _channel.invokeListMethod<dynamic>('getShareProgress') ?? [];
      for (final item in progress.whereType<Map>()) {
        final progress = ShareImportProgress.fromJson(item);
        if (!updatesDuringSnapshot.contains(progress.id)) {
          _shareProgress(progress);
        }
      }
    } on MissingPluginException {
      // Older native hosts still support durable share delivery.
    } on PlatformException catch (error) {
      _onShareError?.call(error);
    } finally {
      shareImports.endSnapshot(updatesDuringSnapshot);
    }
    await drainShares();
  }

  static Future<void> _readNetworkState() async {
    final event = _networkEvent;
    try {
      final state = await _channel.invokeMapMethod<dynamic, dynamic>(
        'getNetworkState',
      );
      if (state != null) {
        _networkStateSupported = true;
        if (event == _networkEvent) {
          onNetworkStateChanged?.call(NetworkState.fromMap(state));
        }
        return;
      }
    } on MissingPluginException {
      // Fall back to the original bridge on older native hosts.
    }
    if (_networkStateSupported) return;
    try {
      final available = await _channel.invokeMethod<bool>(
        'getNetworkAvailable',
      );
      if (event == _networkEvent && available != null) {
        onNetworkChanged?.call(available);
      }
    } on MissingPluginException {
      // Older hosts report network changes on resume.
    }
  }

  static Future<void> drainShares() async {
    if (_sharesPaused) return;
    if (!Platform.isAndroid || _onShare == null || presentShare == null) return;
    if (_draining) {
      _again = true;
      return;
    }
    _draining = true;
    final deferred = <String>{};
    try {
      do {
        _again = false;
        final pending =
            await _channel.invokeListMethod<dynamic>('getPendingShares') ?? [];
        for (final value in pending) {
          if (_sharesPaused) break;
          final payload = Map<String, dynamic>.from(value as Map);
          final id = payload['id'] as String;
          if (deferred.contains(id)) continue;
          _shareProgress(ShareImportProgress(id: id, phase: 'saving'));
          try {
            var disposition = ShareDisposition.cancelled;
            if (payload['error'] != null) {
              _onShareError?.call(StateError(payload['error'] as String));
            } else {
              disposition = await presentShare!(payload, (chosen) async {
                // Record the destination before the first item is committed.
                // Retrying a partial import therefore keeps the same conversation.
                await _channel.invokeMethod<void>('saveShareTarget', {
                  'id': id,
                  'conversationId': chosen['conversationId'],
                  'comment': chosen['comment'] ?? '',
                });
                await _onShare!(chosen);
                await _channel.invokeMethod<void>('ackShare', id);
                _shareProgress(ShareImportProgress(id: id, phase: 'completed'));
              });
            }
            if (disposition == ShareDisposition.deferred) {
              deferred.add(id);
              continue;
            }
            // Native source copies are deleted only after the durable inbox commit.
            await _channel.invokeMethod<void>('ackShare', payload['id']);
            _shareProgress(
              ShareImportProgress(
                id: id,
                phase: disposition == ShareDisposition.sent
                    ? 'completed'
                    : 'cancelled',
              ),
            );
          } on Object catch (e) {
            _onShareError?.call(e);
            _shareProgress(ShareImportProgress(id: id, phase: 'failed'));
          }
        }
      } while (_again);
    } on Object catch (e) {
      _onShareError?.call(e);
    } finally {
      _draining = false;
    }
  }

  static Future<void> startReceiver() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('startReceiver');
  }

  static Future<void> setTransferring(bool active) async {
    if (Platform.isAndroid) {
      await _channel.invokeMethod<void>('setTransferring', active);
    }
  }

  static Future<void> stopReceiver() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('stopReceiver');
  }

  static Future<bool> exportFile(String path, String name) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('exportFile', {
          'path': path,
          'name': name,
        }) ??
        false;
  }
}
