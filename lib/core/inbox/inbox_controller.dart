import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'package:lanflow/core/files/file_utils.dart';
import 'package:lanflow/core/inbox/inbox_api.dart';
import 'package:lanflow/core/inbox/inbox_models.dart';
import 'package:lanflow/core/inbox/inbox_store.dart';
import 'package:lanflow/core/inbox/inbox_sync.dart';
import 'package:lanflow/core/inbox/sync_watch.dart';
import 'sync_retry_policy.dart';
import 'sync_progress.dart';
import 'sync_errors.dart';
import 'package:lanflow/core/network/network_state.dart';
import 'package:lanflow/core/network/lan_controller.dart';
import 'package:lanflow/core/network/models.dart';
import 'package:lanflow/platform/native_core.dart';

part 'legacy_import.dart';
part 'sync_runtime.dart';
part 'sync_connections.dart';
part 'search_runtime.dart';

class InboxController extends ChangeNotifier {
  InboxController({
    required this.lan,
    required this.store,
    this.automaticSync = true,
  }) {
    _sync = InboxSync(store, _receivedChanges);
    _progress = SyncProgress(_sampleTransferProgress);
    lan.transferActivity.addListener(_activityChanged);
  }
  final LanController lan;
  final InboxStore store;
  final bool automaticSync;
  late final InboxSync _sync;
  final Map<String, SyncStatus> statuses = {};
  final Map<String, SyncWatch> _watches = {};
  final Set<String> _pendingSync = {};
  final Map<String, int> _pendingPulls = {};
  int _pullGeneration = 0;
  void _expectRemoteChanges(String key) {
    _pendingPulls[key] = ++_pullGeneration;
  }

  final Map<String, int> _requestedContent = {};
  Timer? _kick;
  Timer? _retryTimer;
  Timer? _draftTimer;
  late final SyncProgress _progress;
  Future<void>? _transferRefresh;
  bool _refreshTransfersAgain = false;
  int _transferRevision = 0;
  int? _transferInitialThrough;
  Set<String> _transferBindings = {};
  final Map<String, TransferTask> _transferCache = {};
  final Map<String, ({int bytes, DateTime at, double rate})> _transferSamples =
      {};
  List<TransferTask> transferTasks = [];
  final Map<String, Future<void>> _syncJobs = {};
  final Map<String, List<Completer<void>>> _syncWaiters = {};
  final Set<String> _forcedSync = {};
  final Map<String, String> _networkExchanged = {};
  Future<void>? _startup;
  final Set<Future<void>> _localOperations = {};
  Future<void> _favoritePreferenceWrites = Future.value();
  bool _closed = false;
  bool ready = false;
  int loadingRecords = 0, totalRecords = 0;
  bool _migrating = false;
  bool _migrateAgain = false;
  Future<void>? _legacyImportTask;
  int _activeSynchronizations = 0;
  int _fileSynchronizations = 0;
  final List<_MessageSearch> _searchQueue = [];
  _MessageSearch? _activeSearch;
  Future<void>? _searchWorker;
  bool _wasPaused = false;
  bool _foreground = true;
  bool _networkAvailable = true;
  int _networkGeneration = 0;
  NetworkState _networkState = const NetworkState();

  void setForeground(bool value) => _setForeground(value);

  void setNetworkAvailable(bool value) => _setNetworkAvailable(value);

  void setNetworkState(NetworkState state) => _setNetworkState(state);

  String? error;
  final Map<String, String> _peerSignatures = {};
  final Set<String> _knownSyncTargets = {};
  final Map<String, String> _connections = {};
  final Map<String, ({int revision, int through, String? identity, int count})>
  _unreadCounts = {};
  final Set<String> _unreadReads = {};
  final appearance = ValueNotifier<String>('light');
  final language = ValueNotifier<String>('zh');
  // Progress and connection state do not invalidate the conversation/editor.
  final activity = ValueNotifier<int>(0);
  final draftActivity = ValueNotifier<int>(0);
  Map<String, List<InboxEntry>> get _groupedItems => store.conversationEntries;
  bool get syncing => statuses.values.any((s) => s.busy);
  int get activeTransferCount =>
      _activeSynchronizations + lan.activeTransferCount;
  bool get transferring =>
      !lan.receivingPaused &&
      (_fileSynchronizations > 0 || lan.activeTransferCount > 0);
  String? readingConversation;
  Timer? _readSaveTimer;
  bool _readStateDirty = false;
  Future<void> Function(String destination, bool migrate)? relocateStorage;
  Future<void> Function(String destination)? backupStorage;
  Future<void> Function(String archivePath, String destination)? restoreStorage;
  Future<Map<String, dynamic>> Function(bool clearTrash)? cleanupStorage;
  Future<void> Function()? onCommitPendingEdits;

  Future<void> commitPendingEdits() async {
    await onCommitPendingEdits?.call();
  }

  List<SyncEndpoint> get endpoints => [
    ...store.hubs,
    if (lan.ready)
      for (final peer in lan.peers.values)
        if (lan.sessions.containsKey(peer.id) && peer.inboxVersion >= 2)
          SyncEndpoint(
            id: peer.id,
            name: peer.name,
            url: Uri(scheme: 'https', host: peer.address, port: peer.port),
            fingerprint: peer.fingerprint,
            token: lan.sessions[peer.id]!.sendToken,
            deviceId: lan.identity.id,
          ),
  ];

  List<InboxEntry> get items => store.chronologicalEntries;

  List<InboxEntry> itemsIn(String id) {
    items; // Refresh the per-conversation index only when the store changes.
    return _groupedItems[id] ?? const [];
  }

  Map<String, Conversation> get _allConversations {
    items;
    final all = <String, Conversation>{
      defaultConversationId: const Conversation(defaultConversationId, '发给自己'),
      ...store.conversations,
    };
    for (final id in store.historyConversations) {
      all.putIfAbsent(id, () => Conversation(id, '同步中的会话'));
    }
    return all;
  }

  bool _ensureConversationOrder() {
    final all = _allConversations;
    if (store.conversationOrder.isEmpty) {
      // Preserve the previous order once when upgrading. Subsequent activity
      // never sorts conversations by their latest message again.
      final initial = all.values.toList()
        ..sort((a, b) {
          final left = store.latestIn(a.id)?.item.createdAt;
          final right = store.latestIn(b.id)?.item.createdAt;
          if (left != null && right != null) {
            final order = right.compareTo(left);
            if (order != 0) return order;
          }
          if (left != null && right == null) return -1;
          if (left == null && right != null) return 1;
          return a.id.compareTo(b.id);
        });
      store.conversationOrder.addAll(initial.map((c) => c.id));
      return initial.isNotEmpty;
    }
    final known = store.conversationOrder.toSet();
    final added = all.keys.where((id) => !known.contains(id)).toList();
    store.conversationOrder.addAll(added);
    return added.isNotEmpty;
  }

