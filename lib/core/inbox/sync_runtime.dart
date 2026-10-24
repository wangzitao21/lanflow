part of 'inbox_controller.dart';

extension _SyncRuntime on InboxController {
  Future<void> _receivedChanges(String source) async {
    _changed();
    if (!automaticSync || _closed || lan.receivingPaused) return;
    // A NAS download can be the only route by which another bound device's
    // changes reach us. Forward durable unsent events, not receipt-only updates.
    for (final endpoint in endpoints.where((e) => e.key != source)) {
      if (await _sync.hasPendingChanges(endpoint)) {
        requestSync(endpoint: endpoint.key);
      }
    }
  }

  void _scheduleRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!automaticSync ||
        _closed ||
        lan.receivingPaused ||
        !_networkAvailable) {
      return;
    }
    final available = endpoints
        .where(_endpointAvailable)
        .map((e) => e.key)
        .toSet();
    final times =
        statuses.entries
            .where(
              (e) =>
                  available.contains(e.key) &&
                  e.value.retryAfter != null &&
                  !(_watches.containsKey(e.key) &&
                      e.value.notificationsSupported != false &&
                      const {
                        'offline',
                        'timeout',
                      }.contains(e.value.errorCategory)),
            )
            .map((e) => e.value.retryAfter!)
            .toList()
          ..sort();
    if (times.isEmpty) return;
    final delay = times.first.difference(DateTime.now());
    _retryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _retryTimer = null;
      final now = DateTime.now();
      for (final entry in statuses.entries) {
        final retry = entry.value.retryAfter;
        if (retry != null &&
            !retry.isAfter(now) &&
            available.contains(entry.key)) {
          entry.value.retryAfter = null;
          requestSync(endpoint: entry.key);
        }
      }
      _scheduleRetry();
    });
  }

  Future<void> _runSync({required bool force, Set<String>? targets}) {
    if (_closed ||
        !ready ||
        !lan.ready ||
        lan.receivingPaused ||
        !_networkAvailable) {
      return Future.value();
    }
    if (_running != null) {
      if (targets != null && targets.isNotEmpty) {
        _pendingSync.addAll(targets);
        _syncAgain = true;
      }
      return _running!;
    }
    _progress.start();
    final task = _syncAll(force: force, selected: targets);
    _running = task;
    return task.whenComplete(() {
      _running = null;
      _progress.stop();
      if (_syncAgain && !_closed) {
        _syncAgain = false;
        if (_pendingSync.isNotEmpty) {
          requestSync(endpoint: _pendingSync.first, immediate: true);
        }
      }
      _scheduleRetry();
    });
  }

  void _sampleTransferProgress() {
    // A slow read must not accumulate more reads behind it. Completion itself
    // always performs an awaited fresh read, regardless of the display cadence.
    if (_closed || _transferRefresh != null) return;
    unawaited(refreshTransfers().catchError((Object _) {}));
  }

  Future<void> _syncAll({required bool force, Set<String>? selected}) async {
    final targets = endpoints
        .where(
          (endpoint) =>
              _endpointAvailable(endpoint) &&
              (selected == null || selected.contains(endpoint.key)),
        )
        .toList();
    // Keep one offline NAS from blocking other locations or local devices.
    for (
      var offset = 0;
      offset < targets.length && !_closed && !lan.receivingPaused;
      offset += 4
    ) {
      await Future.wait(
        targets.skip(offset).take(4).map((endpoint) async {
          if (_closed ||
              lan.receivingPaused ||
              !_endpointAvailable(endpoint) ||
              !_connectionIsCurrent(endpoint, _connectionSignature(endpoint))) {
            return;
          }
          final status = statuses.putIfAbsent(endpoint.key, SyncStatus.new);
          if (!force &&
              status.failures > 0 &&
              status.retryAfter != null &&
              DateTime.now().isBefore(status.retryAfter!)) {
            return;
          }
          status.busy = true;
          _activeSynchronizations++;
          status.retryAfter = null;
          final connection = _connectionSignature(endpoint);
          _activityChanged();
          try {
            final result = await _sync.sync(endpoint);
            if (!_connectionIsCurrent(endpoint, connection)) return;
            status.online = true;
            if (!endpoint.isHub) {
              lan.peers[endpoint.id]!
                ..online = true
                ..lastSeen = DateTime.now();
            }
            status.error = result.error;
            status.errorCategory = result.errorCategory;
            status.needsAttention =
                result.error != null &&
                !const {
                  'offline',
                  'timeout',
                  'busy',
                }.contains(result.errorCategory);
            status.lastSuccess = DateTime.now();
            // Per-file failures have their own durable retry schedule. Keep
            // healthy metadata and unrelated attachments moving.
            status.failures = 0;
            status.retryAfter = result.retryAfter;
            if (result.more && automaticSync) {
              _pendingSync.add(endpoint.key);
              _syncAgain = true;
            }
          } on Object catch (e) {
            // Discovery may have replaced this endpoint while its request was
            // in flight. A stale failure must not delay the replacement.
            if (!_connectionIsCurrent(endpoint, connection)) return;
            if (e is NativeCoreError && e.category == 'cancelled') return;
            status.online = _watches[endpoint.key]?.connected == true;
            final transient =
                e is SocketException ||
                e is TimeoutException ||
                (e is NativeCoreError && e.transient);
            if (transient && !endpoint.isHub) {
              lan.peers[endpoint.id]?.online = false;
            }
            status.needsAttention = !transient;
            status.errorCategory = e is NativeCoreError
                ? e.category
                : transient
                ? 'offline'
                : 'unknown';
            status.error =
                e is NativeCoreError && e.category == 'authentication'
                ? '连接已失效，请重新配对'
                : transient
                ? '设备离线'
                : e is HandshakeException
                ? '连接身份校验失败，请检查 NAS 连接码'
                : e is StateError
                ? e.message
                : e is FormatException
                ? e.message
                : '同步未完成，可稍后重试';
            status.failures = (status.failures + 1).clamp(1, 6);
            var retry =
                !(e is NativeCoreError && e.category == 'authentication');
            if (retry) {
              try {
                retry = await _sync.hasPendingChanges(endpoint);
              } on Object {
                // A failed local read must not abandon accepted pending work.
              }
            }
            if (!_connectionIsCurrent(endpoint, connection)) return;
            status.retryAfter = retry
                ? DateTime.now().add(syncRetryDelay(status.failures))
                : null;
          } finally {
            _activeSynchronizations--;
            status.busy = false;
            _activityChanged();
          }
        }),
      );
    }
    await refreshTransfers();
  }
}
