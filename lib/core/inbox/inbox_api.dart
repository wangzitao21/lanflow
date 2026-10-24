import 'dart:convert';
import 'dart:io';

import 'package:lanflow/core/inbox/blob_api.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';

Future<Map<String, dynamic>> readInboxJson(
  Stream<List<int>> stream, {
  int limit = 8 * 1024 * 1024,
}) async {
  final bytes = <int>[];
  await for (final chunk in stream.timeout(const Duration(seconds: 30))) {
    if (bytes.length + chunk.length > limit) {
      throw const FormatException('响应数据过大');
    }
    bytes.addAll(chunk);
  }
  return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
}

Future<void> inboxReply(
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

// Authentication belongs to LanController. Only bound devices reach this handler.
class InboxApi {
  InboxApi(this.store, this.onChange, {this.onContentChange})
    : _blobs = BlobApi(store);
  final InboxStore store;
  final void Function() onChange;
  final void Function()? onContentChange;
  final BlobApi _blobs;

  Future<void> handle(HttpRequest request) async {
    final route = request.uri.path;
    if (route == '/v3/watch' && request.method == 'GET') {
      final after = int.tryParse(request.uri.queryParameters['after'] ?? '-1');
      if (after == null || after < -1) throw const FormatException('同步位置无效');
      final hold =
          (int.tryParse(request.uri.queryParameters['wait'] ?? '25') ?? 25)
              .clamp(5, 120);
      final cursor = await store.waitForChanges(
        after,
        timeout: Duration(seconds: hold),
      );
      await inboxReply(request, 200, {
        'cursor': cursor,
        'changed': cursor != after,
      });
      return;
    }
    if (route == '/v3/changes' && request.method == 'GET') {
      final after = int.tryParse(request.uri.queryParameters['after'] ?? '0');
      if (after == null || after < 0) throw const FormatException('同步位置无效');
      await inboxReply(
        request,
        200,
        await store.changes(
          after,
          capabilities: request.uri.queryParameters['capabilities'],
        ),
      );
      return;
    }
    if (route == '/v3/changes' && request.method == 'POST') {
      final event = await readInboxJson(request, limit: 1024 * 1024);
      final sender = request.headers.value('X-Lanflow-Device');
      if (sender != null &&
          event['type'] == 'item' &&
          event['item'] is Map &&
          event['item']['kind'] != 'text' &&
          await store.transferBlocked(
            'device:$sender',
            event['item']['sha256'] as String? ?? '',
          )) {
        await inboxReply(request, 409, {'error': '此附件已在本机暂停或取消'});
        return;
      }
      final previousCursor = store.changeCursor;
      final changed = await store.applyChange(
        event,
        source: sender == null ? null : 'device:$sender',
      );
      if (changed) onChange();
      if (store.changeCursor != previousCursor) onContentChange?.call();
      await inboxReply(request, 200, {'ok': true});
      return;
    }
    if (route == '/v2/items' && request.method == 'GET') {
      final after = int.tryParse(request.uri.queryParameters['after'] ?? '0');
      if (after == null || after < 0) throw const FormatException('同步位置无效');
      await inboxReply(request, 200, await store.itemsPage(after));
      return;
    }
    if (route == '/v2/items' && request.method == 'POST') {
      final item = InboxItem.fromJson(
        await readInboxJson(request, limit: 128 * 1024),
      );
      final existing = store.find(item.id);
      if (existing != null && !existing.item.sameContent(item)) {
        await inboxReply(request, 409, {'error': '消息编号冲突'});
        return;
      }
      if (item.isFile && !await store.hasBlob(item.digest, item.size)) {
        await inboxReply(request, 409, {'error': '文件尚未上传完整'});
        return;
      }
      final sender = request.headers.value('X-Lanflow-Device');
      final previousCursor = store.changeCursor;
      await store.add(item, source: sender == null ? null : 'device:$sender');
      onChange();
      if (store.changeCursor != previousCursor) onContentChange?.call();
      await inboxReply(request, 200, {'ok': true});
      return;
    }
    if (route.startsWith('/v2/blobs/')) {
      final digest = route.substring('/v2/blobs/'.length);
      await _blobs.handle(request, digest);
      return;
    }
    await inboxReply(request, 404, {'error': '未知的收件箱请求'});
  }
}