  List<Conversation> get conversations {
    final all = _allConversations;
    final ordered = {...store.conversationOrder, ...all.keys}.toList();
    final ranks = {for (var i = 0; i < ordered.length; i++) ordered[i]: i};
    return all.values.where((conversation) {
      final hidden = store.preference(conversation.id).hiddenThrough;
      return hidden == null ||
          (store.maxConversationSequence[conversation.id] ?? 0) > hidden;
    }).toList()..sort((a, b) {
      final leftPin = store.preference(a.id).pinnedAt;
      final rightPin = store.preference(b.id).pinnedAt;
      if (leftPin != null || rightPin != null) {
        if (leftPin == null) return 1;
        if (rightPin == null) return -1;
        final order = rightPin.compareTo(leftPin);
        if (order != 0) return order;
      }
      return ranks[a.id]!.compareTo(ranks[b.id]!);
    });
  }

  Future<void> reorderConversation(String id, int newIndex) =>
      _trackLocal(() async {
        if (store.preference(id).pinnedAt != null) return;
        _ensureConversationOrder();
        final visible = conversations.map((c) => c.id).toList();
        final oldIndex = visible.indexOf(id);
        if (oldIndex < 0) return;
        final pinned = visible
            .where((id) => store.preference(id).pinnedAt != null)
            .length;
        final destination = newIndex.clamp(pinned, visible.length - 1);
        visible
          ..removeAt(oldIndex)
          ..insert(destination, id);
        final unpinned = visible
            .where((id) => store.preference(id).pinnedAt == null)
            .toList();
        final editable = unpinned.toSet();
        final previous = List<String>.of(store.conversationOrder);
        var cursor = 0;
        final next = [
          for (final old in previous)
            editable.contains(old) ? unpinned[cursor++] : old,
        ];
        if (listEquals(previous, next)) return;
        store.conversationOrder
          ..clear()
          ..addAll(next);
        _changed();
        try {
          await store.save();
        } on Object {
          if (listEquals(store.conversationOrder, next)) {
            store.conversationOrder
              ..clear()
              ..addAll(previous);
            _changed();
          }
          rethrow;
        }
      });

  String get conversationId => store.currentConversation;
  Conversation get conversation => conversations.firstWhere(
    (c) => c.id == conversationId,
    orElse: () => const Conversation(defaultConversationId, '发给自己'),
  );
  void selectConversation(String id, {bool markRead = true}) {
    store.currentConversation = id;
    readingConversation = null;
    if (markRead) _markRead(id);
    _changed();
    if (store.loaded && store.pagedHistory) unawaited(loadHistory(id));
    if (store.loaded) {
      unawaited(
        store.save().catchError((Object e) => reportError('会话选择保存失败：$e')),
      );
    }
  }

  int unreadCount(String id) {
    final through = store.preference(id).readThrough;
    final identity = lan.identityReady ? lan.identity.id : null;
    final cached = _unreadCounts[id];
    if (cached != null &&
        cached.revision == store.contentRevision &&
        cached.through == through &&
        cached.identity == identity) {
      return cached.count;
    }
    if (store.pagedHistory) {
      if (through >= (store.maxConversationSequence[id] ?? 0)) return 0;
      final revision = store.contentRevision;
      final key = '$id:$revision:$through:$identity';
      if (_unreadReads.add(key)) {
        unawaited(
          store
              .countUnread(id, through, identity)
              .then((count) {
                if (_closed ||
                    revision != store.contentRevision ||
                    through != store.preference(id).readThrough) {
                  return;
                }
                _unreadCounts[id] = (
                  revision: revision,
                  through: through,
                  identity: identity,
                  count: count,
                );
                notifyListeners();
              })
              .catchError((Object e) {
                if (!_closed) reportError('未读数量加载失败：$e');
              })
              .whenComplete(() => _unreadReads.remove(key)),
        );
      }
      return cached?.count ?? 0;
    }
    final count = itemsIn(id)
        .where(
          (entry) =>
              entry.sequence > through &&
              (!lan.identityReady || entry.item.originId != lan.identity.id),
        )
        .length;
    _unreadCounts[id] = (
      revision: store.contentRevision,
      through: through,
      identity: identity,
      count: count,
    );
    return count;
  }

  bool isUnread(String id) =>
      store.preference(id).manualUnread || unreadCount(id) > 0;

  bool _markRead(String id) {
    final preference = store.preference(id);
    final maximum = store.maxConversationSequence[id] ?? 0;
    final through = maximum > preference.readThrough
        ? maximum
        : preference.readThrough;
    final changed =
        preference.manualUnread || through != preference.readThrough;
    preference.manualUnread = false;
    preference.readThrough = through;
    return changed;
  }

  void setReadingConversation(String? id) {
    if (_closed) return;
    if (id == null) {
      _readSaveTimer?.cancel();
      _readSaveTimer = null;
      if (_readStateDirty && store.loaded) {
        _readStateDirty = false;
        unawaited(
          store.save().catchError((Object e) => reportError('已读状态保存失败：$e')),
        );
      }
    }
    if (readingConversation == id) return;
    readingConversation = id;
    if (id != null &&
        ready &&
        !store.preference(id).manualUnread &&
        _markRead(id)) {
      _saveReadState();
      _changed();
    }
  }

  void _saveReadState() {
    _readStateDirty = true;
    _readSaveTimer?.cancel();
    _readSaveTimer = Timer(const Duration(milliseconds: 250), () {
      if (!_closed && store.loaded) {
        _readStateDirty = false;
        unawaited(
          store.save().catchError((Object e) => reportError('已读状态保存失败：$e')),
        );
      }
    });
  }

  Future<void> setConversationUnread(String id, bool unread) async {
    final previous = ConversationPreference.fromJson(
      store.preference(id).toJson(),
    );
    if (unread) {
      store.preference(id).manualUnread = true;
    } else {
      _markRead(id);
    }
    try {
      await store.save();
    } on Object {
      store.conversationPreferences[id] = previous;
      rethrow;
    }
    _changed();
  }

  Future<void> setConversationPinned(String id, bool pinned) async {
    final previous = store.preference(id).pinnedAt;
    store.preference(id).pinnedAt = pinned
        ? DateTime.now().microsecondsSinceEpoch
        : null;
    try {
      await store.save();
    } on Object {
      store.preference(id).pinnedAt = previous;
      rethrow;
    }
    _changed();
  }

  Future<void> deleteConversation(String id) => _trackLocal(() async {
    final through = await store.removeConversation(id);
    final preference = store.preference(id);
    preference.hiddenThrough = through;
    preference.pinnedAt = null;
    preference.manualUnread = false;
    store.drafts.remove(id);
    store.draftQuotes.remove(id);
    store.attachmentDrafts.remove(id);
    if (conversationId == id) {
      store.currentConversation =
          conversations.firstOrNull?.id ?? defaultConversationId;
    }
    await store.save();
    _changed();
    if (automaticSync) requestSync();
  });

