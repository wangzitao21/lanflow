import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lanflow/core/network/identity.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/core/storage/local_store.dart';

// Exercise the production HTTP handler and real filesystem without opening a
// network connection. transport_test.dart separately covers real TLS sockets.
void main() {
  late Directory directory;
  late LanController receiver;
  late Identity identity;
  late Peer sender;
  late String token;
  late Directory suiteDirectory;

  setUpAll(() async {
    suiteDirectory = await Directory.systemTemp.createTemp('lanflow-receiver-');
    identity = await Identity.load(suiteDirectory);
  });
  tearDownAll(() => suiteDirectory.delete(recursive: true));

  setUp(() async {
    directory = await suiteDirectory.createTemp('case-');
    receiver = LanController(
      store: LocalStore(directory),
      receiveDirectory: Directory('${directory.path}/received'),
      enableDiscovery: false,
    )..identity = identity;
    receiver.name = '接收设备';
    sender = Peer(
      id: 'a' * 32,
      name: '发送设备',
      platform: 'android',
      address: '192.168.1.12',
      port: 53318,
      fingerprint: 'a' * 64,
    );
    token = randomToken();
    receiver.peers[sender.id] = sender;
    receiver.sessions[sender.id] = PeerSession(
      receiveToken: token,
      sendToken: randomToken(),
    );
    receiver.onPrompt = (_) async => true;
  });

  tearDown(() async {
    await receiver.close();
    receiver.dispose();
  });

  Future<_Request> request(
    String method,
    String route, {
    Map<String, dynamic>? json,
    List<int>? bytes,
    bool authenticated = true,
    int? contentLength,
  }) async {
    final data = bytes ?? utf8.encode(jsonEncode(json ?? {}));
    final request = _Request(method, route, data, contentLength);
    if (authenticated) {
      request.headers.set('X-Lanflow-Device', sender.id);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    await receiver.handleRequest(request);
    return request;
  }

  Future<_Request> offer(List<int> bytes, String name, String kind) => request(
    'POST',
    '/v1/offer',
    json: {
      'id': randomToken(18),
      'name': name,
      'kind': kind,
      'size': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    },
  );

  test('pairing requires approval and issues a fresh receive token', () async {
    receiver.sessions.clear();
    var prompts = 0;
    receiver.onPrompt = (prompt) async {
      prompts++;
      expect(
        prompt.code,
        verificationCode(identity.fingerprint, sender.fingerprint),
      );
      return prompts == 2;
    };
    final body = {'device': sender.toJson(), 'token': token};
    final denied = await request(
      'POST',
      '/v1/pair',
      json: body,
      authenticated: false,
    );
    expect(denied.response.statusCode, 403);
    expect(receiver.sessions, isEmpty);
    final allowed = await request(
      'POST',
      '/v1/pair',
      json: body,
      authenticated: false,
    );
    expect(allowed.response.statusCode, 200);
    final session = receiver.sessions[sender.id]!;
    expect(session.sendToken, token);
    expect(session.receiveToken, allowed.response.json['token']);
    expect(session.receiveToken, isNot(token));
  });

  test(
    'text authentication, Unicode, deduplication and pause work together',
    () async {
      final body = {'id': randomToken(18), 'text': '你好，Windows 👋\n文件收到了'};
      final unauthenticated = await request(
        'POST',
        '/v1/text',
        json: body,
        authenticated: false,
      );
      expect(unauthenticated.response.statusCode, 401);
      expect(receiver.messages, isEmpty);
      expect(
        (await request('POST', '/v1/text', json: body)).response.statusCode,
        200,
      );
      expect(
        (await request('POST', '/v1/text', json: body)).response.statusCode,
        200,
      );
      expect(receiver.messages, hasLength(1));
      expect(receiver.messages.single.text, body['text']);
      receiver.setReceivingPaused(true);
      final paused = await request(
        'POST',
        '/v1/text',
        json: {...body, 'id': randomToken(18)},
      );
      expect(paused.response.statusCode, 403);
      expect(receiver.messages, hasLength(1));
    },
  );

  test(
    'image, video, generic and empty file streams are saved byte for byte',
    () async {
      var prompts = 0;
      receiver.onPrompt = (_) async {
        prompts++;
        return true;
      };
      for (final spec in [
        ('photo.png', 'image', 8193),
        ('movie.mp4', 'video', 3 * 1024 * 1024 + 7),
        ('archive.zip', 'file', 33333),
        ('empty.dat', 'file', 0),
      ]) {
        final bytes = Uint8List.fromList(
          List.generate(spec.$3, (i) => (17 * i + 23) % 256),
        );
        final accepted = await offer(bytes, spec.$1, spec.$2);
        expect(accepted.response.statusCode, 200);
        final upload = await request(
          'PUT',
          '/v1/upload/${accepted.response.json['token']}',
          bytes: bytes,
        );
        expect(upload.response.statusCode, 200);
        expect(
          upload.response.json['sha256'],
          sha256.convert(bytes).toString(),
        );
        final message = receiver.messages.last;
        expect(message.delivery, Delivery.complete);
        expect(message.kind.name, spec.$2);
        expect(message.transferred, bytes.length);
        expect(await File(message.path!).readAsBytes(), orderedEquals(bytes));
      }
      expect(prompts, 0);
    },
  );

  test(
    'paired devices receive files without any confirmation callback',
    () async {
      receiver.onPrompt = (_) async => false;
      final accepted = await offer([1, 2, 3], 'private.bin', 'file');
      expect(accepted.response.statusCode, 200);
      expect(receiver.messages, hasLength(1));
      expect(await receiver.receiveDirectory.exists(), isFalse);
    },
  );

  test('checksum and truncated uploads remove all partial files', () async {
    for (final truncated in [false, true]) {
      final accepted = await offer([1, 2, 3], '../../escape.bin', 'file');
      final upload = await request(
        'PUT',
        '/v1/upload/${accepted.response.json['token']}',
        bytes: truncated ? [1, 2] : [4, 5, 6],
        contentLength: 3,
      );
      expect(upload.response.statusCode, 400);
      expect(receiver.messages.last.delivery, Delivery.failed);
      expect(receiver.messages.last.path, isNull);
      expect(receiver.messages.last.name, 'escape.bin');
      expect(await receiver.receiveDirectory.list().toList(), isEmpty);
    }
  });

  test(
    'receiver cancellation cannot be overwritten by a late upload',
    () async {
      final accepted = await offer([1, 2, 3], 'cancelled.bin', 'file');
      final message = receiver.messages.last;
      receiver.cancel(message);
      final upload = await request(
        'PUT',
        '/v1/upload/${accepted.response.json['token']}',
        bytes: [1, 2, 3],
      );
      expect(upload.response.statusCode, 400);
      expect(message.delivery, Delivery.cancelled);
      expect(message.path, isNull);
      expect(await receiver.receiveDirectory.exists(), isFalse);
    },
  );
}

class _Headers implements HttpHeaders {
  final values = <String, String>{};
  @override
  ContentType? contentType;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response implements HttpResponse {
  final body = StringBuffer();
  @override
  final headers = _Headers();
  @override
  int statusCode = 200;
  Map<String, dynamic> get json =>
      jsonDecode(body.toString()) as Map<String, dynamic>;
  @override
  void write(Object? object) => body.write(object);
  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ConnectionInfo implements HttpConnectionInfo {
  @override
  InternetAddress get remoteAddress => InternetAddress('192.168.1.12');
  @override
  int get remotePort => 55000;
  @override
  int get localPort => 53318;
}

class _Request extends Stream<Uint8List> implements HttpRequest {
  _Request(this.method, String path, List<int> data, int? length)
    : uri = Uri(path: path),
      contentLength = length ?? data.length,
      _stream = Stream.fromIterable([
        for (var offset = 0; offset < data.length; offset += 16384)
          Uint8List.fromList(
            data.sublist(offset, (offset + 16384).clamp(0, data.length)),
          ),
      ]);
  final Stream<Uint8List> _stream;
  @override
  final String method;
  @override
  final Uri uri;
  @override
  final int contentLength;
  @override
  final headers = _Headers();
  @override
  final _Response response = _Response();
  @override
  HttpConnectionInfo get connectionInfo => _ConnectionInfo();
  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
