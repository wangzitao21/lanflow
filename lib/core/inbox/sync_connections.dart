part of 'inbox_controller.dart';

// Network policy and peer notification lifecycles are separate from running
// transfers. These handlers react immediately to events and schedule no polls.
extension _SyncConnections on InboxController {
  void _setForeground(bool value) {
    final resumed = value && !_foreground;
    _foreground = value;
    _progress.setForeground(value);
    lan.setForeground(value);
    if (resumed) {
      // A quiet NAS socket can have been lost while the device was asleep.
      // Re-establish it on this user event instead of adding idle heartbeats.
      for (final watch in _watches.values) {
        watch.close();
      }
      _watches.clear();
      _updateWatches();
    }
  }

  void _setNetworkAvailable(bool value) {
    if (_networkAvailable == value) return;
    _networkAvailable = value;
    lan.setNetworkAvailable(value);
    if (!value) {
      for (final status in statuses.values) {
        status.online = false;
      }
      _activityChanged();
      _kick?.cancel();
      _kick = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      for (final watch in _watches.values) {
        watch.close();
      }
      _watches.clear();
      for (final endpoint in endpoints) {
        unawaited(_sync.cancel(endpoint.key).catchError((Object _) {}));
      }
    } else {
      for (final status in statuses.values) {
        status.retryAfter = null;
        status.failures = 0;
      }
      _updateWatches();
      if (automaticSync) requestSync(immediate: true);
    }
  }

  void _setNetworkState(NetworkState state) {
    if (_networkState.sameNetwork(state) &&
        _networkAvailable == state.available) {
      return;
    }
    final routeChanged = _networkState.fingerprint != state.fingerprint;
    _networkState = state;
    // Apply a rich snapshot once. The legacy boolean handler also reconnects
    // watches/cancels work, so calling it here would repeat both side effects.
    _networkAvailable = state.available;
    lan.setNetworkAvailable(state.canDiscover);
    for (final watch in _watches.values) {
      watch.close();
    }
    _watches.clear();
    if (!state.available) {
      _kick?.cancel();
      _kick = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      for (final status in statuses.values) {
        status.online = false;
      }
    }
    for (final endpoint in endpoints) {
      final available = _endpointAvailable(endpoint);
      final status = statuses[endpoint.key];
      if (!available) {
        status?.online = false;
        _pendingSync.remove(endpoint.key);
      } else {
        status?.retryAfter = null;
        status?.failures = 0;
      }
      if (status?.busy == true && (!available || routeChanged)) {
        // A reachable endpoint can still have a socket on the previous network.
        // Abort it now; requestSync below queues delivery on the new route and
        // InboxSync waits for this cancellation before starting the replacement.
        unawaited(_sync.cancel(endpoint.key).catchError((Object _) {}));
      }
    }
    _activityChanged();
    _updateWatches();
    _scheduleRetry();
    if (automaticSync && state.available) requestSync(immediate: true);
    if (state.canDiscover) unawaited(lan.refresh().catchError((Object _) {}));
  }

  bool _endpointAvailable(SyncEndpoint endpoint) =>
      _networkAvailable && _networkState.canReach(endpoint.url);

  String _connectionSignature(SyncEndpoint endpoint) {
    final peer = endpoint.isHub ? null : lan.peers[endpoint.id];
    return '${endpoint.url}:${endpoint.token}:${endpoint.fingerprint}:'
        '${peer?.instanceId}';
  }

  bool _connectionIsCurrent(SyncEndpoint endpoint, String signature) {
    final current = endpoints.where((e) => e.key == endpoint.key).firstOrNull;
    return current != null && _connectionSignature(current) == signature;
  }