  Future<Conversation> createConversation(String name) => _trackLocal(() async {
    final value = name.trim();
    if (value.isEmpty || value.length > 40) {
      throw const FormatException('会话名称为 1–40 个字');
    }
    final conversation = Conversation(randomToken(18), value);
    await store.setConversation(conversation.id, conversation.name);
    selectConversation(conversation.id);
    if (automaticSync) requestSync();
    return conversation;
  });

  Future<void> setAppearance(String value) async {
    await _awaitLoaded();
    final previous = store.appearance;
    store.appearance = const {'light', 'dark', 'system'}.contains(value)
        ? value
        : 'light';
    appearance.value = store.appearance;
    try {
      await store.save();
    } on Object {
      store.appearance = previous;
      appearance.value = previous;
      rethrow;
    }
  }

  Future<void> setComposerFraction(double value) async {
    store.composerFraction = value.clamp(.18, .6);
    await store.save();
  }

  Future<void> setLanguage(String value) async {
    await _awaitLoaded();
    if (!const {'zh', 'en'}.contains(value)) return;
    final previous = store.language;
    store.language = value;
    language.value = value;
    try {
      await store.save();
    } on Object {
      store.language = previous;
      language.value = previous;
      rethrow;
    }
  }

  String deviceName(String id, [String fallback = '我的设备']) =>
      store.profiles[id]?['name'] as String? ??
      (id == lan.identity.id ? lan.name : lan.peers[id]?.name) ??
      fallback;
  String? deviceAvatar(String id) => store.profiles[id]?['avatar'] as String?;
  String? deviceAvatarPreset(String id) =>
      store.profiles[id]?['avatarPreset'] as String?;
  int? deviceAvatarColor(String id) =>
      store.profiles[id]?['avatarColor'] as int?;
  Future<void> updateProfile(
    String name, {
    String? avatar,
    bool appearance = false,
    String? preset,
    int? color,
  }) async {
    await store.setProfile(
      lan.identity.id,
      name,
      avatar: avatar,
      appearance: appearance,
      preset: preset,
      color: color,
    );
    lan.updateSettings(deviceName: name);
    _changed();
    if (automaticSync) requestSync();
  }

  Future<void> setDeviceAppearance(
    String id, {
    String? avatar,
    String? preset,
    int? color,
  }) => _trackLocal(() async {
    final hub = store.hubs.where((hub) => hub.id == id).firstOrNull;
    final name = deviceName(id, hub?.name ?? '我的设备');
    await store.setProfile(
      id,
      name,
      avatar: avatar,
      appearance: true,
      preset: preset,
      color: color,
    );
    _changed();
    if (automaticSync) requestSync(immediate: true);
  });

  Future<void> deleteItem(InboxItem item) => _trackLocal(() async {
    await store.remove(item.id);
    _changed();
    if (automaticSync) requestSync();
  });

  Future<void> deleteItems(Iterable<String> ids) => _trackLocal(() async {
    final selected = ids
        .where((id) => store.pagedHistory || store.find(id) != null)
        .toSet();
    if (selected.isEmpty) return;
    await store.removeMany(selected);
    _changed();
    if (automaticSync) requestSync();
  });

  Future<void> setFavorites(Iterable<String> ids, bool value) =>
      _trackLocal(() async {
        await store.setFavorites(ids, value);
        _changed();
        if (automaticSync) requestSync();
      });

  bool isFavorite(String id) =>
      store.favorites.contains(id) || store.findFavorite(id) != null;

  List<FavoriteEntry> get favoriteEntries => store.favoriteEntries;
  FavoritePreferences get favoritePreferences => store.favoritePreferences;
  int get favoritePreferencesRevision => store.favoritePreferencesRevision;
  bool get linkFavoriteDeletion => true;

  Future<void> setFavoritePreferences(FavoritePreferences value) {
    final base = favoritePreferences;
    // Treat a copied preference value as a patch against the state the caller
    // saw. Queued layout/filter changes must not overwrite later pins or other
    // presentation fields; pins are edited only through setFavoritesPinned.
    return _writeFavoritePreferences(
      (current) => current.copyWith(
        layout: value.layout != base.layout ? value.layout : null,
        filter: value.filter != base.filter ? value.filter : null,
        sort: value.sort != base.sort ? value.sort : null,
        onlyPinned: value.onlyPinned != base.onlyPinned
            ? value.onlyPinned
            : null,
      ),
    );
  }

  Future<void> setFavoritesPinned(Iterable<String> ids, bool pinned) {
    final selected = ids.toSet();
    return _writeFavoritePreferences((previous) {
      final pins = Map<String, int>.of(previous.pinned);
      var at = DateTime.now().millisecondsSinceEpoch;
      for (final value in pins.values) {
        if (value >= at) at = value + 1;
      }
      for (final id in selected) {
        if (!pinned) {
          pins.remove(id);
        } else if (store.findFavorite(id) != null && !pins.containsKey(id)) {
          pins[id] = at++;
        }
      }
      return previous.copyWith(pinned: pins);
    });
  }

  Future<void> _writeFavoritePreferences(
    FavoritePreferences Function(FavoritePreferences previous) update,
  ) => _trackLocal(() {
    final operation = _favoritePreferenceWrites.then((_) async {
      final previous = store.favoritePreferences;
      final next = update(previous);
      if (previous == next) return;
      store.favoritePreferences = next;
      try {
        await store.save();
      } on Object {
        store.favoritePreferences = previous;
        _changed();
        rethrow;
      }
      _changed();
    });
    // Keep later changes runnable after a failed save, while returning the
    // actual error to the caller and draining every accepted edit at close.
    _favoritePreferenceWrites = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  });

  Future<void> deleteFavorites(Iterable<String> ids) => _trackLocal(() async {
    await store.deleteFavorites(ids);
    _changed();
    if (automaticSync) requestSync();
  });

  Future<void> restoreFavorites(Iterable<String> ids) => _trackLocal(() async {
    await store.restoreFavorites(ids);
    _changed();
    if (automaticSync) requestSync();
  });

  Future<bool> favoriteAvailable(FavoriteEntry entry) async =>
      !entry.item.isFile ||
      await store.hasBlob(entry.item.digest, entry.item.size);
  Future<File> favoriteFileForOpening(FavoriteEntry entry) =>
      store.fileForOpening(entry.item);
  Future<File> favoriteFileForExport(FavoriteEntry entry) =>
      store.fileForExport(entry.item);

  Future<void> restoreDeleted(DeletedItem entry) => _trackLocal(() async {
    await store.restore(entry.id, source: entry.source);
    _changed();
    if (automaticSync) requestSync();
  });

