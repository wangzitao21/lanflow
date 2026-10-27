import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:lanflow/core/files/file_utils.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/platform/native_core.dart';
import 'package:lanflow/core/storage/storage_layout.dart';

part 'history_store.dart';

class InboxStore {
  InboxStore(this.directory, {this.eagerHistory = false});
  final Directory directory;
  final bool eagerHistory;
  final List<InboxEntry> entries = [];
  final Map<String, InboxEntry> _byId = {};
  final List<InboxEntry> chronologicalEntries = [];
  final Map<String, List<InboxEntry>> conversationEntries = {};
  final Set<String> favorites = {};
  final List<FavoriteEntry> favoriteEntries = [];
  final List<MessageConflict> conflicts = [];
  final Map<String, FavoriteEntry> _favoritesById = {};
  final Map<String, String> _favoriteIdsByOriginal = {};
  bool linkFavoriteDeletion = true;
  FavoritePreferences _favoritePreferences = FavoritePreferences();
  FavoritePreferences get favoritePreferences => _favoritePreferences;
  set favoritePreferences(FavoritePreferences value) {
    if (_favoritePreferences == value) return;
    _favoritePreferences = value;
    favoritePreferencesRevision++;
  }

  int favoritePreferencesRevision = 0;
  int contentRevision = 0;
  int favoritesRevision = 0;
  int profilesRevision = 0;
  int conversationsRevision = 0;
  final Map<String, int> maxConversationSequence = {};
  final Map<String, String> _blobPaths = {};
  final Map<String, SyncCursor> cursors = {};
  final List<SyncEndpoint> hubs = [];
  final Set<String> migrated = {};
  Future<void> _mutations = Future.value();
  String currentConversation = defaultConversationId;
  String appearance = 'light';
  String language = 'zh';
  double composerFraction = .24;
  final Map<String, String> drafts = {};
  final Map<String, MessageQuote> draftQuotes = {};
  final Map<String, List<InboxItem>> attachmentDrafts = {};
  String get draft => drafts[currentConversation] ?? '';
  set draft(String value) => drafts[currentConversation] = value;
  bool loaded = false;
  List<InboxItem> get draftAttachments =>
      attachmentDrafts.putIfAbsent(currentConversation, () => []);
  final Map<String, Map<String, dynamic>> profiles = {};
  final Map<String, Conversation> conversations = {};
  final Map<String, ConversationPreference> conversationPreferences = {};
  final List<String> conversationOrder = [];
  int readBaseline = 0;
  ConversationPreference preference(String id) => conversationPreferences
      .putIfAbsent(id, () => ConversationPreference(readThrough: readBaseline));
  final Set<String> deleted = {};
  int revision = -1;
  int changeCursor = 0;
  Completer<void> _change = Completer<void>();
  bool _closing = false;
  bool _closedSuccessfully = false;
  Future<void>? _loadingTask;
  bool _searchIndexPending = false;
  Future<void>? _searchIndexing;
  bool pagedHistory = false;
  final Map<String, Map<String, dynamic>> _historySummaries = {};
  final Map<String, InboxEntry> _latestEntries = {};
  final Map<String, _HistoryWindow> _historyWindows = {};
  final List<String> _recentWindows = [];
  final Set<String> _residentIds = {};
  final Set<String> _lookupIds = {};
  final Set<String> _favoriteSources = {};
  final Set<Future<void>> _historyReads = {};
  final List<InboxEntry> contextEntries = [];
  String? contextTarget;
  Map<String, dynamic>? _olderContext, _newerContext;
  bool moreOlderContext = false, moreNewerContext = false;
  int _contextGeneration = 0;
  Future<void>? _contextRead;

  Future<int> waitForChanges(
    int after, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (!_closing && changeCursor == after) {
      await _change.future.timeout(timeout, onTimeout: () {});
    }
    return changeCursor;
  }

  void _appearance(Map state) {
    linkFavoriteDeletion = true;
    language = state['language'] == 'en' ? 'en' : 'zh';
    final value = state['appearance'];
    appearance = const {'light', 'dark', 'system'}.contains(value)
        ? value as String
        : 'light';
    composerFraction = ((state['composerFraction'] as num?)?.toDouble() ?? .24)
        .clamp(.18, .6);
  }