  void _updateWatches() {
    if (!automaticSync || !ready || _closed || !_networkAvailable) return;
    // Devices push their own changes directly. Only a NAS needs a notification
    // subscription: it cannot initiate a connection back to a sleeping client.
    final targets = {
      for (final endpoint in endpoints.where(
        (e) => e.isHub && _endpointAvailable(e),
      ))
        endpoint.key: endpoint,
    };
    for (final key in _watches.keys.toList()) {
      final next = targets[key];
      final old = _watches[key]!.endpoint;
      if (next == null ||
          next.url != old.url ||
          next.token != old.token ||
          next.fingerprint != old.fingerprint ||
          lan.receivingPaused) {
        _watches.remove(key)!.close();
      }
    }
    if (lan.receivingPaused) return;
    for (final endpoint in targets.values) {
      if (_watches.containsKey(endpoint.key)) continue;
      late final SyncWatch watch;
      bool current() => !_closed && identical(_watches[endpoint.key], watch);
      watch = SyncWatch(
        endpoint: endpoint,
        isForeground: () => _foreground,
        onChange: () {
          if (!current()) return;
          statuses[endpoint.key]?.retryAfter = null;
          requestSync(endpoint: endpoint.key);
        },
        onConnection: (online, error) {
          if (!current()) return;
          final status = statuses.putIfAbsent(endpoint.key, SyncStatus.new);
          final changed = status.online != online;
          status.online = online;
          if (online) status.notificationsSupported = true;
          if (changed && online && status.failures > 0) {
            status.retryAfter = null;
            requestSync(endpoint: endpoint.key);
          }
          if (error is StateError) {
            status.needsAttention = true;
            status.error = error.message;
          }
          if (changed || error is StateError) _activityChanged();
        },
        onUnsupported: () {
          if (!current()) return;
          statuses
                  .putIfAbsent(endpoint.key, SyncStatus.new)
                  .notificationsSupported =
              false;
          _activityChanged();
          _scheduleRetry();
        },
      );
      _watches[endpoint.key] = watch;
      unawaited(watch.run());
    }
  }

  void _lanChanged() {
    if (_closed) return;
    if (_wasPaused != lan.receivingPaused) {
      _wasPaused = lan.receivingPaused;
      if (_wasPaused) {
        _kick?.cancel();
        _kick = null;
        _retryTimer?.cancel();
        _pendingSync.clear();
        for (final endpoint in endpoints) {
          unawaited(_sync.cancel(endpoint.key).catchError((Object _) {}));
        }
      } else if (automaticSync) {
        for (final status in statuses.values) {
          status.retryAfter = null;
          status.failures = 0;
        }
        requestSync();
      }
    }
    final targets = endpoints;
    for (final endpoint in targets) {
      final connection = _connectionSignature(endpoint);
      if (_connections[endpoint.key] != connection) {
        _connections[endpoint.key] = connection;
        // A new address/process or a peer coming online is a new connection.
        // Its first attempt must not inherit the old connection's backoff.
        if (endpoint.isHub || lan.peers[endpoint.id]?.online == true) {
          final status = statuses[endpoint.key];
          status?.retryAfter = null;
          status?.failures = 0;
        }
      }
    }
    _connections.removeWhere((key, _) => !targets.any((e) => e.key == key));
    final boundKeys = syncTargets.map((target) => target.key).toSet();
    if (!setEquals(_knownSyncTargets, boundKeys)) {
      _knownSyncTargets
        ..clear()
        ..addAll(boundKeys);
      // Binding changes still update the local transfer list without causing
      // an unrelated network synchronization.
      unawaited(refreshTransfers().catchError((Object _) {}));
    }
    statuses.removeWhere((key, _) => !boundKeys.contains(key));
    _updateWatches();
    for (final endpoint in targets.where((e) => !e.isHub)) {
      final peer = lan.peers[endpoint.id]!;
      final signature =
          '${_connectionSignature(endpoint)}:'
          '${peer.online}:${peer.inboxRevision}';
      final previous = _peerSignatures[endpoint.key];
      _peerSignatures[endpoint.key] = signature;
      // An offline flag or an unrelated device update must not resync every
      // device. A new address/process/content cursor catches up just this peer.
      if (previous != signature && peer.online && automaticSync) {
        requestSync(endpoint: endpoint.key);
      }
    }
    _peerSignatures.removeWhere((key, _) => !boundKeys.contains(key));
    unawaited(_migrateLegacy());
    _changed();
  }
}