  Map<String, Object> diagnostics() {
    const categories = {
      'offline',
      'timeout',
      'busy',
      'source_pending',
      'paused',
      'not_ready',
      'authentication',
      'identity',
      'storage',
      'remote_storage',
      'protocol',
      'conflict',
      'integrity',
      'invalid',
      'cancelled',
      'unknown',
    };
    final transfers = <String, int>{};
    for (final task in transferTasks) {
      final state =
          const {'queued', 'failed', 'paused', 'cancelled'}.contains(task.state)
          ? task.state
          : 'unknown';
      transfers.update(state, (count) => count + 1, ifAbsent: () => 1);
    }
    return {
      'app': 'LanFlow',
      'platform': Platform.operatingSystem,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'language': language.value,
      'appearance': appearance.value,
      'storageReady': ready && store.loaded,
      'localErrorPresent': error != null || lan.error != null,
      'messages': store.messageCount,
      'messageConflicts': store.conflicts.length,
      'conversations': conversations.length,
      'favorites': favoriteEntries.length,
      'pairedDevices': lan.sessions.length,
      'nasConnections': store.hubs.length,
      'syncPaused': lan.receivingPaused,
      'onlineTargets': statuses.values.where((status) => status.online).length,
      'targetsNeedingAttention': statuses.values
          .where((status) => status.needsAttention)
          .length,
      'errorCategories':
          statuses.values
              .where((status) => status.error != null)
              .map(
                (status) => categories.contains(status.errorCategory)
                    ? status.errorCategory!
                    : 'unknown',
              )
              .toSet()
              .toList()
            ..sort(),
      'transfers': transfers,
    };
  }

  FutureOr<Map<String, dynamic>> searchMessages(
    Map<String, dynamic> query, {
    Object? requestGroup,
  }) => _queueSearch(query, requestGroup);

  void cancelMessageSearches(Object requestGroup) =>
      _cancelQueuedSearches(group: requestGroup);

  Future<void> loadHistory(String id, {bool older = false}) async {
    try {
      await _trackLocal(() => store.loadConversation(id, older: older));
      if (!_closed) _changed();
    } on Object catch (e) {
      if (!_closed) reportError('聊天记录加载失败：$e');
    }
  }

  Future<void> extendMessageContext({required bool newer}) async {
    try {
      await _trackLocal(() => store.extendContext(newer: newer));
      if (!_closed) _changed();
    } on Object catch (e) {
      if (!_closed) reportError('聊天记录加载失败：$e');
    }
  }

  Future<void> renameConversation(String id, String name) =>
      _trackLocal(() async {
        final value = name.trim();
        if (value.isEmpty || value.length > 40) {
          throw const FormatException('会话名称为 1–40 个字');
        }
        await store.setConversation(id, value);
        _changed();
        if (automaticSync) requestSync();
      });

  Future<void> restoreItem(InboxItem item) => _trackLocal(() async {
    await store.restore(item.id);
    _changed();
    if (automaticSync) requestSync();
  });

  Future<void> editMessage(
    InboxItem item, {
    required String text,
    String? name,
  }) => _trackLocal(() async {
    if (!ready) throw StateError('请等待本机收件箱启动完成');
    await store.editMessage(
      item.id,
      text: text,
      name: name ?? item.name,
      parents: item.editHeads,
      editorId: lan.identity.id,
      editorName: lan.name,
    );
    _changed();
    if (automaticSync) requestSync(immediate: true);
  });

  Future<void> refreshTransfers() {
    if (_closed || !ready) return Future.value();
    _refreshTransfersAgain = true;
    if (_transferRefresh != null) return _transferRefresh!;
    final completed = Completer<void>();
    _transferRefresh = completed.future;
    unawaited(_drainTransferRefresh(completed));
    return completed.future;
  }

  Future<void> _drainTransferRefresh(Completer<void> completed) async {
    try {
      do {
        _refreshTransfersAgain = false;
        await _readTransferSnapshot();
      } while (_refreshTransfersAgain && !_closed);
      // Clear the reservation before completing callers, so a new request can
      // never join an already-finished read and lose its requested refresh.
      _transferRefresh = null;
      completed.complete();
    } on Object catch (error, stack) {
      _transferRefresh = null;
      _refreshTransfersAgain = false;
      completed.completeError(error, stack);
    }
  }

  Future<void> _readTransferSnapshot() async {
    final bound = {
      ...store.hubs.map((hub) => hub.key),
      ...lan.sessions.keys.map((id) => 'device:$id'),
    };
    var changed = false;
    if (!setEquals(bound, _transferBindings)) {
      _transferBindings = bound;
      _transferRevision = 0;
      _transferInitialThrough = null;
      _transferCache.clear();
      _transferSamples.clear();
      changed = true;
    }
    final page = await store.transferUpdates(
      bound,
      _transferRevision,
      initialThrough: _transferInitialThrough,
    );
    if (_closed) return;
    final current = {
      ...store.hubs.map((h) => h.key),
      ...lan.sessions.keys.map((id) => 'device:$id'),
    };
    if (!setEquals(bound, current)) {
      _refreshTransfersAgain = true;
      return;
    }
    if (page['reset'] == true) {
      _transferCache.clear();
      _transferSamples.clear();
      changed = true;
    }
    for (final key in (page['removed'] as List).cast<String>()) {
      changed = _transferCache.remove(key) != null || changed;
      _transferSamples.remove(key);
    }
    final now = DateTime.now();
    for (final value in (page['items'] as List).cast<Map>()) {
      final task = TransferTask.fromJson(Map<String, dynamic>.from(value));
      final old = _transferSamples[task.key];
      var rate = 0.0;
      if (!task.stopped && task.state != 'failed' && task.transferred > 0) {
        if (old != null && task.transferred > old.bytes) {
          final seconds = now.difference(old.at).inMilliseconds / 1000;
          rate = seconds > 0 ? (task.transferred - old.bytes) / seconds : 0;
          if (old.rate > 0 && rate > 0) rate = old.rate * .6 + rate * .4;
        }
        _transferSamples[task.key] = (
          bytes: task.transferred,
          at: now,
          rate: rate,
        );
      } else {
        _transferSamples.remove(task.key);
      }
      task.bytesPerSecond = rate;
      _transferCache[task.key] = task;
      changed = true;
    }
    for (final entry in _transferSamples.entries.toList()) {
      if (now.difference(entry.value.at).inSeconds >= 3) {
        final task = _transferCache[entry.key];
        if (task != null && task.bytesPerSecond != 0) {
          task.bytesPerSecond = 0;
          changed = true;
        }
        _transferSamples.remove(entry.key);
      }
    }
    _transferRevision = page['cursor'] as int;
    _transferInitialThrough = page['initialThrough'] as int?;
    if (page['more'] == true) _refreshTransfersAgain = true;
    final active = _activeSynchronizations == 0
        ? 0
        : await NativeCore.run({
                'op': 'sync_file_activity',
                'root': store.directory.path,
              })
              as int;
    if (!_closed && active != _fileSynchronizations) {
      _fileSynchronizations = active;
      _activityChanged();
    }
    if (!_closed && changed) {
      transferTasks = _transferCache.values.toList();
      _activityChanged();
    }
  }

