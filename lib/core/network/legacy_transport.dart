part of 'lan_controller.dart';

// Compatibility for deployed v1 peers. Discovery and pairing remain in LanController.
extension _LegacyTransport on LanController {
  Future<void> _handleLegacyRequest(
    HttpRequest request,
    String route,
    Peer peer,
  ) async {
    if (request.method == 'POST' && route == '/v1/text') {
      if (receivingPaused) {
        await _reply(request, 403, {'error': '对方已暂停接收'});
        return;
      }
      final data = await LanController._readJson(request);
      final text = data['text'] as String;
      final id = _messageId(data);
      if (text.trim().isEmpty || text.length > 20000) {
        throw const FormatException('消息长度无效');
      }
      if (!messages.any(
        (m) => m.id == id && m.peerId == peer.id && !m.outgoing,
      )) {
        _add(
          ChatMessage(
            id: id,
            peerId: peer.id,
            outgoing: false,
            kind: MessageKind.text,
            createdAt: DateTime.now(),
            text: text,
            delivery: Delivery.complete,
          ),
        );
      }
      await _reply(request, 200, {'ok': true});
      return;
    }
    if (request.method == 'POST' && route == '/v1/offer') {
      if (receivingPaused || _incoming.length >= 4) {
        await _reply(request, 503, {'error': '对方已暂停接收或接收任务已满'});
        return;
      }
      final data = await LanController._readJson(request);
      final id = _messageId(data);
      final size = data['size'] as int;
      final digest = data['sha256'] as String;
      final kind = MessageKind.values.byName(data['kind'] as String);
      if (size < 0 ||
          size > 100 * 1024 * 1024 * 1024 ||
          kind == MessageKind.text ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(digest) ||
          (data['name'] as String).length > 512) {
        throw const FormatException('文件信息无效');
      }
      if (messages.any(
        (m) => m.id == id && m.peerId == peer.id && !m.outgoing,
      )) {
        await _reply(request, 409, {'error': '重复的传输任务，请重新发送'});
        return;
      }
      final message = ChatMessage(
        id: id,
        peerId: peer.id,
        outgoing: false,
        kind: kind,
        createdAt: DateTime.now(),
        name: safeFileName(data['name'] as String),
        size: size,
      );
      if (receivingPaused || _incoming.length >= 4) {
        await _reply(request, 403, {'error': '接收已暂停或任务已满'});
        return;
      }
      final token = randomToken();
      _incoming[token] = _IncomingFile(message, token, digest);
      _scheduleExpiry();
      _add(message);
      await _reply(request, 200, {'token': token});
      return;
    }
    if (request.method == 'PUT' && route.startsWith('/v1/upload/')) {
      final token = route.substring('/v1/upload/'.length);
      final incoming = _incoming[token];
      if (incoming == null ||
          incoming.active ||
          incoming.message.peerId != peer.id) {
        await _reply(request, 404, {'error': '接收任务不存在或已过期'});
        return;
      }
      await _receiveFile(request, incoming);
      return;
    }
    await _reply(request, 404, {'error': '未知请求'});
  }

