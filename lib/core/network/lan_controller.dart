import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:lanflow/core/files/file_utils.dart';
import 'package:lanflow/core/network/discovery.dart';
import 'package:lanflow/core/network/identity.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/storage/local_store.dart';
import 'package:lanflow/platform/native_core.dart';

part 'legacy_transport.dart';
part 'device_network.dart';

class LanController extends ChangeNotifier {
  LanController({
    required this.store,
    required this.receiveDirectory,
    this.enableDiscovery = true,
    this.preferredPort = servicePort,
    this.bindAddress,
    this.initialName,
    this.beforeDiscovery,
  });

  final LocalStore store;
  Directory receiveDirectory;
  final bool enableDiscovery;
  final int preferredPort;
  final InternetAddress? bindAddress;
  final String? initialName;
  final Future<void> Function()? beforeDiscovery;
  Identity? _identity;
  Identity get identity => _identity!;
  set identity(Identity value) => _identity = value;
  bool get identityReady => _identity != null;
  final Map<String, Peer> peers = {};
  final Map<String, PeerSession> sessions = {};
  final List<ChatMessage> messages = [];
  final Map<String, int> unread = {};
  final Map<String, String> pairingCodes = {};
  final Map<String, Future<void>> _pairing = {};
  final Map<String, String> _pairingReceiveTokens = {};
  final Map<String, _IncomingFile> _incoming = {};
  final Map<String, HttpClient> _clients = {};
  final Map<String, String> _networkKeys = {};
  final Set<String> _forgottenPeers = {};
  final Map<String, Future<void>> _networkExchanges = {};
  final Set<HttpClient> _networkClients = {};
  Timer? _networkTimer;
  Future<void> _sendQueue = Future.value();
  HttpServer? _server;
  DiscoveryService? _discovery;
  Timer? _saveTimer;
  Timer? _expiryTimer;
  Timer? _notifyTimer;
  bool _closed = false;
  bool _stateLoaded = false;
  final String instanceId = randomToken(18);
  int inboxRevision = 0;
  int _pendingPrompts = 0;
  int _activeRequests = 0;
  int _activeWatchRequests = 0;
  final transferActivity = ValueNotifier<int>(0);
  int get activeTransferCount => transferActivity.value;
  bool _disposed = false;
  final Set<String> _watchingPeers = {};
  String name = '';
  String? error;
  String? discoveryWarning;
  bool ready = false;
  bool starting = false;
  bool receivingPaused = false;
  bool _networkAvailable = true;
  bool autoAcceptFiles = true;
  String? selectedPeerId;
  List<String> addresses = [];
  Future<bool> Function(IncomingPrompt)? onPrompt;
  Future<void> Function(HttpRequest)? onInboxRequest;

  Peer get self => Peer(
    id: identity.id,
    name: name,
    platform: Platform.operatingSystem,
    address: '',
    port: _server?.port ?? preferredPort,
    fingerprint: identity.fingerprint,
    inboxVersion: 3,
    instanceId: instanceId,
    inboxRevision: inboxRevision,
  );

  List<ChatMessage> conversation(String peerId) =>
      messages.where((message) => message.peerId == peerId).toList();

