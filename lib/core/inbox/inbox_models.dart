import 'dart:convert';

import 'package:lanflow/core/network/models.dart';
import 'sync_errors.dart';

export 'favorite_preferences.dart';

const hubPort = 53320;
const defaultConversationId = 'lanflow-self-chat';
const maxInboxFileBytes = 100 * 1024 * 1024 * 1024;
final inboxIdPattern = RegExp(r'^[A-Za-z0-9_-]{16,64}$');
final digestPattern = RegExp(r'^[a-f0-9]{64}$');

class MessageQuote {
  const MessageQuote({
    required this.id,
    required this.name,
    required this.text,
  });
  final String id, name, text;
  factory MessageQuote.fromItem(InboxItem item) => MessageQuote(
    id: item.id,
    name: item.originName,
    text: String.fromCharCodes(
      (item.isFile ? '[${item.kind.name}] ${item.name}' : item.text).runes.take(
        500,
      ),
    ),
  );
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'text': text};
  factory MessageQuote.fromJson(Map value) {
    final quote = MessageQuote(
      id: value['id'] as String,
      name: value['name'] as String,
      text: value['text'] as String,
    );
    if (!inboxIdPattern.hasMatch(quote.id) ||
        quote.name.length > 60 ||
        quote.text.length > 2000) {
      throw const FormatException('引用内容格式不正确');
    }
    return quote;
  }
}

class InboxItem {
  const InboxItem({
    required this.id,
    required this.originId,
    required this.originName,
    required this.createdAt,
    required this.kind,
    this.text = '',
    this.name = '',
    this.size = 0,
    this.digest = '',
    this.conversationId = defaultConversationId,
    this.quote,
    this.editHeads = const [],
  });

  final String id;
  final String originId;
  final String originName;
  final DateTime createdAt;
  final MessageKind kind;
  final String text;
  final String name;
  final int size;
  final String digest;
  final String conversationId;
  final MessageQuote? quote;
  // Local edit context travels with the displayed version, never as item data.
  final List<String> editHeads;
  bool get isFile => kind != MessageKind.text;

  Map<String, dynamic> toJson() => {
    'id': id,
    'originId': originId,
    'originName': originName,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'kind': kind.name,
    'text': text,
    'name': name,
    'size': size,
    'sha256': digest,
    if (quote != null) 'quote': quote!.toJson(),
    if (conversationId != defaultConversationId)
      'conversationId': conversationId,
  };

  factory InboxItem.fromJson(Map<String, dynamic> value) {
    final item = InboxItem(
      id: value['id'] as String,
      originId: value['originId'] as String,
      originName: value['originName'] as String,
      createdAt: DateTime.parse(value['createdAt'] as String).toUtc(),
      kind: MessageKind.values.byName(value['kind'] as String),
      text: value['text'] as String? ?? '',
      name: value['name'] as String? ?? '',
      size: value['size'] as int? ?? 0,
      digest: value['sha256'] as String? ?? '',
      quote: value['quote'] is Map
          ? MessageQuote.fromJson(value['quote'] as Map)
          : null,
      conversationId:
          value['conversationId'] as String? ?? defaultConversationId,
      editHeads: List<String>.unmodifiable(
        value['editHeads'] as List? ?? const [],
      ),
    );
    if (!inboxIdPattern.hasMatch(item.id) ||
        !inboxIdPattern.hasMatch(item.conversationId) ||
        !inboxIdPattern.hasMatch(item.originId) ||
        item.originName.isEmpty ||
        item.originName.length > 60 ||
        item.text.length > 20000 ||
        item.name.length > 512 ||
        item.size < 0 ||
        item.size > maxInboxFileBytes ||
        (item.isFile &&
            (item.name.isEmpty || !digestPattern.hasMatch(item.digest))) ||
        (!item.isFile &&
            (item.text.trim().isEmpty ||
                item.size != 0 ||
                item.digest.isNotEmpty))) {
      throw const FormatException('收件箱内容格式不正确');
    }
    return item;
  }

  bool sameContent(InboxItem other) =>
      jsonEncode(toJson()) == jsonEncode(other.toJson());
}