  Future<void> controlTransfer(TransferTask task, String action) async {
    await store.transferAction(task, action);
    if (action == 'delete') {
      // Let an already-started chunk settle, but prevent its later receipt.
      if (task.state != 'completed') {
        await _sync.cancel(task.endpoint);
      }
      final status = statuses[task.endpoint];
      if (status?.failures == 0) {
        status?.error = null;
        status?.errorCategory = null;
        status?.needsAttention = false;
        status?.retryAfter = null;
      }
    }
    await refreshTransfers();
    if (action == 'delete' && automaticSync) {
      requestSync(endpoint: task.endpoint);
    }
    if (action == 'retry') {
      statuses[task.endpoint]?.retryAfter = null;
      statuses[task.endpoint]?.needsAttention = false;
      statuses[task.endpoint]?.error = null;
      _activityChanged();
      requestSync();
    }
  }

  Future<void> resetSync(String endpoint) => _trackLocal(() async {
    if (_closed || !ready) throw StateError('请稍后重试同步');
    if (!syncTargets.any((target) => target.key == endpoint)) {
      throw StateError('设备已移除');
    }
    _pendingSync.remove(endpoint);
    await _sync.cancel(endpoint);
    if (_closed || !syncTargets.any((target) => target.key == endpoint)) {
      throw StateError('设备已移除');
    }
    await NativeCore.run({
      'op': 'reset_endpoint',
      'root': store.directory.path,
      'key': endpoint,
    });
    statuses.remove(endpoint);
    _requestedContent.remove(endpoint);
    _expectRemoteChanges(endpoint);
    await store.refresh();
    await refreshTransfers();
    _changed();
    if (automaticSync) requestSync(endpoint: endpoint, immediate: true);
  });

  Future<void> updateDeviceAddress(String id, String address) =>
      _trackLocal(() async {
        final key = 'device:$id';
        await _sync.cancel(key);
        await lan.updatePeerAddress(id, address);
        statuses.remove(key);
        _requestedContent.remove(key);
        _changed();
        if (automaticSync) requestSync(endpoint: key, immediate: true);
      });

  Future<void> updateHub(
    SyncEndpoint old, {
    required String address,
    required String name,
    String code = '',
  }) => _trackLocal(() async {
    var settings = old.toJson();
    if (code.trim().isNotEmpty) {
      final raw = code.trim();
      if (!raw.startsWith('lanflow1:')) {
        throw const FormatException('NAS 连接码无效');
      }
      settings = Map<String, dynamic>.from(
        jsonDecode(
              utf8.decode(
                base64Url.decode(base64Url.normalize(raw.substring(9))),
              ),
            )
            as Map,
      );
    }
    final next = SyncEndpoint.hub({
      ...settings,
      'url': parseHubAddress(address).toString(),
      'name': name.trim().isEmpty ? old.name : name.trim(),
    });
    if (next.name.length > 60) throw const FormatException('设备名称最多 60 个字');
    final index = store.hubs.indexWhere((hub) => hub.key == old.key);
    if (index < 0) throw StateError('设备已移除');
    if (store.hubs.any((hub) => hub.key != old.key && hub.key == next.key)) {
      throw StateError('此 NAS 已在列表中');
    }
    await _sync.cancel(old.key);
    store.hubs[index] = next;
    try {
      await store.save();
    } on Object {
      store.hubs[index] = old;
      rethrow;
    }
    _watches.remove(old.key)?.close();
    _pendingSync.remove(old.key);
    _pendingPulls.remove(old.key);
    _requestedContent.remove(old.key);
    statuses.remove(old.key);
    await refreshTransfers();
    _changed();
    _updateWatches();
    if (automaticSync) requestSync(endpoint: next.key, immediate: true);
  });

  // Include paired devices even while discovery has no usable address for them.
  List<SyncTarget> get syncTargets => [
    for (final hub in store.hubs) SyncTarget(hub.key, hub.name, isHub: true),
    for (final id in lan.sessions.keys)
      SyncTarget(
        'device:$id',
        store.profiles[id]?['name'] as String? ??
            lan.peers[id]?.name ??
            '已绑定设备',
      ),
  ];

  String endpointName(String key) =>
      syncTargets.where((e) => e.key == key).firstOrNull?.name ?? '未连接的设备';

  List<MessageConflict> get syncProblems => store.conflicts;
  MessageConflict? conflictFor(String id) =>
      store.conflicts.where((conflict) => conflict.id == id).firstOrNull;

  Future<void> resolveConflict(
    MessageConflict conflict, {
    String? versionId,
    String? text,
    String? name,
  }) => _trackLocal(() async {
    await store.resolveMessage(
      conflict,
      versionId: versionId,
      text: text,
      name: name,
      editorId: lan.identity.id,
      editorName: lan.name,
    );
    _changed();
    if (automaticSync) requestSync(immediate: true);
  });

  Future<void> deleteConflict(MessageConflict conflict) =>
      _trackLocal(() async {
        await store.remove(conflict.id);
        _changed();
        if (automaticSync) requestSync(immediate: true);
      });

  List<SyncTarget> get connectionProblems => syncTargets
      .where(
        (target) =>
            statuses[target.key]?.needsAttention == true ||
            transferTasks.any(
              (task) => task.endpoint == target.key && task.needsAttention,
            ),
      )
      .toList();

  String? syncProblemDetail(String endpoint) =>
      (statuses[endpoint]?.needsAttention == true
          ? statuses[endpoint]?.error
          : null) ??
      transferTasks
          .where((task) => task.endpoint == endpoint && task.needsAttention)
          .firstOrNull
          ?.error ??
      statuses[endpoint]?.error;

  Future<void> retrySync(String endpoint) async {
    // An explicit retry bypasses backoff, but never resumes paused/cancelled jobs.
    if (_closed || !ready || !lan.ready) throw StateError('请稍后重试同步');
    if (lan.receivingPaused) throw StateError('同步已暂停，请先恢复同步');
    if (!endpoints.any((target) => target.key == endpoint)) {
      throw StateError('设备离线');
    }
    if (!endpoints.any(
      (target) => target.key == endpoint && _endpointAvailable(target),
    )) {
      throw StateError('当前网络无法连接此设备，请检查网络后重试');
    }
    _pendingSync.remove(endpoint);
    await _sync.cancel(endpoint);
    await _syncJobs[endpoint];
    if (_closed || !ready || !lan.ready) throw StateError('请稍后重试同步');
    if (lan.receivingPaused) throw StateError('同步已暂停，请先恢复同步');
    if (!endpoints.any((target) => target.key == endpoint)) {
      throw StateError('设备离线');
    }
    if (!endpoints.any(
      (target) => target.key == endpoint && _endpointAvailable(target),
    )) {
      throw StateError('当前网络无法连接此设备，请检查网络后重试');
    }
    await NativeCore.run({
      'op': 'retry_endpoint',
      'root': store.directory.path,
      'key': endpoint,
    });
    final status = statuses.putIfAbsent(endpoint, SyncStatus.new);
    status.needsAttention = false;
    status.error = null;
    status.errorCategory = null;
    status.failures = 0;
    status.retryAfter = null;
    _activityChanged();
    await refreshTransfers();
    await _runSync(force: true, targets: {endpoint});
  }

