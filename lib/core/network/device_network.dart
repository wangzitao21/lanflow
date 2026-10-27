part of 'lan_controller.dart';

extension _DeviceNetwork on LanController {
  void _loadDeviceNetwork(Map<String, dynamic> state) {
    _networkKeys.clear();
    for (final entry in (state['networkKeys'] as Map? ?? {}).entries) {
      if (_validNetworkKey(entry.key, entry.value)) {
        _networkKeys[entry.key as String] = entry.value as String;
      }
    }
    _networkKeys.putIfAbsent(identity.id, randomToken);
    _forgottenPeers
      ..clear()
      ..addAll(List<String>.from(state['forgottenPeers'] as List? ?? []));
  }

  bool _validNetworkKey(Object? id, Object? key) =>
      id is String &&
      RegExp(r'^[a-f0-9]{32}$').hasMatch(id) &&
      key is String &&
      RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(key);

  String _networkToken(String secret, String from, String to) =>
      base64UrlEncode(
        Hmac(
          sha256,
          utf8.encode(secret),
        ).convert(utf8.encode('LanFlow device network v1:$from:$to')).bytes,
      ).replaceAll('=', '');

  String _sendNetworkToken(String peerId) {
    final keys = _networkKeys.keys.toList()..sort();
    return _networkToken(_networkKeys[keys.first]!, identity.id, peerId);
  }

  bool _acceptNetworkToken(HttpRequest request, String peerId) {
    if (_forgottenPeers.contains(peerId)) return false;
    final provided = request.headers.value(HttpHeaders.authorizationHeader);
    return _networkKeys.values.any(
      (secret) =>
          provided == 'Bearer ${_networkToken(secret, peerId, identity.id)}',
    );
  }

  Map<String, dynamic> _deviceNetworkPayload() => {
    'keys': _networkKeys,
    'device': self.toJson(),
    'members': [
      for (final peer in peers.values)
        if (sessions.containsKey(peer.id) && !_forgottenPeers.contains(peer.id))
          peer.toJson(),
    ],
  };

  void _mergeDeviceNetwork(Map<String, dynamic> data, Peer sender) {
    final keys = data['keys'] as Map;
    final members = data['members'] as List;
    if (keys.length > 128 ||
        members.length > 128 ||
        keys.entries.any((e) => !_validNetworkKey(e.key, e.value))) {
      throw const FormatException('设备网络信息无效');
    }
    // Only an authenticated, certificate-pinned owned device can introduce
    // members or share group credentials. Discovery never carries secrets.
    final remote = Peer.fromJson(
      Map<String, dynamic>.from(data['device'] as Map),
      address: sender.address,
    );
    if (remote.id != sender.id || remote.fingerprint != sender.fingerprint) {
      throw const FormatException('设备身份不一致');
    }
    final introduced = members
        .map((v) => Peer.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
    var changed = false;
    for (final entry in keys.entries) {
      if (!_networkKeys.containsKey(entry.key) && _networkKeys.length < 128) {
        _networkKeys[entry.key as String] = entry.value as String;
        changed = true;
      }
    }
    _observe(remote);
    for (final peer in introduced) {
      if (peer.id == identity.id ||
          _forgottenPeers.contains(peer.id) ||
          InternetAddress.tryParse(peer.address) == null) {
        continue;
      }
      final old = peers[peer.id];
      if (old == null || !old.online) {
        peer.online = false;
        _observe(peer);
      }
      if (!sessions.containsKey(peer.id)) {
        final keys = _networkKeys.keys.toList()..sort();
        final secret = _networkKeys[keys.first]!;
        sessions[peer.id] = PeerSession(
          sendToken: _networkToken(secret, identity.id, peer.id),
          receiveToken: _networkToken(secret, peer.id, identity.id),
        );
        changed = true;
      }
    }
    if (changed) {
      _persist();
      _changed();
      _scheduleDeviceNetwork();
    }
  }

  void _scheduleDeviceNetwork() {
    if (_closed || _networkTimer != null) return;
    _networkTimer = Timer(const Duration(milliseconds: 100), () {
      _networkTimer = null;
      for (final peer in peers.values.toList()) {
        if (sessions.containsKey(peer.id)) {
          unawaited(refreshDeviceNetwork(peer));
        }
      }
    });
  }
}

extension DeviceNetwork on LanController {
  Future<void> refreshDeviceNetwork(Peer peer) {
    if (_closed ||
        !ready ||
        receivingPaused ||
        !_networkAvailable ||
        !sessions.containsKey(peer.id)) {
      return Future.value();
    }
    return _networkExchanges.putIfAbsent(
      peer.id,
      () => _exchangeDeviceNetwork(peer).whenComplete(() {
        _networkExchanges.remove(peer.id);
      }),
    );
  }

  Future<void> _exchangeDeviceNetwork(Peer peer) async {
    final address = peer.address;
    final port = peer.port;
    final instance = peer.instanceId;
    final session = sessions[peer.id]!;
    bool current() {
      final latest = peers[peer.id];
      return !_closed &&
          identical(sessions[peer.id], session) &&
          latest?.address == address &&
          latest?.port == port &&
          latest?.instanceId == instance;
    }

    final client = _client(peer)
      ..connectionTimeout = const Duration(seconds: 3);
    _networkClients.add(client);
    try {
      var token = session.sendToken;
      for (var attempt = 0; attempt < 2; attempt++) {
        final request = await client.postUrl(
          Uri(scheme: 'https', host: address, port: port, path: '/v1/network'),
        );
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.headers.set('X-Lanflow-Device', identity.id);
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.add(utf8.encode(jsonEncode(_deviceNetworkPayload())));
        final response = await request.close().timeout(
          const Duration(seconds: 5),
        );
        final data = await LanController._readJson(response);
        // A delayed reply from the previous route/process must not undo discovery.
        if (!current()) return;
        if (response.statusCode == 401 && attempt == 0) {
          token = _sendNetworkToken(peer.id);
          continue;
        }
        if (response.statusCode != 200) {
          return; // Older devices retain direct pairing.
        }
        _mergeDeviceNetwork(data, peer);
        if (token != sessions[peer.id]!.sendToken) {
          sessions[peer.id] = PeerSession(
            sendToken: token,
            receiveToken: sessions[peer.id]!.receiveToken,
          );
          _persist();
          _changed();
        }
        return;
      }
    } on Object {
      // Offline introductions are durable and retried by ordinary sync/reconnect.
    } finally {
      _networkClients.remove(client);
      client.close(force: true);
    }
  }
}
