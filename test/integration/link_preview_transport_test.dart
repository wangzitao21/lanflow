import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/network/identity.dart';
import 'package:lanflow/core/network/link_preview.dart';

void main() {
  late Directory root;
  late Identity identity;
  late HttpServer server;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('lanflow-preview-tls-');
    identity = await Identity.load(root);
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      identity.context,
    );
    server.listen((request) async {
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<title>Secure preview</title><meta property="og:description" content="TLS transport works">',
      );
      await request.response.close();
    }, onError: (Object _) {});
  });
  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test(
    'preview connector negotiates TLS using the hostname with a pinned IP',
    () async {
      final trust = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(identity.certificate));
      final client = HttpClient();
      client.findProxy = (_) => 'DIRECT';
      client.connectionFactory = (uri, _, _) => connectPreviewSocket(
        uri,
        InternetAddress.loopbackIPv4,
        context: trust,
      );
      try {
        final url = Uri(
          scheme: 'https',
          host: 'lanflow.local',
          port: server.port,
        );
        final response = await (await client.getUrl(url)).close();
        expect(response.statusCode, 200);
        final preview = parseLinkPreview(
          await utf8.decoder.bind(response).join(),
          url,
        )!;
        expect(preview.title, 'Secure preview');
        expect(preview.description, 'TLS transport works');
      } finally {
        client.close(force: true);
      }
    },
  );

  test('preview connector rejects an untrusted certificate', () async {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (uri, _, _) =>
        connectPreviewSocket(uri, InternetAddress.loopbackIPv4);
    try {
      await expectLater(
        client.getUrl(
          Uri(scheme: 'https', host: 'lanflow.local', port: server.port),
        ),
        throwsA(isA<HandshakeException>()),
      );
    } finally {
      client.close(force: true);
    }
  });
}