  List<TargetCopyStatus> copyDetails(InboxEntry entry) => [
    for (final target in syncTargets) _targetCopyStatus(entry, target),
  ];

  TargetCopyStatus _targetCopyStatus(InboxEntry entry, SyncTarget target) {
    if (entry.copies.contains(target.key)) {
      return TargetCopyStatus(target, CopyState.complete, '已同步');
    }
    final peer = target.isHub ? null : lan.peers[target.key.substring(7)];
    if (peer != null && peer.inboxVersion < 2) {
      return TargetCopyStatus(
        target,
        CopyState.failed,
        '版本过旧',
        detail: '请更新另一台设备上的 LanFlow',
      );
    }
    final task = transferTasks
        .where(
          (task) =>
              task.endpoint == target.key &&
              task.item.id == entry.item.id &&
              task.direction == 'upload',
        )
        .firstOrNull;
    final status = statuses[target.key];
    if (task?.state == 'cancelled') {
      return TargetCopyStatus(target, CopyState.cancelled, '已取消传输');
    }
    if (lan.receivingPaused || task?.state == 'paused') {
      return TargetCopyStatus(target, CopyState.paused, '同步已暂停');
    }
    if (task?.needsAttention == true ||
        (status?.needsAttention == true &&
            (status?.online != true ||
                !transferTasks.any(
                  (other) =>
                      other.endpoint == target.key && other.state == 'failed',
                )))) {
      return TargetCopyStatus(
        target,
        CopyState.failed,
        '等待处理',
        detail: task?.error ?? status?.error,
      );
    }
    if (status?.busy == true) {
      return TargetCopyStatus(target, CopyState.syncing, '同步中');
    }
    if (task?.state == 'failed') {
      return TargetCopyStatus(
        target,
        CopyState.waiting,
        '等待自动重试',
        detail: task?.error,
      );
    }
    if (status?.error != null) {
      return TargetCopyStatus(
        target,
        CopyState.waiting,
        '等待自动重试',
        detail: status?.error,
      );
    }
    if (status?.online == true) {
      return TargetCopyStatus(target, CopyState.waiting, '等待同步');
    }
    return TargetCopyStatus(target, CopyState.waiting, '等待设备上线');
  }

  String copyStatus(InboxEntry entry) {
    if (conflictFor(entry.item.id) != null) return '内容冲突，待选择';
    final details = copyDetails(entry);
    if (details.isEmpty) return '已保存到本机';
    final completed = details
        .where((s) => s.state == CopyState.complete)
        .length;
    final count = '已同步 $completed/${details.length}';
    if (completed == details.length) return count;
    final pending = details.where((s) => s.state != CopyState.complete);
    final label = pending.any((s) => s.state == CopyState.failed)
        ? '连接或传输待处理'
        : pending.any((s) => s.state == CopyState.cancelled)
        ? '部分传输已取消'
        : pending.any((s) => s.state == CopyState.paused)
        ? '同步已暂停'
        : pending.any((s) => s.state == CopyState.syncing)
        ? '同步中'
        : pending.any((s) => statuses[s.target.key]?.online == true)
        ? '等待同步'
        : '等待设备上线';
    return '$count · $label';
  }

  String get connectionSummary {
    final targets = syncTargets;
    if (targets.isEmpty) return '未连接设备';
    if (lan.receivingPaused) return '同步已暂停';
    return '已绑定 ${targets.length} 台设备';
  }

  Future<void> start() {
    if (_closed || ready) return Future.value();
    if (_startup != null) return _startup!;
    final task = _start();
    _startup = task;
    return task.whenComplete(() => _startup = null);
  }

  Future<void> _start() async {
    error = null;
    try {
      await store.load(
        onProgress: (count, total) {
          loadingRecords = count;
          totalRecords = total;
          if (total > 1000) _changed();
        },
      );
      if (_closed) return;
      await store.migrateConversationAvatars();
      if (_closed) return;
      if (_ensureConversationOrder()) await store.save();
      appearance.value = store.appearance;
      language.value = store.language;
      ready = true;
      // Searches retain their complete scan fallback until the derived index
      // is ready. Index maintenance must never turn a usable inbox into an error.
      unawaited(store.optimizeSearchIndex().catchError((Object _) {}));
      await refreshTransfers();
      if (_closed) return;
      final api = InboxApi(
        store,
        _changed,
        onContentChange: () {
          if (automaticSync) requestSync();
        },
      );
      lan.onInboxRequest = api.handle;
      lan.addListener(_lanChanged);
      await _migrateLegacy();
      if (_closed) return;
      if (lan.ready && !store.profiles.containsKey(lan.identity.id)) {
        await store.setProfile(lan.identity.id, lan.name);
      }
      if (automaticSync) {
        for (final endpoint in endpoints) {
          _expectRemoteChanges(endpoint.key);
        }
        _updateWatches();
        requestSync();
      }
    } on Object catch (e) {
      ready = false;
      error = '收件箱加载失败：$e';
    } finally {
      _changed();
    }
  }

