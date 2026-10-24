import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'inbox_api.dart';
import 'inbox_models.dart';
import 'sync_retry_policy.dart';

/// Holds an authenticated request until the peer commits a content change.
/// Idle renewals do not fetch history or change the visible sync state.
class SyncWatch {
  SyncWatch({
    required this.endpoint,
    required this.onChange,
    required this.onConnection,
    required this.onUnsupported,
    this.isForeground,
  });

  final SyncEndpoint endpoint;
  final void Function() onChange;
  final void Function(bool online, Object? error) onConnection;
  final void Function() onUnsupported;
  final bool Function()? isForeground;
  final _closed = Completer<void>();
  HttpClient? _client;
  Timer? _reconnect;
  bool connected = false;

  void close() {
    if (_closed.isCompleted) return;
    _closed.complete();
    connected = false;
    _reconnect?.cancel();
    _client?.close(force: true);
  }

  Future<void> run() async {
    var cursor = -1;
    var failures = 0;
    while (!_closed.isCompleted) {
      final client =
          HttpClient(context: SecurityContext(withTrustedRoots: false))
            ..connectionTimeout = const Duration(seconds: 5)
            ..badCertificateCallback = (certificate, _, _) =>
                sha256.convert(certificate.der).toString() ==
                endpoint.fingerprint;
      _client = client;
      try {
        var handshake = true;
        var waitForChange = false;
        while (!_closed.isCompleted) {
          final hold = isForeground?.call() == false ? 120 : 25;
          final request = await client.getUrl(
            endpoint.url.resolve(
              '/v3/watch?after=${handshake ? -1 : cursor}'
              '&wait=${!handshake && waitForChange ? 'change' : hold}',
            ),
          );
          request.followRedirects = false;
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${endpoint.token}',
          );
          if (endpoint.deviceId != null) {
            request.headers.set('X-Lanflow-Device', endpoint.deviceId!);
          }
          final pending = request.close();
          // New NAS versions hold the request until content actually changes.
          // Older versions retain their bounded long-poll compatibility path.
          final response = !handshake && waitForChange
              ? await pending
              : await pending.timeout(Duration(seconds: hold + 10));
          if (_closed.isCompleted) return;
          if (response.statusCode == 404 || response.statusCode == 405) {
            onUnsupported();
            return;
          }
          final value = await readInboxJson(response, limit: 4096);
          if (_closed.isCompleted) return;
          if (response.statusCode == 401 || response.statusCode == 403) {
            connected = false;
            onConnection(false, StateError('连接已失效，请重新配对'));
            return;
          }
          if (response.statusCode != 200 || value['cursor'] is! int) {
            throw const FormatException('无法接收设备通知');
          }
          final next = value['cursor'] as int;
          final changed = next != cursor;
          cursor = next;
          waitForChange = value['waitForChange'] == true;
          handshake = false;
          failures = 0;
          connected = true;
          onConnection(true, null);
          if (changed) onChange();
        }
      } on Object catch (error) {
        if (_closed.isCompleted) return;
        connected = false;
        onConnection(false, error);
        // Reconnect only the notification channel, with a capped backoff.
        // This never starts repeated full synchronizations while offline.
        failures = (failures + 1).clamp(1, 6);
        final resumed = Completer<void>();
        _reconnect = Timer(syncRetryDelay(failures), resumed.complete);
        await Future.any([resumed.future, _closed.future]);
        _reconnect = null;
      } finally {
        client.close(force: true);
        if (identical(_client, client)) _client = null;
      }
    }
  }
}
