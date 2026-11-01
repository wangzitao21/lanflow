import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html;

class LinkPreview {
  const LinkPreview({
    required this.url,
    required this.title,
    required this.source,
    this.description = '',
    this.image,
  });
  final Uri url;
  final String title, description, source;
  final Uri? image;
}

Future<ConnectionTask<Socket>> connectPreviewSocket(
  Uri url,
  InternetAddress address, {
  SecurityContext? context,
}) async {
  // Keep the validated address pinned, but use the original host for TLS/SNI.
  // HttpClient delegates TLS as well when a connectionFactory is supplied.
  final task = await Socket.startConnect(address, url.port);
  Socket? active;
  var cancelled = false;
  final connected = task.socket.then<Socket>((socket) async {
    active = socket;
    if (cancelled) {
      socket.destroy();
      throw const SocketException('Preview connection cancelled');
    }
    if (url.scheme == 'https') {
      try {
        active = await SecureSocket.secure(
          socket,
          host: url.host,
          context: context,
          supportedProtocols: const ['http/1.1'],
        ).timeout(const Duration(seconds: 5));
      } on Object {
        socket.destroy();
        rethrow;
      }
    }
    if (cancelled) {
      active!.destroy();
      throw const SocketException('Preview connection cancelled');
    }
    return active!;
  });
  return ConnectionTask.fromSocket(connected, () {
    cancelled = true;
    task.cancel();
    active?.destroy();
  });
}

Uri? firstMessageLink(String text) {
  for (final match in RegExp(
    r'''(?:https?://|www\.)[^\s<>"\u3000]+''',
    caseSensitive: false,
  ).allMatches(text)) {
    final value = match
        .group(0)!
        .replaceFirst(RegExp(r'[。，、；：！？,.!;:）)\]】]+$'), '');
    final uri = Uri.tryParse(
      value.startsWith('www.') ? 'https://$value' : value,
    );
    if (uri != null && isPreviewUrl(uri)) return uri;
  }
  return null;
}

bool isPublicPreviewAddress(InternetAddress address) {
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return !(bytes[0] == 0 ||
        bytes[0] == 10 ||
        bytes[0] == 127 ||
        bytes[0] >= 224 ||
        (bytes[0] == 169 && bytes[1] == 254) ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168) ||
        (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127));
  }
  // Only globally routed IPv6 unicast; reject IPv4-mapped and local ranges.
  return (bytes[0] & 0xe0) == 0x20 && !(bytes[0] == 0x20 && bytes[1] == 0x02);
}

bool isPreviewUrl(Uri uri) {
  if (!const {'https', 'http'}.contains(uri.scheme) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.toString().length > 4096) {
    return false;
  }
  final host = uri.host.toLowerCase();
  if (!host.contains('.') && !host.contains(':')) return false;
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    return false;
  }
  final address = InternetAddress.tryParse(host);
  return address == null || isPublicPreviewAddress(address);
}

LinkPreview? parseLinkPreview(String source, Uri url) {
  final document = html.parse(source);
  final metadata = <String, String>{};
  for (final element in document.querySelectorAll('meta')) {
    final key =
        (element.attributes['property'] ?? element.attributes['name'] ?? '')
            .toLowerCase();
    final value = element.attributes['content']?.trim() ?? '';
    if (value.isNotEmpty) metadata.putIfAbsent(key, () => value);
  }
  String clean(String value, int limit) => String.fromCharCodes(
    value.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(limit),
  );
  final title = clean(
    metadata['og:title'] ??
        metadata['twitter:title'] ??
        document.querySelector('title')?.text ??
        '',
    300,
  );
  if (title.isEmpty) return null;
  Uri? image;
  final imageValue =
      metadata['og:image:secure_url'] ??
      metadata['og:image'] ??
      metadata['og:image:url'] ??
      metadata['twitter:image'] ??
      metadata['twitter:image:src'];
  if (imageValue != null) {
    try {
      final resolved = url.resolve(imageValue);
      if (isPreviewUrl(resolved)) image = resolved;
    } on FormatException {
      /* Invalid metadata must not hide the original link. */
    }
  }
  return LinkPreview(
    url: url,
    title: title,
    description: clean(
      metadata['og:description'] ??
          metadata['twitter:description'] ??
          metadata['description'] ??
          '',
      500,
    ),
    source: clean(
      metadata['og:site_name'] ?? url.host.replaceFirst(RegExp(r'^www\.'), ''),
      100,
    ),
    image: image,
  );
}

