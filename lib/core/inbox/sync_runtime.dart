part of 'inbox_controller.dart';

extension _SyncRuntime on InboxController {
  Future<void> _receivedChanges(String source) async {
    _changed();
    if (!automaticSync || _closed || lan.receivingPaused) return;
    // A NAS download can be the only route by which another bound device's
    // changes reach us. Forward durable unsent events, not receipt-only updates.
    for (final endpoint in endpoints.where((e) => e.key != source)) {
      var pending = true;
      try {
        pending = await _sync.hasPendingChanges(endpoint);
      } on Object {
        // Scheduling another route must not turn a committed receive into failure.
      }
      if (pending) {
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
                      _watches[e.key]?.connected != true &&
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
    final waiting = <Future<void>>[];
    for (final endpoint in endpoints.where(
      (e) =>
          _endpointAvailable(e) && (targets == null || targets.contains(e.key)),
    )) {
      final done = Completer<void>();
      (_syncWaiters[endpoint.key] ??= []).add(done);
      waiting.add(done.future);
      _pendingSync.add(endpoint.key);
      if (force) _forcedSync.add(endpoint.key);
    }
    if (waiting.isEmpty) return refreshTransfers();
    final completed = Future.wait(waiting).then<void>((_) {});
    _pumpSync();
    return completed;
  }

  void _pumpSync() {
    final available = {
      for (final e in endpoints.where(_endpointAvailable)) e.key: e,
    };
    for (final key in {..._pendingSync, ..._syncWaiters.keys}) {
      if (_closed ||
          lan.receivingPaused ||
          !available.containsKey(key) ||
          !_pendingSync.contains(key)) {
        _pendingSync.remove(key);
        _forcedSync.remove(key);
        for (final waiter in _syncWaiters.remove(key) ?? <Completer<void>>[]) {
          waiter.complete();
        }
      }
    }
    while (_syncJobs.length < 4) {
      final key = _pendingSync
          .where((key) => !_syncJobs.containsKey(key))
          .firstOrNull;
      if (key == null) break;
      _pendingSync.remove(key);
      final waiters = _syncWaiters.remove(key) ?? <Completer<void>>[];
      final force = _forcedSync.remove(key);
      final done = Completer<void>();
      _syncJobs[key] = done.future;
      _progress.start();
      unawaited(() async {
        try {
          await _syncEndpoint(available[key]!, force: force);
          await refreshTransfers();
          for (final waiter in waiters) {
            waiter.complete();
          }
        } on Object catch (error, stack) {
          for (final waiter in waiters) {
            waiter.completeError(error, stack);
          }
          if (waiters.isEmpty && !_closed) reportError('同步状态读取失败，请检查本机存储后重试');
        } finally {
          _syncJobs.remove(key);
          done.complete();
          _pumpSync();
          if (_syncJobs.isEmpty) _progress.stop();
          _scheduleRetry();
        }
      }());
    }
  }

  void _sampleTransferProgress() {
    // A slow read must not accumulate more reads behind it. Completion itself
    // always performs an awaited fresh read, regardless of the display cadence.
    if (_closed || _transferRefresh != null) return;
    unawaited(refreshTransfers().catchError((Object _) {}));
  }

  Future<void> _syncEndpoint(
    SyncEndpoint initialEndpoint, {
    required bool force,
  }) async {
    var endpoint = initialEndpoint;
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
    var connection = _connectionSignature(endpoint);
    _activityChanged();
    try {
      if (!endpoint.isHub &&
          (force ||
              status.failures > 0 ||
              _networkExchanged[endpoint.key] != connection)) {
        await lan.refreshDeviceNetwork(lan.peers[endpoint.id]!);
        final current = endpoints
            .where((e) => e.key == endpoint.key)
            .firstOrNull;
        if (current == null) return;
        endpoint = current;
        connection = _connectionSignature(endpoint);
        _networkExchanged[endpoint.key] = connection;
      }
      if (_closed || lan.receivingPaused || !_endpointAvailable(endpoint)) {
        return;
      }
      final pendingPull = _pendingPulls[endpoint.key];
      final result = await _sync.sync(endpoint, continuousFiles: automaticSync);
      if (!_connectionIsCurrent(endpoint, connection)) return;
      status.online = true;
      if (!endpoint.isHub) {
        lan.peers[endpoint.id]!
          ..online = true
          ..lastSeen = DateTime.now();
      }
      status.error = syncErrorMessage(
        result.error,
        result.errorCategory,
        isHub: endpoint.isHub,
      );
      status.errorCategory = result.errorCategory;
      status.needsAttention =
          result.error != null &&
          !retryableSyncCategories.contains(result.errorCategory);
      status.lastSuccess = DateTime.now();
      // Per-file failures have their own durable retry schedule. Keep
      // healthy metadata and unrelated attachments moving.
      status.failures = 0;
      status.retryAfter = result.retryAfter;
      if (!result.more && _pendingPulls[endpoint.key] == pendingPull) {
        _pendingPulls.remove(endpoint.key);
      }
      if (result.more && automaticSync) {
        _pendingSync.add(endpoint.key);
      }
    } on Object catch (e) {
      if (_closed) return;
      // Earlier metadata or another route may have committed before the
      // connection failed or was cancelled. Publish it even when paused.
      try {
        final previous = store.revision;
        await store.refresh();
        if (store.revision != previous) {
          await _receivedChanges(endpoint.key);
        }
      } on Object {
        /* Preserve the actual synchronization failure below. */
      }
      // A stale/cancelled request cannot change the replacement's status.
      if (!_connectionIsCurrent(endpoint, connection)) return;
      if (e is NativeCoreError && e.category == 'cancelled') return;
      final transient =
          e is SocketException ||
          e is TimeoutException ||
          (e is NativeCoreError && e.transient);
      status.needsAttention = !transient;
      status.errorCategory = e is NativeCoreError
          ? e.category
          : e is HandshakeException
          ? 'identity'
          : e is TimeoutException
          ? 'timeout'
          : transient
          ? 'offline'
          : 'unknown';
      status.online =
          _watches[endpoint.key]?.connected == true ||
          const {
            'busy',
            'paused',
            'not_ready',
            'source_pending',
          }.contains(status.errorCategory);
      if (!endpoint.isHub &&
          const {'offline', 'timeout'}.contains(status.errorCategory)) {
        lan.peers[endpoint.id]?.online = false;
      }
      status.error = syncErrorMessage(
        e is StateError
            ? e.message
            : e is FormatException
            ? e.message
            : '同步未完成，可稍后重试',
        status.errorCategory,
        isHub: endpoint.isHub,
      );
      status.failures = (status.failures + 1).clamp(1, 6);
      var retry = true;
      try {
        retry =
            await _sync.hasPendingChanges(endpoint) ||
            (_pendingPulls.containsKey(endpoint.key) &&
                (endpoint.isHub || status.errorCategory != 'offline'));
        // A direct peer announces/pushes when it returns. Retain its pull
        // request without polling when we have no outgoing work.
      } on Object {
        // A failed local read must not abandon accepted pending work.
      }
      if (!_connectionIsCurrent(endpoint, connection)) return;
      status.retryAfter = retry && transient
          ? DateTime.now().add(syncRetryDelay(status.failures))
          : null;
    } finally {
      _activeSynchronizations--;
      status.busy = false;
      _activityChanged();
    }
  }
}