class Conversation {
  const Conversation(
    this.id,
    this.name, {
    this.avatar,
    this.avatarColor,
    this.appearanceConfigured = false,
  });
  final String id;
  final String name;
  final String? avatar;
  final int? avatarColor;
  final bool appearanceConfigured;
  factory Conversation.fromJson(String id, Map value) => Conversation(
    id,
    value['name'] as String,
    avatar: value['avatar'] as String?,
    avatarColor: value['avatarColor'] as int?,
    appearanceConfigured:
        value.containsKey('avatar') || value.containsKey('avatarColor'),
  );
}

class MessageEditVersion {
  MessageEditVersion.fromJson(Map value)
    : id = value['id'] as String,
      text = value['text'] as String,
      name = value['name'] as String,
      editorId = value['editorId'] as String?,
      editorName = value['editorName'] as String? ?? '旧版设备',
      editedAt = DateTime.tryParse(value['editedAt'] as String? ?? '');
  final String id, text, name, editorName;
  final String? editorId;
  final DateTime? editedAt;
}

class MessageConflict {
  MessageConflict.fromJson(Map value)
    : id = value['id'] as String,
      item = InboxItem.fromJson(
        Map<String, dynamic>.from(value['item'] as Map),
      ),
      heads = List<String>.unmodifiable(value['heads'] as List),
      versions = List<MessageEditVersion>.unmodifiable(
        (value['versions'] as List).map(
          (v) => MessageEditVersion.fromJson(v as Map),
        ),
      );
  final String id;
  final InboxItem item;
  final List<String> heads;
  final List<MessageEditVersion> versions;
}

class ConversationPreference {
  ConversationPreference({
    this.pinnedAt,
    this.readThrough = 0,
    this.manualUnread = false,
    this.hiddenThrough,
    this.avatar,
    this.avatarColor,
  });
  int? pinnedAt;
  int readThrough;
  bool manualUnread;
  int? hiddenThrough;
  String? avatar;
  int? avatarColor;

  Map<String, dynamic> toJson() => {
    'pinnedAt': pinnedAt,
    'readThrough': readThrough,
    'manualUnread': manualUnread,
    'hiddenThrough': hiddenThrough,
    'avatar': avatar,
    'avatarColor': avatarColor,
  };
  factory ConversationPreference.fromJson(Map value) => ConversationPreference(
    pinnedAt: value['pinnedAt'] as int?,
    readThrough: value['readThrough'] as int? ?? 0,
    manualUnread: value['manualUnread'] == true,
    hiddenThrough: value['hiddenThrough'] as int?,
    avatar: value['avatar'] as String?,
    avatarColor: value['avatarColor'] as int?,
  );
}

class InboxEntry {
  InboxEntry(this.sequence, this.item, [Set<String>? copies])
    : copies = copies ?? {};
  final int sequence;
  InboxItem item;
  final Set<String> copies;
  Map<String, dynamic> toJson() => {
    'sequence': sequence,
    'item': item.toJson(),
    'copies': copies.toList(),
  };
}

class SyncCursor {
  SyncCursor({this.pushed = 0, this.pulled = 0});
  int pushed;
  int pulled;
  Map<String, dynamic> toJson() => {'pushed': pushed, 'pulled': pulled};
  factory SyncCursor.fromJson(Map<String, dynamic> value) => SyncCursor(
    pushed: value['pushed'] as int? ?? 0,
    pulled: value['pulled'] as int? ?? 0,
  );
}

class SyncEndpoint {
  const SyncEndpoint({
    required this.id,
    required this.name,
    required this.url,
    required this.fingerprint,
    required this.token,
    this.deviceId,
    this.isHub = false,
  });
  final String id;
  final String name;
  final Uri url;
  final String fingerprint;
  final String token;
  final String? deviceId;
  final bool isHub;
  String get key => '${isHub ? 'hub' : 'device'}:$id';

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'url': url.toString(),
    'fingerprint': fingerprint,
    'token': token,
  };

  factory SyncEndpoint.hub(Map<String, dynamic> value) {
    final endpoint = SyncEndpoint(
      id: value['id'] as String,
      name: value['name'] as String,
      url: parseHubAddress(value['url'] as String),
      fingerprint: value['fingerprint'] as String,
      token: value['token'] as String,
      isHub: true,
    );
    if (!inboxIdPattern.hasMatch(endpoint.id) ||
        !digestPattern.hasMatch(endpoint.fingerprint) ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(endpoint.token)) {
      throw const FormatException('NAS 连接码无效');
    }
    return endpoint;
  }
}