class LinkPreviewService {
  LinkPreviewService({this.loader});
  static final shared = LinkPreviewService();
  final Future<LinkPreview?> Function(Uri)? loader;
  final _cache = <Uri, ({DateTime expires, Future<LinkPreview?> value})>{};
  final _images = <Uri, Future<Uint8List?>>{};
  final _queue = Queue<Completer<void>>();
  int _active = 0;

  Future<T> _limited<T>(Future<T> Function() action) async {
    if (_active >= 3) {
      final ready = Completer<void>();
      _queue.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await action();
    } finally {
      if (_queue.isNotEmpty) {
        _queue.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }

  Future<LinkPreview?> load(Uri url) {
    if (!isPreviewUrl(url)) return Future.value();
    final cached = _cache.remove(url);
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      _cache[url] = cached;
      return cached.value;
    }
    final future = _limited(() async {
      try {
        if (loader != null) return await loader!(url);
        final response = await _read(url, image: false);
        if (response == null) return null;
        return parseLinkPreview(
          utf8.decode(response.bytes, allowMalformed: true),
          response.url,
        );
      } on Object {
        return null;
      }
    });
    _cache[url] = (
      expires: DateTime.now().add(const Duration(minutes: 10)),
      value: future,
    );
    while (_cache.length > 200) {
      _cache.remove(_cache.keys.first);
    }
    return future;
  }

  Future<Uint8List?> loadImage(Uri url) {
    final cached = _images.remove(url);
    if (cached != null) {
      _images[url] = cached;
      return cached;
    }
    final future = _limited(() async => (await _read(url, image: true))?.bytes);
    _images[url] = future;
    // At most 32 bounded thumbnails; the widget also decodes to thumbnail size.
    while (_images.length > 32) {
      _images.remove(_images.keys.first);
    }
    return future;
  }

  Future<({Uint8List bytes, Uri url})?> _read(
    Uri uri, {
    required bool image,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    client.findProxy = (_) => 'DIRECT';
    client.connectionFactory = (url, _, _) async {
      final addresses = await InternetAddress.lookup(
        url.host,
      ).timeout(const Duration(seconds: 5));
      if (addresses.isEmpty ||
          addresses.any((address) => !isPublicPreviewAddress(address))) {
        throw const SocketException('Preview address is not public');
      }
      return connectPreviewSocket(url, addresses.first);
    };
    final deadline = Timer(
      const Duration(seconds: 8),
      () => client.close(force: true),
    );
    try {
      for (var redirects = 0; redirects <= 4; redirects++) {
        if (!isPreviewUrl(uri)) return null;
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'Mozilla/5.0 (compatible; LanFlow/0.1.3; link preview)',
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          image ? 'image/*' : 'text/html,application/xhtml+xml',
        );
        final response = await request.close();
        if (response.isRedirect) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          await response.listen((_) {}).cancel();
          if (location == null) return null;
          uri = uri.resolve(location);
          continue;
        }
        if (response.statusCode != 200) return null;
        final type = response.headers.contentType?.mimeType ?? '';
        if (image
            ? !type.startsWith('image/')
            : !const {'text/html', 'application/xhtml+xml'}.contains(type)) {
          return null;
        }
        final limit = image ? 2 * 1024 * 1024 : 512 * 1024;
        if (image && response.contentLength > limit) return null;
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          final remaining = limit - bytes.length;
          bytes.add(
            chunk.length > remaining ? chunk.sublist(0, remaining) : chunk,
          );
          if (bytes.length >= limit) {
            if (image) return null;
            break;
          }
        }
        return (bytes: bytes.takeBytes(), url: uri);
      }
    } on Object {
      return null;
    } finally {
      deadline.cancel();
      client.close(force: true);
    }
    return null;
  }
}