  List<Peer> get sortedPeers {
    final result = peers.values.toList();
    result.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      DateTime last(String id) => messages
          .lastWhere(
            (m) => m.peerId == id,
            orElse: () => ChatMessage(
              id: '',
              peerId: id,
              outgoing: false,
              kind: MessageKind.text,
              createdAt: DateTime(1970),
            ),
          )
          .createdAt;
      return last(b.id).compareTo(last(a.id));
    });
    return result;
  }

  Future<void> start() async {
    if (_closed || starting || ready) return;
    starting = true;
    error = null;
    discoveryWarning = null;
    _changed();
    try {
      final state = await store.load();
      _stateLoaded = true;
      name = initialName ?? state['name'] as String? ?? Platform.localHostname;
      if (name.isEmpty) name = Platform.isAndroid ? '我的 Android' : '我的电脑';
      if (name.length > 60) name = name.substring(0, 60);
      // Binding identifies an owned device. Subsequent content needs no confirmation.
      autoAcceptFiles = true;
      receivingPaused = state['receivingPaused'] == true;
      if (state['receiveDirectory'] is String && !Platform.isAndroid) {
        receiveDirectory = Directory(state['receiveDirectory'] as String);
      }
      await receiveDirectory.create(recursive: true);
      identity = await Identity.load(store.deviceDirectory);
      _loadDeviceNetwork(state);
      peers.clear();
      sessions.clear();
      messages.clear();
      for (final value in state['peers'] as List? ?? []) {
        try {
          final peer = Peer.fromJson(Map<String, dynamic>.from(value as Map));
          peer.online = false;
          peers[peer.id] = peer;
        } on Object {
          /* Skip individual incompatible records. */
        }
      }
      for (final entry in (state['sessions'] as Map? ?? {}).entries) {
        try {
          sessions[entry.key as String] = PeerSession.fromJson(
            Map<String, dynamic>.from(entry.value as Map),
          );
        } on Object {
          /* Pair again if an old record cannot be read. */
        }
      }
      for (final value in state['messages'] as List? ?? []) {
        try {
          messages.add(
            ChatMessage.fromJson(Map<String, dynamic>.from(value as Map)),
          );
        } on Object {
          /* Preserve readable history. */
        }
      }
      try {
        _server = await HttpServer.bindSecure(
          bindAddress ?? InternetAddress.anyIPv4,
          preferredPort,
          identity.context,
        );
      } on SocketException {
        if (preferredPort == 0) rethrow;
        _server = await HttpServer.bindSecure(
          bindAddress ?? InternetAddress.anyIPv4,
          0,
          identity.context,
        );
      }
      _server!.idleTimeout = const Duration(seconds: 20);
      _server!.listen(
        (request) => unawaited(handleRequest(request)),
        onError: (Object e) {
          error = '接收服务出现错误：$e';
          _changed();
        },
      );
      ready = true;
      // The local conversation is usable before adapter discovery finishes.
      _changed();
      await refreshAddresses();
      if (enableDiscovery) {
        _discovery = DiscoveryService(
          beforeDiscovery: beforeDiscovery,
          self: () => self,
          onPeer: _observe,
          onError: (message) {
            discoveryWarning = message;
            _changed();
          },
        );
        try {
          await _discovery!.start();
          _discovery!.setActivity(
            paused: receivingPaused || !_networkAvailable,
          );
        } on Object catch (e) {
          if (e is! SocketException && e is! OSError) rethrow;
          _discovery?.close();
          _discovery = null;
          discoveryWarning = '自动发现不可用，可通过右上角手动添加设备';
        }
      }
      _scheduleExpiry();
      _persist();
    } on Object catch (e) {
      _discovery?.close();
      _discovery = null;
      await _server?.close(force: true);
      _server = null;
      error = '启动失败：$e';
      ready = false;
    } finally {
      starting = false;
      _changed();
    }
  }

  Future<void> refreshAddresses() async {
    try {
      addresses = (await NetworkInterface.list(type: InternetAddressType.IPv4))
          .expand((interface) => interface.addresses)
          .map((ip) => '${ip.address}:${self.port}')
          .toList();
    } on SocketException {
      addresses = [];
    } on OSError {
      addresses = [];
    }
    _changed();
  }

  void _observe(Peer peer) {
    if (_closed || peer.id == identity.id) return;
    // Identity is derived from the certificate, so broadcasts cannot replace a paired key.
    final previous = peers[peer.id];
    peers[peer.id] = peer;
    if (previous == null ||
        previous.name != peer.name ||
        previous.address != peer.address ||
        previous.port != peer.port ||
        previous.platform != peer.platform ||
        previous.online != peer.online ||
        previous.fingerprint != peer.fingerprint ||
        previous.inboxVersion != peer.inboxVersion ||
        previous.instanceId != peer.instanceId ||
        previous.inboxRevision != peer.inboxRevision) {
      _changed();
    }
    _scheduleExpiry();
  }

  void _scheduleExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    if (_closed) return;
    // Bound devices stay quiet until they have work. Their last successful
    // contact must not turn into an offline/reconnect loop just from age.
    final deadlines = [
      for (final peer in peers.values)
        if (peer.online && !sessions.containsKey(peer.id))
          peer.lastSeen.add(const Duration(seconds: 150)),
      for (final incoming in _incoming.values)
        if (!incoming.active) incoming.created.add(const Duration(minutes: 2)),
    ];
    if (deadlines.isEmpty) return;
    deadlines.sort();
    final delay = deadlines.first.difference(DateTime.now());
    _expiryTimer = Timer(delay.isNegative ? Duration.zero : delay, () {
      final now = DateTime.now();
      var changed = false;
      for (final peer in peers.values) {
        if (peer.online &&
            !sessions.containsKey(peer.id) &&
            !peer.lastSeen.add(const Duration(seconds: 150)).isAfter(now)) {
          peer.online = false;
          changed = true;
        }
      }
      for (final entry in _incoming.entries.toList()) {
        if (!entry.value.active &&
            !entry.value.created.add(const Duration(minutes: 2)).isAfter(now)) {
          _incoming.remove(entry.key);
          _fail(entry.value.message, '发送端未开始传输，请重试');
        }
      }
      if (changed) _changed();
      _scheduleExpiry();
    });
  }

  void selectPeer(String? id) {
    selectedPeerId = id;
    if (id != null) unread[id] = 0;
    _changed();
  }

  void updateSettings({
    String? deviceName,
    bool? acceptFiles,
    Directory? directory,
  }) {
    if (deviceName != null && deviceName.trim().isNotEmpty) {
      name = deviceName.trim().substring(
        0,
        deviceName.trim().length.clamp(0, 60),
      );
    }
    if (acceptFiles != null) autoAcceptFiles = acceptFiles;
    if (directory != null) receiveDirectory = directory;
    _persist();
    _changed();
    unawaited(_discovery?.announce() ?? Future.value());
  }

  void setReceivingPaused(bool paused) {
    receivingPaused = paused;
    _discovery?.setActivity(paused: paused || !_networkAvailable);
    _persist();
    _changed();
  }

  void setForeground(bool foreground) =>
      _discovery?.setActivity(foreground: foreground);

  void setNetworkAvailable(bool available) {
    _networkAvailable = available;
    _discovery?.setActivity(paused: receivingPaused || !available);
  }

  void forgetPeer(String id) {
    sessions.remove(id);
    _forgottenPeers.add(id);
    _scheduleExpiry();
    _persist();
    _changed();
  }

  Future<void> refresh() async {
    await refreshAddresses();
    await _discovery?.announce();
  }

  void announceChanges(int revision) {
    if (inboxRevision == revision) return;
    inboxRevision = revision;
    unawaited(_discovery?.announce() ?? Future.value());
  }

  HttpClient _client(Peer peer) =>
      HttpClient(context: SecurityContext(withTrustedRoots: false))
        ..connectionTimeout = const Duration(seconds: 8)
        ..badCertificateCallback = (cert, host, port) =>
            sha256.convert(cert.der).toString() == peer.fingerprint;

  Future<Peer> addAddress(String input) async {
    final value = input.trim();
    final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请输入设备上的地址，例如 192.168.1.8:53318');
    }
    final address = InternetAddress.tryParse(uri.host);
    if (address == null || address.type != InternetAddressType.IPv4) {
      throw const FormatException('请填写局域网 IPv4 地址');
    }
    final client = HttpClient(context: SecurityContext(withTrustedRoots: false))
      ..connectionTimeout = const Duration(seconds: 5)
      ..badCertificateCallback = (_, _, _) => true;
    try {
      // Only this unauthenticated identity lookup accepts an unknown certificate.
      // No messages, tokens or files are sent before confirmation and pinning.
      final request = await client.getUrl(
        Uri(
          scheme: 'https',
          host: address.address,
          port: uri.hasPort ? uri.port : servicePort,
          path: '/v1/info',
        ),
      );
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final certificate = response.certificate;
      if (response.statusCode != 200 || certificate == null) {
        throw const FormatException('不是 LanFlow 设备');
      }
      final peer = Peer.fromJson(
        await _readJson(response),
        address: address.address,
      );
      if (peer.fingerprint != sha256.convert(certificate.der).toString()) {
        throw const FormatException('设备证书不一致');
      }
      if (peer.id == identity.id) throw const FormatException('这是当前设备');
      _observe(peer);
      _persist();
      return peer;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> updatePeerAddress(String id, String input) async {
    final old = peers[id];
    if (old == null || !sessions.containsKey(id)) throw StateError('设备已移除');
    final text = input.trim();
    final uri = Uri.tryParse(text.contains('://') ? text : 'https://$text');
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw const FormatException('请输入设备上的地址，例如 192.168.1.8:53318');
    }
    final address = InternetAddress.tryParse(uri.host);
    if (address == null || address.type != InternetAddressType.IPv4) {
      throw const FormatException('请填写局域网 IPv4 地址');
    }
    final next = Peer.fromJson({
      ...old.toJson(),
      'port': uri.hasPort ? uri.port : servicePort,
    }, address: address.address)..online = false;
    peers[id] = next;
    try {
      await store.save(_state());
    } on Object {
      if (identical(peers[id], next)) peers[id] = old;
      rethrow;
    }
    _scheduleExpiry();
    _changed();
  }

  Future<Map<String, dynamic>> _post(
    Peer peer,
    String path,
    Map<String, dynamic> body, {
    bool authenticated = true,
    Duration timeout = const Duration(seconds: 75),
  }) async {
    final client = _client(peer);
    try {
      final request = await client.postUrl(
        Uri(scheme: 'https', host: peer.address, port: peer.port, path: path),
      );
      request.followRedirects = false;
      request.headers.contentType = ContentType.json;
      if (authenticated) _authorizeRequest(request, peer);
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(timeout);
      final data = await _readJson(response);
      if (response.statusCode != 200) {
        if (response.statusCode == 401) {
          sessions.remove(peer.id);
          _persist();
        }
        throw StateError(data['error'] as String? ?? '对方暂时无法接收');
      }
      _observe(
        peer
          ..lastSeen = DateTime.now()
          ..online = true,
      );
      return data;
    } finally {
      client.close(force: true);
    }
  }

  void _authorizeRequest(HttpClientRequest request, Peer peer) {
    final session = sessions[peer.id];
    if (session == null) throw StateError('请重新连接设备');
    request.headers.set('X-Lanflow-Device', identity.id);
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${session.sendToken}',
    );
  }

  Future<void> connect(Peer peer, {bool rePair = false}) {
    if (!rePair && sessions.containsKey(peer.id)) return Future.value();
    return _pairing.putIfAbsent(
      peer.id,
      () => _pair(peer).whenComplete(() {
        _pairing.remove(peer.id);
      }),
    );
  }

  Future<void> _pair(Peer peer) async {
    final receiveToken = randomToken();
    _pairingReceiveTokens[peer.id] = receiveToken;
    pairingCodes[peer.id] = verificationCode(
      identity.fingerprint,
      peer.fingerprint,
    );
    _changed();
    try {
      final response = await _post(peer, '/v1/pair', {
        'device': self.toJson(),
        'token': receiveToken,
      }, authenticated: false);
      final sendToken = response['token'] as String;
      if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(sendToken)) {
        throw StateError('配对响应无效');
      }
      if (_closed) throw StateError('连接已关闭');
      sessions[peer.id] = PeerSession(
        receiveToken: receiveToken,
        sendToken: sendToken,
      );
      _forgottenPeers.remove(peer.id);
      _scheduleExpiry();
      _persist();
      await refreshDeviceNetwork(peer);
      _scheduleDeviceNetwork();
    } finally {
      _pairingReceiveTokens.remove(peer.id);
      pairingCodes.remove(peer.id);
      _changed();
    }
  }

  Future<bool> _ask(IncomingPrompt prompt) async {
    if (receivingPaused ||
        _pendingPrompts >= 3 ||
        onPrompt == null ||
        _closed) {
      return false;
    }
    _pendingPrompts++;
    try {
      return await onPrompt!(
        prompt,
      ).timeout(const Duration(seconds: 60), onTimeout: () => false);
    } finally {
      _pendingPrompts--;
    }
  }

  @visibleForTesting
  Future<void> handleRequest(HttpRequest request) async {
    final route = request.uri.path;
    final watching = route == '/v3/watch' && request.method == 'GET';
    if (watching) {
      _activeWatchRequests++;
    } else {
      _activeRequests++;
    }
    try {
      if ((watching ? _activeWatchRequests > 128 : _activeRequests > 16) ||
          _closed) {
        await _reply(request, 503, {'error': '设备忙，请稍后重试'});
        return;
      }
      if (request.method == 'GET' && route == '/v1/info') {
        await _reply(request, 200, self.toJson());
        return;
      }
      if (request.method == 'POST' && route == '/v1/pair') {
        if (receivingPaused) {
          await _reply(request, 403, {'error': '对方已暂停接收'});
          return;
        }
        final data = await _readJson(request);
        final peer = Peer.fromJson(
          data['device'] as Map<String, dynamic>,
          address: request.connectionInfo!.remoteAddress.address,
        );
        final token = data['token'] as String;
        if (peer.id == identity.id ||
            !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(token)) {
          throw const FormatException('配对信息无效');
        }
        final approved = await _ask(
          IncomingPrompt.pair(
            peer,
            verificationCode(identity.fingerprint, peer.fingerprint),
          ),
        );
        if (!approved || _closed || receivingPaused) {
          await _reply(request, 403, {'error': '对方拒绝连接或确认超时'});
          return;
        }
        // Both devices may initiate pairing before either prompt is approved.
        // Use the token already offered by this device for both directions.
        // A late inbound response can also match the just-completed handshake;
        // a genuinely new pairing token still rotates an old session.
        final existing = sessions[peer.id];
        final receiveToken =
            _pairingReceiveTokens[peer.id] ??
            (existing?.sendToken == token
                ? existing!.receiveToken
                : randomToken());
        sessions[peer.id] = PeerSession(
          receiveToken: receiveToken,
          sendToken: token,
        );
        _forgottenPeers.remove(peer.id);
        _observe(peer);
        _persist();
        await _reply(request, 200, {'token': receiveToken});
        return;
      }
      final peerId = request.headers.value('X-Lanflow-Device');
      final session = sessions[peerId];
      if (session == null ||
          (request.headers.value(HttpHeaders.authorizationHeader) !=
                  'Bearer ${session.receiveToken}' &&
              !_acceptNetworkToken(request, peerId!)) ||
          !peers.containsKey(peerId)) {
        await _reply(request, 401, {'error': '连接已失效，请重新配对'});
        return;
      }
      final peer = peers[peerId]!;
      peer.lastSeen = DateTime.now();
      peer.online = true;
      if (route == '/v1/network' && request.method == 'POST') {
        final data = await _readJson(request);
        // Use the authenticated socket's address, not the last discovery record.
        final sender = Peer.fromJson(
          peer.toJson(),
          address: request.connectionInfo!.remoteAddress.address,
        );
        _mergeDeviceNetwork(data, sender);
        await _reply(request, 200, _deviceNetworkPayload());
        return;
      }
      if (route.startsWith('/v2/') || route.startsWith('/v3/')) {
        if (receivingPaused || onInboxRequest == null) {
          await _reply(request, 503, {
            'error': receivingPaused ? '对方已暂停同步，恢复后会继续' : '对方正在准备同步，稍后自动重试',
            'category': receivingPaused ? 'paused' : 'not_ready',
          });
        } else {
          if (watching && !_watchingPeers.add(peer.id)) {
            await _reply(request, 409, {'error': '设备通知连接已存在'});
            return;
          }
          final transferring =
              route.startsWith('/v2/blobs/') &&
              const {'GET', 'PUT'}.contains(request.method);
          if (transferring) _transferChanged(1);
          try {
            await onInboxRequest!(request);
          } finally {
            if (transferring) _transferChanged(-1);
            if (watching) {
              _watchingPeers.remove(peer.id);
              peer.lastSeen = DateTime.now();
            }
          }
        }
        return;
      }
      await _handleLegacyRequest(request, route, peer);
    } on Object catch (e) {
      try {
        await _reply(request, e is NativeCoreError ? e.status : 400, {
          'error': e is NativeCoreError
              ? e.message
              : e is FormatException
              ? e.message
              : '请求无效或传输中断',
        });
      } on Object {
        /* The sender may already have disconnected. */
      }
    } finally {
      if (watching) {
        _activeWatchRequests--;
      } else {
        _activeRequests--;
      }
    }
  }

  void _transferChanged(int delta) {
    if (!_disposed) transferActivity.value += delta;
  }

  Future<void> sendText(Peer peer, String text) => _sendLegacyText(peer, text);
  Future<void> sendFile(Peer peer, String path) => _sendLegacyFile(peer, path);
  void cancel(ChatMessage message) => _cancelLegacy(message);
  Future<void> retry(ChatMessage message) => _retryLegacy(message);

  void _add(ChatMessage message) {
    messages.add(message);
    if (!message.outgoing && selectedPeerId != message.peerId) {
      unread.update(message.peerId, (value) => value + 1, ifAbsent: () => 1);
    }
    _persist();
    _changed();
  }

  void _fail(ChatMessage message, String reason) {
    if (message.delivery != Delivery.cancelled) {
      message.delivery = Delivery.failed;
      message.error = reason;
    }
    _persist();
    _changed();
  }

  String _friendly(Object error) {
    if (error is SocketException || error is HandshakeException) {
      return '连接中断，请确认对方在线、网络和防火墙设置';
    }
    if (error is TimeoutException) return '等待超时，请确认对方在线后重试';
    if (error is FileSystemException) return '无法读写文件，请检查文件是否存在、存储空间和权限';
    if (error is StateError) return error.message;
    if (error is FormatException) return error.message;
    return '传输失败，请重试';
  }

  static Future<Map<String, dynamic>> _readJson(
    Stream<List<int>> stream,
  ) async {
    final bytes = <int>[];
    await for (final chunk in stream.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > 65536) {
        throw const FormatException('请求过大');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  Future<void> _reply(
    HttpRequest request,
    int status,
    Map<String, dynamic> body,
  ) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.headers.set('Cache-Control', 'no-store');
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  void _changed() {
    if (_closed || _notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 16), () {
      _notifyTimer = null;
      if (!_closed) notifyListeners();
    });
  }

  Map<String, dynamic> _state() => {
    'name': name,
    'autoAcceptFiles': autoAcceptFiles,
    'receivingPaused': receivingPaused,
    'receiveDirectory': receiveDirectory.path,
    'peers': peers.values.map((peer) => peer.toJson()).toList(),
    'sessions': sessions.map((key, value) => MapEntry(key, value.toJson())),
    'networkKeys': _networkKeys,
    'forgottenPeers': _forgottenPeers.toList(),
    'messages': messages
        .skip((messages.length - 2000).clamp(0, messages.length))
        .map((message) => message.toJson())
        .toList(),
  };

  void _persist() {
    if (_closed || !_stateLoaded) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(
        store.save(_state()).catchError((Object e) {
          error = '本地记录保存失败：$e';
          _changed();
        }),
      );
    });
  }

  Future<void> retrySave() async {
    if (!_stateLoaded || _closed) return;
    _saveTimer?.cancel();
    try {
      await store.save(_state());
      error = null;
    } on Object catch (e) {
      error = '本地记录保存失败：$e';
    }
    _changed();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _saveTimer?.cancel();
    _notifyTimer?.cancel();
    _expiryTimer?.cancel();
    _networkTimer?.cancel();
    for (final client in _networkClients.toList()) {
      client.close(force: true);
    }
    _discovery?.close();
    for (final client in _clients.values) {
      client.close(force: true);
    }
    for (final incoming in _incoming.values) {
      incoming.cancelled = true;
    }
    await _server?.close(force: true);
    if (_stateLoaded) await store.save(_state());
  }

  @override
  void dispose() {
    _disposed = true;
    transferActivity.dispose();
    super.dispose();
  }
}