  Future<void> loadPreferences() async => _appearance(
    await NativeCore.run({'op': 'preferences', 'root': directory.path}) as Map,
  );

  Future<void> load({void Function(int loaded, int total)? onProgress}) async {
    if (_loadingTask != null) return _loadingTask!;
    final task = _load(onProgress: onProgress);
    _loadingTask = task;
    try {
      await task;
    } finally {
      _loadingTask = null;
    }
  }

  Future<void> _load({void Function(int loaded, int total)? onProgress}) async {
    loaded = false;
    _closedSuccessfully = false;
    _closing = false;
    if (_change.isCompleted) _change = Completer<void>();
    final state = Map<String, dynamic>.from(
      await NativeCore.run({'op': 'open_paged', 'root': directory.path}) as Map,
    );
    final bootstrap = state['bootstrap'] as Map;
    _searchIndexPending = state['searchIndexPending'] == true;
    final total = bootstrap['count'] as int;
    pagedHistory = !eagerHistory && total > 1000;
    final initialEntries = <InboxEntry>[];
    Map? cursor;
    onProgress?.call(0, total);
    if (total > 0 && !pagedHistory) {
      while (true) {
        final page =
            await NativeCore.run({
                  'op': 'bootstrap_entries',
                  'root': directory.path,
                  'upper': bootstrap['upper'],
                  'after': cursor,
                })
                as Map;
        for (final record in page['entries'] as List) {
          initialEntries.add(
            InboxEntry(
              record['sequence'] as int,
              InboxItem.fromJson(
                Map<String, dynamic>.from(record['item'] as Map),
              ),
              Set<String>.from(record['copies'] as List? ?? []),
            ),
          );
        }
        onProgress?.call(initialEntries.length, total);
        if (page['more'] != true) break;
        final next = page['cursor'] as Map?;
        if (next == null ||
            (cursor != null &&
                next['sequence'] == cursor['sequence'] &&
                next['id'] == cursor['id'])) {
          throw StateError('聊天记录分页未能前进');
        }
        cursor = next;
        await Future<void>.delayed(Duration.zero);
      }
    }
    applySnapshot(state, initialEntries: initialEntries);
    state.remove('blobPaths');
    cursors.clear();
    for (final entry in (state['cursors'] as Map? ?? {}).entries) {
      cursors[entry.key as String] = SyncCursor.fromJson(
        Map<String, dynamic>.from(entry.value as Map),
      );
    }
    hubs
      ..clear()
      ..addAll(
        (state['hubs'] as List? ?? []).map(
          (v) => SyncEndpoint.hub(Map<String, dynamic>.from(v as Map)),
        ),
      );
    migrated
      ..clear()
      ..addAll(List<String>.from(state['migrated'] as List? ?? []));
    _appearance(state);
    favoritePreferences = FavoritePreferences.fromJson(
      state['favoritePreferences'],
    );
    currentConversation =
        state['currentConversation'] as String? ?? defaultConversationId;
    conversationOrder
      ..clear()
      ..addAll(
        (state['conversationOrder'] as List? ?? const [])
            .whereType<String>()
            .where(inboxIdPattern.hasMatch)
            .toSet(),
      );
    drafts
      ..clear()
      ..addAll(
        Map<String, String>.from(
          state['drafts'] as Map? ??
              {defaultConversationId: state['draft'] as String? ?? ''},
        ),
      );
    attachmentDrafts.clear();
    draftQuotes
      ..clear()
      ..addAll({
        for (final entry in (state['draftQuotes'] as Map? ?? {}).entries)
          entry.key as String: MessageQuote.fromJson(entry.value as Map),
      });
    final savedImages =
        state['imageDrafts'] as Map? ??
        {defaultConversationId: state['draftImages'] as List? ?? []};
    for (final entry in savedImages.entries) {
      attachmentDrafts[entry.key as String] = (entry.value as List)
          .map((v) => InboxItem.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();
    }
    readBaseline = state['readBaseline'] as int? ?? bootstrap['upper'] as int;
    conversationPreferences
      ..clear()
      ..addAll({
        for (final entry
            in (state['conversationPreferences'] as Map? ?? {}).entries)
          entry.key as String: ConversationPreference.fromJson(
            entry.value as Map,
          ),
      });
    if (pagedHistory) {
      await loadConversation(currentConversation);
      await loadEntries(draftQuotes.values.map((quote) => quote.id));
      onProgress?.call(entries.length, total);
    }
    await refresh();
    loaded = true;
  }

  void applySnapshot(
    Map<String, dynamic> state, {
    List<InboxEntry>? initialEntries,
  }) {
    _readBlobPaths(state['blobPaths']);
    for (final record in state['entries'] as List? ?? []) {
      final path = record['blobPath'];
      if (path is String) _readBlobPaths({record['item']['sha256']: path});
    }
    final cursor = state['changeCursor'] as int? ?? changeCursor;
    if (cursor > changeCursor) {
      changeCursor = cursor;
      final previous = _change;
      _change = Completer<void>();
      previous.complete();
    }
    final incomingRevision = state['revision'] as int? ?? 0;
    if (incomingRevision <= revision || state['unchanged'] == true) return;
    if (state['conflicts'] is List) {
      conflicts
        ..clear()
        ..addAll(
          (state['conflicts'] as List).map(
            (value) => MessageConflict.fromJson(value as Map),
          ),
        );
    }
    if (state['delta'] == true) {
      _applyDelta(state);
      _readHistorySummaries(state['history']);
      revision = incomingRevision;
      return;
    }
    final next = initialEntries ?? <InboxEntry>[];
    final byId = <String, InboxEntry>{
      for (final entry in next) entry.item.id: entry,
    };
    for (final record in state['entries'] as List? ?? []) {
      final data = record['item'] as Map;
      final entry =
          _byId[data['id']] ??
          InboxEntry(
            record['sequence'] as int,
            InboxItem.fromJson(Map<String, dynamic>.from(data)),
          );
      entry.item = InboxItem.fromJson(Map<String, dynamic>.from(data));
      entry.copies
        ..clear()
        ..addAll(List<String>.from(record['copies'] as List? ?? []));
      next.add(entry);
      byId[entry.item.id] = entry;
    }
    // Publish one complete snapshot, never an intermediate empty history.
    entries
      ..clear()
      ..addAll(next);
    chronologicalEntries
      ..clear()
      ..addAll(next)
      ..sort(_compareEntries);
    conversationEntries.clear();
    maxConversationSequence.clear();
    for (final entry in chronologicalEntries) {
      (conversationEntries[entry.item.conversationId] ??= []).add(entry);
      _recordSequence(entry);
    }
    contentRevision++;
    _readFavorites(state['favorites'] as Map? ?? {}, replace: true);
    favoritesRevision++;
    profilesRevision++;
    conversationsRevision++;
    _byId
      ..clear()
      ..addAll(byId);
    profiles
      ..clear()
      ..addAll(
        (state['profiles'] as Map? ?? {}).map(
          (key, value) =>
              MapEntry(key as String, Map<String, dynamic>.from(value as Map)),
        ),
      );
    conversations
      ..clear()
      ..addAll({
        for (final entry in (state['conversations'] as Map? ?? {}).entries)
          entry.key as String: Conversation.fromJson(
            entry.key as String,
            entry.value as Map,
          ),
      });
    deleted
      ..clear()
      ..addAll(List<String>.from(state['deleted'] as List? ?? []));
    revision = incomingRevision;
    _readHistorySummaries(state['history'], replace: true);
  }

  void _applyDelta(Map<String, dynamic> state) {
    if ((state['baseRevision'] as int) > revision) {
      throw StateError('收件箱更新缺少前序状态');
    }
    final removed = List<String>.from(state['removed'] as List? ?? []).toSet();
    for (final id in removed) {
      _byId.remove(id);
      _residentIds.remove(id);
      _lookupIds.remove(id);
      _favoriteSources.remove(id);
    }
    contextEntries.removeWhere((entry) => removed.contains(entry.item.id));
    if (removed.isNotEmpty) {
      entries.removeWhere((entry) => removed.contains(entry.item.id));
      chronologicalEntries.removeWhere(
        (entry) => removed.contains(entry.item.id),
      );
      for (final group in conversationEntries.values) {
        group.removeWhere((entry) => removed.contains(entry.item.id));
      }
      conversationEntries.removeWhere((_, items) => items.isEmpty);
      contentRevision++;
    }
    for (final record in state['entries'] as List? ?? []) {
      final data = Map<String, dynamic>.from(record['item'] as Map);
      var entry = _byId[data['id']];
      if (entry != null &&
          (entry.item.text != data['text'] ||
              entry.item.name != data['name'] ||
              entry.item.editHeads.join(',') !=
                  (data['editHeads'] as List? ?? const []).join(','))) {
        // Keep shared row/context references, while invalidating text, search
        // and layout caches when an edit changes an existing message.
        entry.item = InboxItem.fromJson(data);
        contentRevision++;
      }
      if (favorites.contains(data['id'])) {
        _favoriteSources.add(data['id'] as String);
      }
      if (pagedHistory && entry == null && !_cacheDeltaItem(data)) continue;
      if (entry == null ||
          (pagedHistory &&
              !_residentIds.contains(entry.item.id) &&
              _cacheDeltaItem(data))) {
        entry ??= InboxEntry(
          record['sequence'] as int,
          InboxItem.fromJson(data),
        );
        _byId[entry.item.id] = entry;
        _residentIds.add(entry.item.id);
        _lookupIds.remove(entry.item.id);
        var low = 0;
        var high = entries.length;
        while (low < high) {
          final mid = (low + high) ~/ 2;
          if (entries[mid].sequence < entry.sequence) {
            low = mid + 1;
          } else {
            high = mid;
          }
        }
        entries.insert(low, entry);
        _insertChronological(chronologicalEntries, entry);
        _insertChronological(
          conversationEntries.putIfAbsent(entry.item.conversationId, () => []),
          entry,
        );
        _recordSequence(entry);
        contentRevision++;
      }
      entry.copies
        ..clear()
        ..addAll(List<String>.from(record['copies'] as List? ?? []));
    }
    for (final entry in (state['profiles'] as Map? ?? {}).entries) {
      profiles[entry.key as String] = Map<String, dynamic>.from(
        entry.value as Map,
      );
    }
    if ((state['profiles'] as Map?)?.isNotEmpty == true) profilesRevision++;
    for (final entry in (state['conversations'] as Map? ?? {}).entries) {
      conversations[entry.key as String] = Conversation.fromJson(
        entry.key as String,
        entry.value as Map,
      );
    }
    if ((state['conversations'] as Map?)?.isNotEmpty == true) {
      conversationsRevision++;
    }
    deleted.addAll(List<String>.from(state['deleted'] as List? ?? []));
    final changedFavorites = state['favorites'] as Map? ?? {};
    _readFavorites(changedFavorites);
    if (changedFavorites.isNotEmpty) favoritesRevision++;
  }

  static int _compareEntries(InboxEntry a, InboxEntry b) {
    final time = b.item.createdAt.compareTo(a.item.createdAt);
    return time == 0 ? b.item.id.compareTo(a.item.id) : time;
  }

  void _readFavorites(Map values, {bool replace = false}) {
    if (replace) {
      favorites.clear();
      _favoritesById.clear();
      _favoriteIdsByOriginal.clear();
      _favoriteSources.clear();
    }
    var changed = replace;
    for (final record in values.entries) {
      final original = record.key as String;
      final value = Map<String, dynamic>.from(record.value as Map);
      if (value['sourceExists'] == true) _favoriteSources.add(original);
      if (value['sourceExists'] == false) _favoriteSources.remove(original);
      if (value['item'] is Map && value['blobPath'] is String) {
        _readBlobPaths({(value['item'] as Map)['sha256']: value['blobPath']});
      }
      if (value['value'] == true) {
        favorites.add(original);
        if (value['item'] is Map &&
            value['snapshotId'] is String &&
            value['savedAt'] is String) {
          final next = FavoriteEntry.fromJson(value);
          final existing = _favoritesById[next.id];
          if (existing == null ||
              existing.revision != next.revision ||
              existing.stateEventId != next.stateEventId ||
              !existing.item.sameContent(next.item)) {
            _favoritesById[next.id] = next;
            _favoriteIdsByOriginal[original] = next.id;
            changed = true;
          }
        }
      } else {
        favorites.remove(original);
        final id = _favoriteIdsByOriginal.remove(original);
        if (id != null) changed = _favoritesById.remove(id) != null || changed;
      }
    }
    if (changed) {
      favoriteEntries
        ..clear()
        ..addAll(_favoritesById.values)
        ..sort((a, b) {
          final order = b.savedAt.compareTo(a.savedAt);
          return order == 0 ? b.id.compareTo(a.id) : order;
        });
    }
  }

  FavoriteEntry? findFavorite(String id) => _favoritesById[id];

  void _recordSequence(InboxEntry entry) {
    final id = entry.item.conversationId;
    if (entry.sequence > (maxConversationSequence[id] ?? 0)) {
      maxConversationSequence[id] = entry.sequence;
    }
  }

  Future<Map<String, dynamic>> searchMessages(
    Map<String, dynamic> query,
  ) async {
    final result = Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'search_messages',
            'root': directory.path,
            ...query,
          })
          as Map,
    );
    if (pagedHistory) {
      await loadEntries(List<String>.from(result['ids'] as List));
    }
    return result;
  }

  static void _insertChronological(List<InboxEntry> list, InboxEntry entry) {
    var low = 0;
    var high = list.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (_compareEntries(list[mid], entry) <= 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    list.insert(low, entry);
  }

  Future<void> setFavorites(Iterable<String> ids, bool value) async =>
      applySnapshot(
        Map<String, dynamic>.from(
          await NativeCore.run({
                'op': 'set_favorites',
                'root': directory.path,
                'ids': ids.toSet().toList(),
                'value': value,
                'knownRevision': revision,
              })
              as Map,
        ),
      );

  Future<void> deleteFavorites(Iterable<String> ids) async => applySnapshot(
    Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'delete_favorites',
            'root': directory.path,
            'ids': ids.toSet().toList(),
            'knownRevision': revision,
          })
          as Map,
    ),
  );

  Future<void> restoreFavorites(Iterable<String> ids) async => applySnapshot(
    Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'restore_favorites',
            'root': directory.path,
            'ids': ids.toSet().toList(),
            'knownRevision': revision,
          })
          as Map,
    ),
  );

  Future<void> refresh() async => applySnapshot(
    Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'snapshot',
            'root': directory.path,
            'knownRevision': revision,
          })
          as Map,
    ),
  );
  Future<void> remove(String id) async => applySnapshot(
    Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'delete',
            'root': directory.path,
            'id': id,
            'knownRevision': revision,
          })
          as Map,
    ),
  );
  Future<void> editMessage(
    String id, {
    required String text,
    String name = '',
    List<String>? parents,
    String? editorId,
    String? editorName,
  }) async => applySnapshot(
    Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'edit_message',
            'root': directory.path,
            'id': id,
            'text': text,
            'name': name,
            'parents': ?parents,
            'editorId': ?editorId,
            'editorName': ?editorName,
            'knownRevision': revision,
          })
          as Map,
    ),
  );
  Future<void> resolveMessage(
    MessageConflict conflict, {
    String? versionId,
    String? text,
    String? name,
    required String editorId,
    required String editorName,
  }) async => applySnapshot(
    Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'resolve_message',
            'root': directory.path,
            'id': conflict.id,
            'heads': conflict.heads,
            'versionId': ?versionId,
            'text': ?text,
            'name': ?name,
            'editorId': editorId,
            'editorName': editorName,
            'knownRevision': revision,
          })
          as Map,
    ),
  );
  Future<List<DeletedItem>> recentlyDeleted() async =>
      (await NativeCore.run({'op': 'trash', 'root': directory.path}) as List)
          .map((v) => DeletedItem.fromJson(Map<String, dynamic>.from(v as Map)))
          .toList();

  Future<Map<String, dynamic>> deletedPage({
    Map<String, dynamic>? after,
    String query = '',
  }) async => Map<String, dynamic>.from(
    await NativeCore.run({
          'op': 'trash_page',
          'root': directory.path,
          'after': after,
          'query': query,
        })
        as Map,
  );

  Future<void> removeMany(Iterable<String> ids) async => applySnapshot(
    Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'delete_many',
            'root': directory.path,
            'ids': ids.toSet().toList(),
            'knownRevision': revision,
          })
          as Map,
    ),
  );

  Future<void> restore(String id, {String source = 'conversation'}) async =>
      applySnapshot(
        Map<String, dynamic>.from(
          await NativeCore.run({
                'op': 'restore',
                'root': directory.path,
                'id': id,
                'source': source,
                'knownRevision': revision,
              })
              as Map,
        ),
      );

  Future<Map<String, dynamic>> storageStats({
    bool clearPreviews = false,
  }) async => Map<String, dynamic>.from(
    await NativeCore.run({
          'op': clearPreviews ? 'clear_preview_cache' : 'storage_stats',
          'root': directory.path,
        })
        as Map,
  );

  Future<List<Map<String, dynamic>>> transfers() async =>
      (await NativeCore.run({'op': 'transfers', 'root': directory.path})
              as List)
          .map((v) => Map<String, dynamic>.from(v as Map))
          .toList();

  Future<Map<String, dynamic>> transferUpdates(
    Set<String> endpoints,
    int after, {
    int? initialThrough,
  }) async => Map<String, dynamic>.from(
    await NativeCore.run({
          'op': 'transfer_updates',
          'root': directory.path,
          'endpoints': endpoints.toList(),
          'after': after,
          'initialThrough': ?initialThrough,
        })
        as Map,
  );

  Future<Map<String, dynamic>> transferHistory({int offset = 0}) async =>
      Map<String, dynamic>.from(
        await NativeCore.run({
              'op': 'transfers_page',
              'root': directory.path,
              'scope': 'completed',
              'offset': offset,
              'limit': 50,
            })
            as Map,
      );

  Future<void> transferAction(TransferTask task, String action) async {
    await NativeCore.run({
      'op': 'transfer_action',
      'root': directory.path,
      'endpoint': task.endpoint,
      'direction': task.direction,
      'eventId': task.eventId,
      'action': action,
    });
  }

  Future<bool> transferBlocked(String endpoint, String digest) async =>
      await NativeCore.run({
            'op': 'transfer_blocked',
            'root': directory.path,
            'endpoint': endpoint,
            'digest': digest,
          })
          as bool;

  Future<void> setConversation(
    String id,
    String name, {
    bool appearance = false,
    String? avatar,
    int? avatarColor,
  }) async => applySnapshot(
    Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'conversation',
            'knownRevision': revision,
            'root': directory.path,
            'id': id,
            'name': name,
            if (appearance) 'avatar': avatar,
            if (appearance) 'avatarColor': avatarColor,
          })
          as Map,
    ),
  );
  Future<void> migrateConversationAvatars() async {
    var changed = false;
    for (final entry in conversationPreferences.entries.toList()) {
      final old = entry.value;
      if (old.avatar == null && old.avatarColor == null) continue;
      final current = conversations[entry.key];
      if (current?.appearanceConfigured != true) {
        await setConversation(
          entry.key,
          current?.name ??
              (entry.key == defaultConversationId ? '发给自己' : '同步中的会话'),
          appearance: true,
          avatar: old.avatar,
          avatarColor: old.avatarColor,
        );
      }
      old
        ..avatar = null
        ..avatarColor = null;
      changed = true;
    }
    if (changed) await save();
  }

  Future<void> setProfile(
    String id,
    String name, {
    String? avatar,
    bool appearance = false,
    String? preset,
    int? color,
  }) async => applySnapshot(
    Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'profile',
            'knownRevision': revision,
            'root': directory.path,
            'id': id,
            'name': name,
            'avatar': ?avatar,
            if (appearance) 'avatarPreset': preset,
            if (appearance) 'avatarColor': color,
          })
          as Map,
    ),
  );
  Future<Map<String, dynamic>> deletions(int after) async =>
      Map<String, dynamic>.from(
        await NativeCore.run({
              'op': 'deletions',
              'root': directory.path,
              'after': after,
            })
            as Map,
      );

  Future<Map<String, dynamic>> changes(
    int after, {
    String? capabilities,
  }) async => Map<String, dynamic>.from(
    await NativeCore.run({
          'op': 'page',
          'root': directory.path,
          'after': after,
          'capabilities': capabilities,
        })
        as Map,
  );
  Future<bool> applyChange(Map<String, dynamic> event, {String? source}) async {
    final result =
        await NativeCore.run({
              'op': 'apply',
              'knownRevision': revision,
              'root': directory.path,
              'event': event,
              'source': ?source,
            })
            as Map;
    applySnapshot(Map<String, dynamic>.from(result));
    return result['changed'] == true;
  }

  Future<bool> applyChanges(
    List<Map<String, dynamic>> events, {
    String? source,
  }) async {
    final result =
        await NativeCore.run({
              'op': 'apply_batch',
              'root': directory.path,
              'knownRevision': revision,
              'events': events,
              'source': ?source,
            })
            as Map;
    applySnapshot(Map<String, dynamic>.from(result));
    return result['changed'] == true;
  }

  Future<Map<String, dynamic>> itemsPage(int after) async =>
      Map<String, dynamic>.from(
        await NativeCore.run({
              'op': 'items_page',
              'root': directory.path,
              'after': after,
            })
            as Map,
      );

  Future<Map<String, dynamic>> importFile(
    String path, {
    String? name,
    String? kind,
  }) async {
    final imported = Map<String, dynamic>.from(
      await NativeCore.run({
            'op': 'import_file',
            'root': directory.path,
            'path': path,
            'name': ?name,
            'kind': ?kind,
          })
          as Map,
    );
    if (imported['path'] is String) {
      _readBlobPaths({imported['sha256']: imported['path']});
    }
    return imported;
  }

  void _readBlobPaths(dynamic value) {
    if (value is! Map) return;
    for (final entry in value.entries) {
      if (entry.key is! String ||
          !digestPattern.hasMatch(entry.key as String) ||
          entry.value is! String) {
        continue;
      }
      final relative = (entry.value as String).replaceAll('\\', '/');
      final parts = relative.split('/');
      if (parts.length != 2 ||
          !const {'media', 'files'}.contains(parts.first) ||
          parts.last.isEmpty ||
          const {'.', '..'}.contains(parts.last)) {
        throw const FormatException('附件索引路径无效');
      }
      _blobPaths[entry.key as String] = p.join(
        directory.path,
        parts.first,
        parts.last,
      );
    }
  }

  InboxEntry? find(String id) => _byId[id];

  File blob(String digest) {
    if (!digestPattern.hasMatch(digest)) throw const FormatException('文件编号无效');
    return File(_blobPaths[digest] ?? StorageLayout.pending(directory, digest));
  }

  Future<bool> hasBlob(String digest, [int? size]) async {
    final file = blob(digest);
    return await file.exists() && (size == null || await file.length() == size);
  }

  Future<String> storeBlob(
    Stream<List<int>> stream,
    int size, {
    String? digest,
  }) async {
    if (size < 0 || size > maxInboxFileBytes) {
      throw const FormatException('文件大小超出限制');
    }
    final temp = File(
      p.join(StorageLayout.incoming(directory).path, '${randomToken(18)}.part'),
    );
    RandomAccessFile? output;
    var count = 0;
    try {
      output = await temp.open(mode: FileMode.write);
      await for (final chunk in stream.timeout(const Duration(seconds: 45))) {
        count += chunk.length;
        if (count > size) throw const FormatException('文件大小超出声明值');
        await output.writeFrom(chunk);
      }
      await output.flush();
      await output.close();
      output = null;
      if (count != size) throw const FormatException('文件未完整传输，稍后自动重试');
      return await NativeCore.run({
            'op': 'blob_commit',
            'root': directory.path,
            'path': temp.path,
            'size': size,
            'digest': digest,
          })
          as String;
    } finally {
      await output?.close();
      if (await temp.exists()) await temp.delete();
    }
  }

  Future<InboxEntry> add(InboxItem item, {String? source}) {
    final result = Completer<InboxEntry>();
    _mutations = _mutations.then((_) async {
      try {
        final state =
            await NativeCore.run({
                  'op': 'add',
                  'knownRevision': revision,
                  'root': directory.path,
                  'item': item.toJson(),
                  'source': ?source,
                })
                as Map;
        applySnapshot(Map<String, dynamic>.from(state));
        result.complete(find(item.id) ?? InboxEntry(0, item));
      } on Object catch (e, stack) {
        result.completeError(
          e is StateError ? FormatException(e.message) : e,
          stack,
        );
      }
    });
    return result.future;
  }

  Future<void> save() async {
    if (!loaded) throw StateError('请等待本机收件箱启动完成');
    final paths = await NativeCore.run({
      'op': 'save_meta',
      'root': directory.path,
      'value': {
        'hubs': hubs.map((hub) => hub.toJson()).toList(),
        'migrated': migrated.toList(),
        'drafts': drafts,
        'draftQuotes': draftQuotes.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
        // Keep the on-disk key compatible with existing image-only drafts.
        'imageDrafts': attachmentDrafts.map(
          (id, images) =>
              MapEntry(id, images.map((item) => item.toJson()).toList()),
        ),
        'currentConversation': currentConversation,
        'conversationOrder': List<String>.of(conversationOrder),
        'appearance': appearance,
        'language': language,
        'linkFavoriteDeletion': linkFavoriteDeletion,
        'favoritePreferences': favoritePreferences.toJson(),
        'composerFraction': composerFraction,
        'readBaseline': readBaseline,
        'conversationPreferences': conversationPreferences.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      },
    });
    _readBlobPaths(paths);
  }

  Future<File> fileForOpening(InboxItem item) async {
    final original = await fileForExport(item);
    final folder = Directory(
      p.join(StorageLayout.previews(directory).path, item.id),
    );
    await folder.create(recursive: true);
    final result = File(p.join(folder.path, safeFileName(item.name)));
    if (!await result.exists() || await result.length() != item.size) {
      await original.copy(result.path);
    }
    return result;
  }

  Future<File> fileForExport(InboxItem item) async {
    if (!item.isFile || !await hasBlob(item.digest, item.size)) {
      throw const FileSystemException('文件尚未下载完成');
    }
    return blob(item.digest);
  }

  Future<void> flush() async {
    if (!loaded) return;
    await _mutations;
    await save();
  }

  Future<void> close() async {
    _closedSuccessfully = false;
    _closing = true;
    await _loadingTask;
    await Future.wait(_historyReads.toList());
    await _searchIndexing?.catchError((Object _) {});
    if (!_change.isCompleted) _change.complete();
    await flush();
    await NativeCore.run({'op': 'close', 'root': directory.path});
    loaded = false;
    _closedSuccessfully = true;
  }

  // Host widgets and startup callbacks may still reference a retired session.
  // Keep close() observable and preserve all failed-save recovery state; only
  // disposal after a complete close releases the persisted history caches.
  bool releaseClosedHistory() {
    if (!_closedSuccessfully) return false;
    entries.clear();
    _byId.clear();
    chronologicalEntries.clear();
    conversationEntries.clear();
    maxConversationSequence.clear();
    _blobPaths.clear();
    favorites.clear();
    favoriteEntries.clear();
    conflicts.clear();
    _favoritesById.clear();
    _favoriteIdsByOriginal.clear();
    deleted.clear();
    profiles.clear();
    conversations.clear();
    _historySummaries.clear();
    _latestEntries.clear();
    _historyWindows.clear();
    _recentWindows.clear();
    _residentIds.clear();
    _lookupIds.clear();
    _favoriteSources.clear();
    contextEntries.clear();
    revision = -1;
    changeCursor = 0;
    return true;
  }
}
