import 'dart:io';

import 'package:lanflow/core/inbox/inbox_api.dart' show inboxReply;
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/platform/native_core.dart';

// Dart owns HTTP streams; the shared core owns offsets, checksums, writer
// exclusion and durable commits. File bytes never cross the JSON FFI bridge.
class BlobApi {
  BlobApi(this.store);
  final InboxStore store;

  Future<Map<String, dynamic>> _call(Map<String, dynamic> request) async =>
      Map<String, dynamic>.from(
        await NativeCore.run({...request, 'root': store.directory.path}) as Map,
      );

  Future<void> handle(HttpRequest request, String digest) async {
    try {
      final sender = request.headers.value('X-Lanflow-Device');
      if (sender != null &&
          await store.transferBlocked('device:$sender', digest)) {
        await inboxReply(request, 409, {'error': '此附件已在另一端暂停或取消'});
        return;
      }
      request.response.headers.set('X-Lanflow-Resumable', '1');
      request.response.headers.set('Accept-Ranges', 'bytes');
      if (request.method == 'GET' || request.method == 'HEAD') {
        await _read(request, digest);
      } else if (request.method == 'PUT') {
        await _upload(request, digest);
      } else {
        await inboxReply(request, 405, {'error': '不支持的文件请求'});
      }
    } on NativeCoreError catch (error) {
      await inboxReply(request, error.status, {'error': error.message});
    }
  }

  Future<void> _read(HttpRequest request, String digest) async {
    final sizeText = request.uri.queryParameters['size'];
    final size = sizeText == null ? null : int.tryParse(sizeText);
    if (sizeText != null &&
        (size == null || size < 0 || size > maxInboxFileBytes)) {
      throw const FormatException('文件大小无效');
    }
    final spec = await _call({
      'op': 'blob_read',
      'digest': digest,
      'size': size,
      'range': request.headers.value(HttpHeaders.rangeHeader),
      'head': request.method == 'HEAD',
    });
    final response = request.response;
    response.statusCode = spec['status'] as int;
    response.contentLength = spec['length'] as int;
    response.headers.contentType = ContentType.binary;
    if (spec['offset'] != null) {
      response.headers.set('X-Lanflow-Offset', spec['offset']);
    }
    if (spec['contentRange'] != null) {
      response.headers.set('Content-Range', spec['contentRange']);
    }
    if (request.method == 'GET' && spec['path'] != null) {
      await response.addStream(
        File(
          spec['path'] as String,
        ).openRead(spec['start'] as int, spec['end'] as int),
      );
    }
    await response.close();
  }

  Future<void> _upload(HttpRequest request, String digest) async {
    final upload = await _call({
      'op': 'blob_begin',
      'digest': digest,
      'length': request.contentLength,
      'range': request.headers.value('Content-Range'),
    });
    RandomAccessFile? output;
    try {
      output = await File(upload['path'] as String).open(mode: FileMode.write);
      var received = 0;
      await for (final bytes in request.timeout(const Duration(seconds: 30))) {
        received += bytes.length;
        if (received > request.contentLength) {
          throw const FormatException('文件超出声明长度');
        }
        await output.writeFrom(bytes);
      }
      await output.flush();
      await output.close();
      output = null;
      final result = await _call({'op': 'blob_finish', 'id': upload['id']});
      await inboxReply(request, 200, result);
    } finally {
      await output?.close();
      await NativeCore.run({'op': 'blob_abort', 'id': upload['id']});
    }
  }
}