  String _messageId(Map<String, dynamic> data) {
    final id = data['id'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]{16,64}$').hasMatch(id)) {
      throw const FormatException('消息编号无效');
    }
    return id;
  }

  Future<void> _receiveFile(HttpRequest request, _IncomingFile incoming) async {
    final message = incoming.message;
    final directory = receiveDirectory;
    final temp = File(
      p.join(directory.path, '.lanflow-${randomToken(12)}.part'),
    );
    RandomAccessFile? output;
    incoming.active = true;
    _scheduleExpiry();
    _transferChanged(1);
    try {
      if (incoming.cancelled || _closed) throw StateError('传输已取消');
      if (request.contentLength != message.size) {
        throw const FormatException('文件大小不一致');
      }
      await directory.create(recursive: true);
      output = await temp.open(mode: FileMode.write);
      message.delivery = Delivery.transferring;
      _changed();
      await for (final chunk in request.timeout(const Duration(seconds: 30))) {
        if (incoming.cancelled || _closed) throw StateError('传输已取消');
        if (message.transferred + chunk.length > message.size) {
          throw const FormatException('文件大小超出声明值');
        }
        await output.writeFrom(chunk);
        message.transferred += chunk.length;
        _changed();
      }
      await output.close();
      output = null;
      if (incoming.cancelled || _closed) throw StateError('传输已取消');
      if (message.transferred != message.size) {
        throw const FormatException('文件未完整接收');
      }
      final digest = await hashFileInBackground(temp.path);
      if (incoming.cancelled || _closed) throw StateError('传输已取消');
      if (digest != incoming.digest) {
        throw const FormatException('文件校验失败，请重新发送');
      }
      final saved = await temp.rename(
        p.join(
          directory.path,
          '${DateTime.now().millisecondsSinceEpoch}-${randomToken(4)}-${message.name}',
        ),
      );
      message.path = saved.path;
      message.delivery = Delivery.complete;
      _persist();
      _changed();
      await _reply(request, 200, {'ok': true, 'sha256': digest});
    } on Object catch (e) {
      if (message.delivery != Delivery.complete) _fail(message, _friendly(e));
      rethrow;
    } finally {
      try {
        await output?.close();
        if (await temp.exists()) await temp.delete();
        _incoming.remove(incoming.token);
      } finally {
        _transferChanged(-1);
      }
    }
  }

  Future<void> _sendLegacyText(Peer peer, String text) async {
    final value = text.trim();
    if (value.isEmpty || value.length > 20000) return;
    final message = ChatMessage(
      id: randomToken(18),
      peerId: peer.id,
      outgoing: true,
      kind: MessageKind.text,
      createdAt: DateTime.now(),
      text: value,
    );
    _add(message);
    try {
      await connect(peer);
      await _post(peer, '/v1/text', {'id': message.id, 'text': value});
      message.delivery = Delivery.complete;
      _persist();
      _changed();
    } on Object catch (e) {
      _fail(message, _friendly(e));
    }
  }

  Future<void> _sendLegacyFile(Peer peer, String path) async {
    final file = File(path);
    final size = await file.length();
    final extension = p.extension(path).toLowerCase();
    final kind =
        ['.jpg', '.jpeg', '.png', '.webp', '.gif', '.bmp'].contains(extension)
        ? MessageKind.image
        : ['.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v'].contains(extension)
        ? MessageKind.video
        : MessageKind.file;
    final message = ChatMessage(
      id: randomToken(18),
      peerId: peer.id,
      outgoing: true,
      kind: kind,
      createdAt: DateTime.now(),
      name: p.basename(path),
      size: size,
      path: path,
    );
    _add(message);
    final task = _sendQueue
        .catchError((Object _) {})
        .then((_) => _sendFile(peer, message));
    _sendQueue = task;
    return task;
  }

  Future<void> _sendFile(Peer peer, ChatMessage message) async {
    if (message.delivery == Delivery.cancelled || _closed) return;
    HttpClient? client;
    _transferChanged(1);
    try {
      if (message.delivery == Delivery.cancelled || _closed) return;
      await connect(peer);
      if (message.delivery == Delivery.cancelled || _closed) return;
      final filePath = message.path!;
      final digest = await hashFileInBackground(filePath);
      if (message.delivery == Delivery.cancelled || _closed) return;
      final response = await _post(peer, '/v1/offer', {
        'id': message.id,
        'name': message.name,
        'size': message.size,
        'kind': message.kind.name,
        'sha256': digest,
      });
      if (message.delivery == Delivery.cancelled || _closed) return;
      client = _client(peer);
      _clients[message.id] = client;
      final request = await client.putUrl(
        Uri(
          scheme: 'https',
          host: peer.address,
          port: peer.port,
          path: '/v1/upload/${response['token']}',
        ),
      );
      request.followRedirects = false;
      _authorizeRequest(request, peer);
      request.headers.contentType = ContentType.binary;
      request.contentLength = message.size;
      message.delivery = Delivery.transferring;
      _changed();
      final stream = File(filePath).openRead().map((chunk) {
        if (message.delivery == Delivery.cancelled || _closed) {
          throw StateError('传输已取消');
        }
        message.transferred += chunk.length;
        _changed();
        return chunk;
      });
      await request.addStream(stream).timeout(const Duration(hours: 2));
      final result = await request.close().timeout(const Duration(minutes: 10));
      final data = await LanController._readJson(result);
      if (result.statusCode != 200 || data['sha256'] != digest) {
        throw StateError(data['error'] as String? ?? '接收端校验失败');
      }
      message.delivery = Delivery.complete;
      _persist();
      _changed();
    } on Object catch (e) {
      _fail(message, _friendly(e));
    } finally {
      client?.close(force: true);
      _clients.remove(message.id);
      _transferChanged(-1);
    }
  }

  void _cancelLegacy(ChatMessage message) {
    if (message.delivery == Delivery.complete) return;
    message.delivery = Delivery.cancelled;
    message.error = '已取消';
    _clients.remove(message.id)?.close(force: true);
    for (final incoming in _incoming.values) {
      if (identical(incoming.message, message)) incoming.cancelled = true;
    }
    _persist();
    _changed();
  }

  Future<void> _retryLegacy(ChatMessage message) async {
    final peer = peers[message.peerId];
    if (peer == null || !message.outgoing) return;
    if (message.kind == MessageKind.text) {
      // Keep the ID, allowing the receiver to deduplicate a lost acknowledgement.
      message.delivery = Delivery.waiting;
      message.error = null;
      _changed();
      try {
        await connect(peer);
        await _post(peer, '/v1/text', {'id': message.id, 'text': message.text});
        message.delivery = Delivery.complete;
        _persist();
        _changed();
      } on Object catch (e) {
        _fail(message, _friendly(e));
      }
    } else if (message.path != null) {
      await _sendLegacyFile(peer, message.path!);
    }
  }
}

class _IncomingFile {
  _IncomingFile(this.message, this.token, this.digest);
  final ChatMessage message;
  final String token;
  final String digest;
  final DateTime created = DateTime.now();
  bool active = false;
  bool cancelled = false;
}
