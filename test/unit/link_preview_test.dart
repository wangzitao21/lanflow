import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanflow/core/network/link_preview.dart';

void main() {
  test(
    'extracts shared links and decodes Open Graph attributes and relative covers',
    () {
      final url = firstMessageLink('推荐看看 https://example.com/articles/123）。')!;
      expect(url.toString(), 'https://example.com/articles/123');
      final result = parseLinkPreview('''<html><head><title>Fallback</title>
      <meta content="研究 &amp; 水文" property="og:title">
      <meta name='description' content='  第一段\n 第二段  '>
      <meta property="og:site_name" content="研究所">
      <meta property="og:image" content="../cover.jpg">
      <meta property="og:title" content="Do not replace first title">
      </head></html>''', url)!;
      expect(result.title, '研究 & 水文');
      expect(result.description, '第一段 第二段');
      expect(result.source, '研究所');
      expect(result.image.toString(), 'https://example.com/cover.jpg');
    },
  );
  test(
    'falls back to Twitter metadata or title and rejects unsafe image targets',
    () {
      final url = Uri.parse('https://example.com');
      expect(
        parseLinkPreview(
          '<meta name="twitter:title" content="Video"><meta name="twitter:image" content="file:///private.png">',
          url,
        )!.image,
        isNull,
      );
      expect(parseLinkPreview('<title>A &lt; B</title>', url)!.title, 'A < B');
      expect(parseLinkPreview('<p>No metadata</p>', url), isNull);
      for (final address in [
        '127.0.0.1',
        '10.1.2.3',
        '172.16.0.1',
        '192.168.5.1',
        '169.254.169.254',
        '100.64.0.1',
        '::1',
        'fc00::1',
        '::ffff:127.0.0.1',
      ]) {
        expect(
          isPublicPreviewAddress(InternetAddress(address)),
          isFalse,
          reason: address,
        );
      }
      expect(firstMessageLink('http://127.0.0.1/private'), isNull);
      expect(firstMessageLink('https://user:secret@example.com'), isNull);
      expect(isPublicPreviewAddress(InternetAddress('8.8.8.8')), isTrue);
      expect(
        isPublicPreviewAddress(InternetAddress('2606:4700:4700::1111')),
        isTrue,
      );
    },
  );
  test('deduplicates requests and contains provider failures', () async {
    var calls = 0;
    final gate = Completer<LinkPreview?>();
    final service = LinkPreviewService(
      loader: (_) {
        calls++;
        return gate.future;
      },
    );
    final url = Uri.parse('https://example.com/post');
    final a = service.load(url);
    final b = service.load(url);
    gate.complete(null);
    expect(await a, isNull);
    expect(await b, isNull);
    expect(calls, 1);
    expect(
      await LinkPreviewService(
        loader: (_) => throw const SocketException('offline'),
      ).load(url),
      isNull,
    );
  });
}