Uri parseHubAddress(String address) {
  final value = address.trim();
  final uri = Uri.tryParse(value.contains('://') ? value : 'https://$value');
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    throw const FormatException('请输入 NAS 地址，例如 192.168.5.10:53320');
  }
  return Uri(
    scheme: 'https',
    host: uri.host,
    port: uri.hasPort ? uri.port : hubPort,
  );
}

class SyncStatus {
  bool online = false;
  bool busy = false;
  bool needsAttention = false;
  String? error;
  String? errorCategory;
  DateTime? lastSuccess;
  DateTime? retryAfter;
  int failures = 0;
  bool notificationsSupported = true;
}

class SyncTarget {
  const SyncTarget(this.key, this.name, {this.isHub = false});
  final String key;
  final String name;
  final bool isHub;
}

enum CopyState { local, waiting, syncing, paused, cancelled, failed, complete }

class TargetCopyStatus {
  const TargetCopyStatus(this.target, this.state, this.label, {this.detail});
  final SyncTarget target;
  final CopyState state;
  final String label;
  final String? detail;
}

class TransferTask {
  TransferTask.fromJson(Map<String, dynamic> value)
    : endpoint = value['endpoint'] as String,
      direction = value['direction'] as String,
      eventId = value['eventId'] as String,
      item = InboxItem.fromJson(
        Map<String, dynamic>.from(value['item'] as Map),
      ),
      transferred = value['transferred'] as int,
      state = value['state'] as String,
      error = syncErrorMessage(
        value['error'] as String?,
        value['errorCategory'] as String?,
        isHub: (value['endpoint'] as String).startsWith('hub:'),
      ),
      errorCategory = value['errorCategory'] as String?,
      retryAfter = value['retryAfter'] is int
          ? DateTime.fromMillisecondsSinceEpoch(
              (value['retryAfter'] as int) * 1000,
            )
          : null,
      completedAt = value['completedAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(value['completedAt'] as int)
          : null;
  final String endpoint;
  final String direction;
  final String eventId;
  final InboxItem item;
  final int transferred;
  final String state;
  final String? error;
  final String? errorCategory;
  final DateTime? retryAfter, completedAt;
  double bytesPerSecond = 0;
  String get key => '$endpoint:$direction:$eventId';
  bool get needsAttention =>
      state == 'failed' &&
      !const {
        'offline',
        'timeout',
        'busy',
        'source_pending',
        'paused',
        'not_ready',
      }.contains(errorCategory);
  bool get stopped => state == 'paused' || state == 'cancelled';
  double get progress => state == 'completed'
      ? 1
      : item.size == 0
      ? 0
      : (transferred / item.size).clamp(0, 1);
  String get label => switch (state) {
    'completed' => '已完成',
    'paused' => '已暂停',
    'cancelled' => '已取消',
    'failed' => '等待重试',
    _ => transferred > 0 ? '等待续传' : '等待传输',
  };
}

class FavoriteEntry {
  FavoriteEntry.fromJson(Map<String, dynamic> value)
    : id = value['snapshotId'] as String,
      originalMessageId = value['id'] as String,
      item = InboxItem.fromJson(
        Map<String, dynamic>.from(value['item'] as Map),
      ),
      savedAt = DateTime.parse(value['savedAt'] as String),
      stateEventId = value['stateEventId'] as String? ?? '',
      revision = value['revision'] as int {
    if (item.id != id) throw const FormatException('收藏快照编号不一致');
  }
  final String id;
  final String originalMessageId;
  final InboxItem item;
  final DateTime savedAt;
  final String stateEventId;
  final int revision;
}

class DeletedItem {
  DeletedItem.fromJson(Map<String, dynamic> value)
    : id = value['id'] as String? ?? (value['item'] as Map)['id'] as String,
      source = value['source'] == 'favorite' ? 'favorite' : 'conversation',
      originalMessageId = value['originalMessageId'] as String?,
      item = InboxItem.fromJson(
        Map<String, dynamic>.from(value['item'] as Map),
      ),
      deletedAt = DateTime.parse(value['deletedAt'] as String),
      available = value['available'] as bool;
  final InboxItem item;
  final String id;
  final String source;
  final String? originalMessageId;
  bool get isFavorite => source == 'favorite';
  final DateTime deletedAt;
  final bool available;
}
