import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:lanflow/core/inbox/inbox_api.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/platform/native_core.dart';

class InboxSync {
  InboxSync(
    this.store,
    this.onChange, {
    Future<dynamic> Function(Map<String, dynamic>) invoke = NativeCore.run,
  }) : _invoke = invoke;
  final InboxStore store;
  final Future<void> Function(String endpoint) onChange;
  final Future<dynamic> Function(Map<String, dynamic>) _invoke;
  bool _closed = false;
  final Map<String, int> _generations = {};
  final Map<String, Future<void>> _cancellations = {};
  final Map<String, String> _activeRuns = {};

  Future<void> interruptTransfers(String key) async {
    final run = _activeRuns[key];
    if (run == null) return;
    await _invoke({
      'op': 'interrupt_sync_transfer',
      'root': store.directory.path,
      'key': key,
      'runId': run,
    });
  }

  Future<bool> hasPendingChanges(SyncEndpoint endpoint) async =>
      await _invoke({
            'op': 'sync_pending',
            'root': store.directory.path,
            'key': endpoint.key,
          })
          as bool;

  Future<void> cancel(String key) async {
    _generations[key] = (_generations[key] ?? 0) + 1;
    final previous = _cancellations[key];
    final cancellation = () async {
      if (previous != null) await previous.catchError((Object _) {});
      await _invoke({
        'op': 'cancel_sync',
        'root': store.directory.path,
        'key': key,
      });
    }();
    _cancellations[key] = cancellation;
    try {
      await cancellation;
    } finally {
      if (identical(_cancellations[key], cancellation)) {
        _cancellations.remove(key);
      }
    }
  }

  Future<Map<String, dynamic>> probe(SyncEndpoint endpoint) async {
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 3)
      ..badCertificateCallback = (cert, _, _) =>
          sha256.convert(cert.der).toString() == endpoint.fingerprint;
    try {
      final request = await client.getUrl(endpoint.url.resolve('/v2/info'));
      request.followRedirects = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer ${endpoint.token}',
      );
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final data = await readInboxJson(response);
      if (response.statusCode != 200) {
        throw StateError(data['error'] as String? ?? 'NAS 暂时不可用');
      }
      return data;
    } finally {
      client.close(force: true);
    }
  }

  Future<
    ({bool more, String? error, String? errorCategory, DateTime? retryAfter})
  >
  sync(SyncEndpoint endpoint, {bool continuousFiles = false}) async {
    final generation = _generations[endpoint.key] ?? 0;
    void check() {
      if (_closed || generation != (_generations[endpoint.key] ?? 0)) {
        throw NativeCoreError('同步已取消', 499, 'cancelled');
      }
    }

    check();
    // Native cancel uses a different isolate from begin_sync. Drain every
    // earlier cancellation before starting a replacement on the same endpoint.
    final cancellation = _cancellations[endpoint.key];
    if (cancellation != null) await cancellation;
    check();
    final runId = await _invoke({
      'op': 'begin_sync',
      'root': store.directory.path,
      'key': endpoint.key,
    });
    check();
    _activeRuns[endpoint.key] = runId as String;
    final state =
        await _invoke({
              'op': 'sync',
              'root': store.directory.path,
              'knownRevision': store.revision,
              'runId': runId,
              'continuousFiles': continuousFiles,
              'endpoint': {
                ...endpoint.toJson(),
                'key': endpoint.key,
                if (endpoint.deviceId != null) 'deviceId': endpoint.deviceId,
              },
            }).whenComplete(() {
              if (_activeRuns[endpoint.key] == runId) {
                _activeRuns.remove(endpoint.key);
              }
            })
            as Map;
    check();
    final previous = store.revision;
    store.applySnapshot(Map<String, dynamic>.from(state));
    if (store.revision != previous) await onChange(endpoint.key);
    return (
      more: state['moreTransfers'] == true || state['moreChanges'] == true,
      error: state['transferError'] as String?,
      errorCategory: state['transferErrorCategory'] as String?,
      retryAfter: state['nextRetry'] is int
          ? DateTime.fromMillisecondsSinceEpoch(
              (state['nextRetry'] as int) * 1000,
            )
          : null,
    );
  }

  Future<void> close() async {
    _closed = true;
    await Future.wait(
      _cancellations.values.map((pending) => pending.catchError((Object _) {})),
    );
    await _invoke({'op': 'cancel_sync', 'root': store.directory.path});
  }
}