  void setDraft(String value) {
    store.draft = value;
    draftActivity.value++;
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(
        store.save().catchError((Object e) {
          error = '草稿保存失败：$e';
          _changed();
        }),
      );
    });
  }

  Future<void> setDraftQuote(
    MessageQuote? quote, {
    String? conversation,
  }) async {
    final id = conversation ?? conversationId;
    final previous = store.draftQuotes[id];
    if (quote == null) {
      store.draftQuotes.remove(id);
    } else {
      store.draftQuotes[id] = quote;
    }
    try {
      await store.save();
    } on Object {
      if (previous == null) {
        store.draftQuotes.remove(id);
      } else {
        store.draftQuotes[id] = previous;
      }
      rethrow;
    }
    _changed();
  }

  Future<void> setConversationAvatar(
    String id,
    String? avatar, {
    int? color,
  }) async {
    final name =
        store.conversations[id]?.name ??
        (id == defaultConversationId ? '发给自己' : '同步中的会话');
    await store.setConversation(
      id,
      name,
      appearance: true,
      avatar: avatar,
      avatarColor: color,
    );
    _changed();
    if (automaticSync) requestSync();
  }

  String? conversationAvatar(String id) => store.conversations[id]?.avatar;
  int? conversationAvatarColor(String id) =>
      store.conversations[id]?.avatarColor;

  Future<void> retryLocalSave() async {
    _draftTimer?.cancel();
    try {
      await store.save();
      error = null;
    } on Object catch (e) {
      error = '草稿保存失败：$e';
    }
    _changed();
  }

  Future<void> flushLocalWrites() {
    if (_closed || !store.loaded) return Future.value();
    return _trackLocal(() async {
      _draftTimer?.cancel();
      _readSaveTimer?.cancel();
      _readStateDirty = false;
      await store.flush();
    });
  }

  Future<void> removeDevice(String id) async {
    _watches.remove('device:$id')?.close();
    _pendingSync.remove('device:$id');
    _pendingPulls.remove('device:$id');
    _requestedContent.remove('device:$id');
    lan.forgetPeer(id);
    await _sync.cancel('device:$id');
    statuses.remove('device:$id');
    await refreshTransfers();
    _changed();
    _scheduleRetry();
  }

  Future<InboxEntry?> addText(
    String text, {
    String? id,
    String? conversation,
    MessageQuote? quote,
  }) async {
    if (!ready || !lan.ready) throw StateError('请等待本机收件箱启动完成');
    final value = text.trim();
    if (value.isEmpty) return null;
    if (value.length > 20000) throw const FormatException('文字最多 20000 字');
    if (id != null) {
      final existing = await store.loadEntry(id);
      if (existing != null) return existing;
    }
    final entry = await store.add(
      InboxItem(
        id: id ?? randomToken(18),
        originId: lan.identity.id,
        originName: lan.name,
        createdAt: DateTime.now().toUtc(),
        kind: MessageKind.text,
        text: value,
        quote: quote,
        conversationId: conversation ?? conversationId,
      ),
    );
    _changed();
    if (automaticSync) requestSync();
    return entry;
  }

  Future<InboxEntry> addFile(
    String path, {
    String? name,
    String? mimeType,
    String? id,
    String? conversation,
  }) => _trackLocal(
    () => _addFile(
      path,
      name: name,
      mimeType: mimeType,
      id: id,
      conversation: conversation,
    ),
  );

  Future<T> _trackLocal<T>(Future<T> Function() action) {
    if (_closed) return Future.error(StateError('收件箱尚未就绪'));
    final operation = Future<T>.sync(() async {
      await _awaitLoaded();
      return action();
    });
    late final Future<void> settled;
    settled = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _localOperations.remove(settled));
    _localOperations.add(settled);
    return operation;
  }

  Future<void> _awaitLoaded() async {
    if (!store.loaded && _startup != null) await _startup;
    if (_closed || !store.loaded) throw StateError('请等待本机收件箱启动完成');
  }

  Future<InboxEntry> _addFile(
    String path, {
    String? name,
    String? mimeType,
    String? id,
    String? conversation,
  }) async {
    if (!ready || !lan.ready) throw StateError('请等待本机收件箱启动完成');
    if (id != null) {
      final existing = await store.loadEntry(id);
      if (existing != null) return existing;
    }
    final item = await _importAttachment(
      path,
      name: name,
      mimeType: mimeType,
      id: id,
      conversation: conversation ?? conversationId,
    );
    final entry = await store.add(item);
    _changed();
    if (automaticSync) requestSync();
    return entry;
  }

  Future<void> stageFile(String path, {String? conversation}) =>
      _trackLocal(() async {
        if (!ready || !lan.ready) throw StateError('请等待本机收件箱启动完成');
        final item = await _importAttachment(
          path,
          conversation: conversation ?? conversationId,
        );
        await _stageAttachment(item);
      });

  Future<void> _stageAttachment(InboxItem item) async {
    final drafts = store.attachmentDrafts[item.conversationId] ??= [];
    drafts.add(item);
    try {
      await store.save();
    } on Object {
      drafts.remove(item);
      rethrow;
    }
    _changed();
  }

  Future<InboxItem> _importAttachment(
    String path, {
    String? name,
    String? mimeType,
    String? id,
    required String conversation,
  }) async {
    final source = File(path);
    final fileName = safeFileName(name ?? p.basename(path));
    final extension = p.extension(fileName).toLowerCase();
    final kind =
        (mimeType?.startsWith('image/') ?? false) ||
            [
              '.jpg',
              '.jpeg',
              '.png',
              '.webp',
              '.gif',
              '.bmp',
              '.heic',
            ].contains(extension)
        ? MessageKind.image
        : (mimeType?.startsWith('video/') ?? false) ||
              [
                '.mp4',
                '.mov',
                '.mkv',
                '.webm',
                '.avi',
                '.m4v',
              ].contains(extension)
        ? MessageKind.video
        : MessageKind.file;
    final imported = await store.importFile(
      source.path,
      name: fileName,
      kind: kind.name,
    );
    final digest = imported['sha256'] as String;
    return InboxItem(
      id: id ?? randomToken(18),
      originId: lan.identity.id,
      originName: lan.name,
      createdAt: DateTime.now().toUtc(),
      kind: kind,
      name: fileName,
      size: imported['size'] as int,
      digest: digest,
      conversationId: conversation,
    );
  }

  Future<void> addShared(Map<String, dynamic> payload) =>
      _trackLocal(() => _addShared(payload));

  Future<void> _addShared(Map<String, dynamic> payload) async {
    final shareId = payload['id'] as String;
    String itemId(String part) =>
        sha256.convert(utf8.encode('share:$shareId:$part')).toString();
    final text = payload['text'] as String? ?? '';
    final target =
        payload['conversationId'] as String? ?? defaultConversationId;
    if (text.trim().isNotEmpty) {
      await addText(text, id: itemId('text'), conversation: target);
    }
    final files = payload['files'] as List? ?? [];
    for (var i = 0; i < files.length; i++) {
      final file = files[i] as Map;
      await _addFile(
        file['path'] as String,
        name: file['name'] as String?,
        mimeType: file['mimeType'] as String?,
        id: itemId('file:$i'),
        conversation: target,
      );
    }
    final comment = payload['comment'] as String? ?? '';
    if (comment.trim().isNotEmpty) {
      await addText(comment, id: itemId('comment'), conversation: target);
    }
  }

  Future<void> pasteImage(Uint8List bytes, {String? conversation}) =>
      _trackLocal(() async {
        if (!ready || !lan.ready) throw StateError('收件箱尚未就绪');
        if (bytes.length > 64 * 1024 * 1024) {
          throw const FormatException('剪贴板图片超过 64 MB');
        }
        final targetConversation = conversation ?? conversationId;
        final digest = await store.storeBlob(Stream.value(bytes), bytes.length);
        await _stageAttachment(
          InboxItem(
            id: randomToken(18),
            originId: lan.identity.id,
            originName: lan.name,
            createdAt: DateTime.now().toUtc(),
            kind: MessageKind.image,
            name: '粘贴图片-${DateTime.now().millisecondsSinceEpoch}.png',
            size: bytes.length,
            digest: digest,
            conversationId: targetConversation,
          ),
        );
      });

  Future<void> removeDraftAttachment(InboxItem item) async {
    final drafts = store.attachmentDrafts[item.conversationId];
    if (drafts == null) return;
    final index = drafts.indexOf(item);
    if (index < 0) return;
    drafts.removeAt(index);
    try {
      await store.save();
    } on Object {
      drafts.insert(index.clamp(0, drafts.length), item);
      rethrow;
    }
    _changed();
  }

  Future<void> sendDraftAttachments({
    String? conversation,
    MessageQuote? quote,
  }) => _trackLocal(
    () => _sendDraftAttachments(conversation: conversation, quote: quote),
  );

  Future<void> _sendDraftAttachments({
    String? conversation,
    MessageQuote? quote,
  }) async {
    for (final item
        in (store.attachmentDrafts[conversation ?? conversationId] ?? [])
            .toList()) {
      // Reuse the draft ID so retrying after a partial send cannot duplicate it.
      if (await store.loadEntry(item.id) == null) {
        await store.add(
          InboxItem(
            id: item.id,
            originId: item.originId,
            originName: item.originName,
            createdAt: DateTime.now().toUtc(),
            kind: item.kind,
            name: item.name,
            size: item.size,
            digest: item.digest,
            conversationId: item.conversationId,
            quote: quote,
          ),
        );
      }
      await removeDraftAttachment(item);
    }
    // The send action also clears the text draft. Commit that immediately so
    // restarting just after Send cannot resurrect an already-sent draft.
    await store.save();
    if (automaticSync) requestSync();
    _changed();
  }

  Future<void> addHub(String address, String code, String name) =>
      _trackLocal(() async {
        final value = code.trim();
        if (!value.startsWith('lanflow1:')) {
          throw const FormatException('请粘贴 NAS 容器日志中的连接码');
        }
        final data =
            jsonDecode(
                  utf8.decode(
                    base64Url.decode(base64Url.normalize(value.substring(9))),
                  ),
                )
                as Map<String, dynamic>;
        final endpoint = SyncEndpoint.hub({
          ...data,
          'url': parseHubAddress(address).toString(),
          'name': name.trim().isEmpty ? '我的 NAS' : name.trim(),
        });
        final info = await _sync.probe(endpoint);
        if (info['service'] != 'lanflow-inbox' ||
            info['version'] != 1 ||
            info['id'] != endpoint.id) {
          throw const FormatException('NAS 身份与连接码不匹配');
        }
        store.hubs.removeWhere((e) => e.id == endpoint.id);
        store.hubs.add(endpoint);
        await store.save();
        _changed();
        _updateWatches();
        if (automaticSync) requestSync();
      });

  Future<void> removeHub(SyncEndpoint hub) => _trackLocal(() async {
    _watches.remove(hub.key)?.close();
    _pendingSync.remove(hub.key);
    _pendingPulls.remove(hub.key);
    _requestedContent.remove(hub.key);
    store.hubs.removeWhere((e) => e.id == hub.id);
    await _sync.cancel(hub.key);
    statuses.remove(hub.key);
    await store.save();
    await refreshTransfers();
    _changed();
    _scheduleRetry();
  });

  void requestSync({String? endpoint, bool immediate = false}) {
    if (_closed ||
        !ready ||
        !lan.ready ||
        lan.receivingPaused ||
        !_networkAvailable) {
      return;
    }
    for (final target in endpoints.where(
      (e) => (endpoint == null || e.key == endpoint) && _endpointAvailable(e),
    )) {
      if (_requestedContent[target.key] != store.changeCursor) {
        _requestedContent[target.key] = store.changeCursor;
        unawaited(
          _sync.interruptTransfers(target.key).catchError((Object _) {}),
        );
        final status = statuses[target.key];
        // New content gets an immediate attempt. An old offline backoff must
        // never delay a message the user has just sent to a now reachable peer.
        if (status != null && status.failures > 0) status.retryAfter = null;
      }
      _pendingSync.add(target.key);
    }
    if (_kick != null || _pendingSync.isEmpty) return;
    if (_syncJobs.isNotEmpty) {
      _pumpSync();
      return;
    }
    _kick = Timer(Duration(milliseconds: immediate ? 0 : 80), () {
      _kick = null;
      _pumpSync();
    });
  }

  Future<void> syncNow({bool force = true}) {
    if (force) {
      for (final key in _watches.keys.toList()) {
        if (statuses[key]?.notificationsSupported == false) {
          _watches.remove(key)!.close();
        }
      }
    }
    _updateWatches();
    return _runSync(force: force);
  }

  void _changed() {
    if (!_closed) {
      if (ready && store.loaded && _ensureConversationOrder()) {
        unawaited(
          store.save().catchError((Object e) => reportError('会话顺序保存失败：$e')),
        );
      }
      final reading = readingConversation;
      if (ready &&
          reading != null &&
          !store.preference(reading).manualUnread &&
          _markRead(reading)) {
        _saveReadState();
      }
      if (ready && lan.ready) lan.announceChanges(store.changeCursor);
      _activityChanged();
      notifyListeners();
    }
  }

  void _activityChanged() {
    if (!_closed) activity.value++;
  }

  void reportError(String message) {
    error = message;
    _changed();
  }

  Future<void> close() async {
    if (_closed) return;
    await commitPendingEdits();
    if (_closed) return;
    _closed = true;
    _cancelQueuedSearches();
    _refreshTransfersAgain = false;
    _readSaveTimer?.cancel();
    lan.removeListener(_lanChanged);
    lan.onInboxRequest = null;
    for (final watch in _watches.values) {
      watch.close();
    }
    _watches.clear();
    _kick?.cancel();
    _retryTimer?.cancel();
    _draftTimer?.cancel();
    _progress.stop();
    await _sync.close();
    await _startup;
    _pumpSync();
    await Future.wait(_syncJobs.values.toList());
    await _searchWorker;
    // A failed progress read must not skip the final durable save. Accepted
    // reads still finish before the native store is closed.
    await _transferRefresh?.catchError((Object _) {});
    await Future.wait(_localOperations.toList());
    await store.close();
  }

  @override
  void dispose() {
    lan.transferActivity.removeListener(_activityChanged);
    if (_closed && store.releaseClosedHistory()) {
      transferTasks = [];
      _transferCache.clear();
      _transferSamples.clear();
      _unreadCounts.clear();
    }
    appearance.dispose();
    language.dispose();
    activity.dispose();
    draftActivity.dispose();
    super.dispose();
  }
}
