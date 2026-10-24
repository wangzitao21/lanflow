part of 'inbox_store.dart';

class _HistoryWindow {
  Map<String, dynamic>? cursor;
  bool loaded = false, more = true;
  Future<void>? reading;
}

extension HistoryStore on InboxStore {
  Future<void> optimizeSearchIndex() {
    if (!_searchIndexPending || _closing) return Future.value();
    if (_searchIndexing != null) return _searchIndexing!;
    final task = _buildSearchIndex();
    _searchIndexing = task;
    return task.whenComplete(() => _searchIndexing = null);
  }

  Future<void> _buildSearchIndex() async {
    while (!_closing && _searchIndexPending) {
      final result =
          await NativeCore.run({
                'op': 'search_index_step',
                'root': directory.path,
              })
              as Map;
      _searchIndexPending = result['done'] != true;
      if (_searchIndexPending && !_closing) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
  }

  int get messageCount => pagedHistory
      ? _historySummaries.values.fold(
          0,
          (total, value) => total + (value['count'] as int),
        )
      : entries.length;
  Iterable<String> get historyConversations =>
      pagedHistory ? _historySummaries.keys : conversationEntries.keys;
  InboxEntry? latestIn(String id) =>
      pagedHistory ? _latestEntries[id] : conversationEntries[id]?.firstOrNull;
  bool originalExists(FavoriteEntry entry) =>
      find(entry.originalMessageId) != null ||
      (_favoriteSources.contains(entry.originalMessageId) &&
          !deleted.contains(entry.originalMessageId));
  bool hasOlderHistory(String id) =>
      pagedHistory && (_historyWindows[id]?.more ?? true);
  bool loadingHistory(String id) => _historyWindows[id]?.reading != null;

  void _readHistorySummaries(dynamic values, {bool replace = false}) {
    if (values is! Map) return;
    if (replace) {
      _historySummaries.clear();
      _latestEntries.clear();
    }
    for (final entry in values.entries) {
      final id = entry.key as String;
      final value = Map<String, dynamic>.from(entry.value as Map);
      _historySummaries[id] = value;
      maxConversationSequence[id] = value['maximum'] as int;
      final last = value['latest'] as Map?;
      if (last == null) {
        _latestEntries.remove(id);
      } else {
        _latestEntries[id] = _decodeRecord(last);
      }
    }
    if (pagedHistory && values.isNotEmpty) contentRevision++;
  }

  InboxEntry _decodeRecord(Map record) {
    final item = InboxItem.fromJson(
      Map<String, dynamic>.from(record['item'] as Map),
    );
    if (record['blobPath'] is String) {
      _readBlobPaths({item.digest: record['blobPath']});
    }
    return InboxEntry(
      record['sequence'] as int,
      item,
      Set<String>.from(record['copies'] as List? ?? []),
    );
  }

  bool _cacheDeltaItem(Map<String, dynamic> item) {
    final conversation =
        item['conversationId'] as String? ?? defaultConversationId;
    final window = _historyWindows[conversation];
    if (window == null || !window.loaded) return false;
    final last = conversationEntries[conversation]?.lastOrNull;
    return !window.more ||
        last == null ||
        !DateTime.parse(
          item['createdAt'] as String,
        ).isBefore(last.item.createdAt);
  }

  Future<T> _historyRead<T>(Future<T> Function() work) {
    if (_closing) return Future.error(StateError('收件箱正在关闭'));
    final operation = Future<T>.sync(work);
    late final Future<void> settled;
    settled = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _historyReads.remove(settled));
    _historyReads.add(settled);
    return operation;
  }

  Future<dynamic> _historyCall(
    String op, [
    Map<String, dynamic> arguments = const {},
  ]) => _historyRead(
    () => NativeCore.run({'op': op, 'root': directory.path, ...arguments}),
  );

  List<InboxEntry> _cacheRecords(List records, {bool resident = false}) {
    final result = <InboxEntry>[];
    for (final record in records.cast<Map>()) {
      final id = record['item']['id'] as String;
      if (deleted.contains(id)) continue;
      final entry = _byId[id] ?? _decodeRecord(record);
      _byId[id] = entry;
      if (resident) {
        _residentIds.add(id);
        _lookupIds.remove(id);
      } else if (!_residentIds.contains(id)) {
        _lookupIds.remove(id);
        _lookupIds.add(id);
      }
      result.add(entry);
    }
    while (_lookupIds.length > 600) {
      final id = _lookupIds.first;
      _lookupIds.remove(id);
      if (!_residentIds.contains(id)) _byId.remove(id);
    }
    return result;
  }

  Future<List<InboxEntry>> loadEntries(Iterable<String> ids) async {
    final selected = ids.toSet().toList();
    if (!pagedHistory) {
      return selected.map(find).whereType<InboxEntry>().toList();
    }
    final missing = selected
        .where((id) => find(id) == null && !deleted.contains(id))
        .toList();
    final fetched = <String, InboxEntry>{};
    for (final id in selected) {
      final entry = find(id);
      if (entry != null) fetched[id] = entry;
    }
    for (var offset = 0; offset < missing.length; offset += 500) {
      final records =
          await _historyCall('history_records', {
                'ids': missing.skip(offset).take(500).toList(),
              })
              as List;
      for (final entry in _cacheRecords(records)) {
        fetched[entry.item.id] = entry;
      }
    }
    return selected
        .map((id) => fetched[id] ?? find(id))
        .whereType<InboxEntry>()
        .toList();
  }

  Future<InboxEntry?> loadEntry(String id) async =>
      (await loadEntries([id])).firstOrNull;

  Future<List<String>> conversationIds(String id) async => pagedHistory
      ? List<String>.from(
          await _historyCall('history_ids', {'conversationId': id}) as List,
        )
      : (conversationEntries[id] ?? []).map((entry) => entry.item.id).toList();

  Future<int> removeConversation(String id) async {
    final result = Map<String, dynamic>.from(
      await _historyCall('delete_conversation', {
            'conversationId': id,
            'knownRevision': revision,
          })
          as Map,
    );
    applySnapshot(result);
    return result['through'] as int;
  }

  Future<int> countUnread(String id, int through, String? origin) async =>
      await _historyCall('history_unread', {
            'conversationId': id,
            'through': through,
            'originId': origin ?? '',
          })
          as int;

  Future<void> loadConversation(String id, {bool older = false}) {
    if (!pagedHistory) return Future.value();
    final window = _historyWindows.putIfAbsent(id, _HistoryWindow.new);
    if (window.reading != null) return window.reading!;
    if (window.loaded && (!older || !window.more)) return Future.value();
    final task = _readConversation(id, window);
    window.reading = task;
    return task.whenComplete(() => window.reading = null);
  }

  Future<void> _readConversation(String id, _HistoryWindow window) async {
    final page =
        await _historyCall('history_page', {
              'conversationId': id,
              'cursor': window.cursor,
            })
            as Map;
    if (_closing) return;
    final incoming = _cacheRecords(page['entries'] as List, resident: true);
    final group = conversationEntries.putIfAbsent(id, () => []);
    final existing = group.map((entry) => entry.item.id).toSet();
    for (final entry in incoming) {
      if (existing.add(entry.item.id)) {
        group.add(entry);
        entries.add(entry);
        chronologicalEntries.add(entry);
      }
    }
    group.sort(InboxStore._compareEntries);
    entries.sort((a, b) => a.sequence.compareTo(b.sequence));
    chronologicalEntries.sort(InboxStore._compareEntries);
    window.cursor = (page['cursor'] as Map?)?.cast<String, dynamic>();
    window.more = page['more'] == true;
    window.loaded = true;
    _recentWindows.remove(id);
    _recentWindows.add(id);
    while (_recentWindows.length > 4) {
      final evicted = _recentWindows.firstWhere(
        (candidate) => candidate != currentConversation && candidate != id,
      );
      _recentWindows.remove(evicted);
      _historyWindows.remove(evicted);
      final discarded = conversationEntries.remove(evicted) ?? [];
      final ids = discarded.map((entry) => entry.item.id).toSet();
      entries.removeWhere((entry) => ids.contains(entry.item.id));
      chronologicalEntries.removeWhere((entry) => ids.contains(entry.item.id));
      for (final id in ids) {
        _residentIds.remove(id);
        _byId.remove(id);
      }
    }
    await loadEntries(
      incoming.map((entry) => entry.item.quote?.id).whereType<String>(),
    );
    contentRevision++;
  }

  Future<void> loadContext(String target) async {
    if (!pagedHistory) return;
    final generation = ++_contextGeneration;
    final entry = await loadEntry(target);
    if (entry == null) return;
    final position = await _historyCall('history_position', {'id': target});
    if (position == null) return;
    final pages = await Future.wait(
      [false, true].map(
        (newer) => _historyCall('history_page', {
          'conversationId': entry.item.conversationId,
          'cursor': position,
          'newer': newer,
          'limit': 100,
        }),
      ),
    );
    if (_closing || generation != _contextGeneration) return;
    contextTarget = target;
    contextEntries
      ..clear()
      ..add(entry);
    for (final page in pages) {
      contextEntries.addAll(_cacheRecords(page['entries'] as List));
    }
    contextEntries.sort(InboxStore._compareEntries);
    _olderContext = ((pages[0]['cursor'] ?? position) as Map)
        .cast<String, dynamic>();
    _newerContext = ((pages[1]['cursor'] ?? position) as Map)
        .cast<String, dynamic>();
    moreOlderContext = pages[0]['more'] == true;
    moreNewerContext = pages[1]['more'] == true;
    await loadEntries(
      contextEntries.map((entry) => entry.item.quote?.id).whereType<String>(),
    );
  }

  Future<void> extendContext({required bool newer}) {
    if (!pagedHistory ||
        contextEntries.isEmpty ||
        !(newer ? moreNewerContext : moreOlderContext)) {
      return Future.value();
    }
    if (_contextRead != null) return _contextRead!;
    final generation = _contextGeneration;
    final task =
        _historyCall('history_page', {
          'conversationId': contextEntries.first.item.conversationId,
          'cursor': newer ? _newerContext : _olderContext,
          'newer': newer,
        }).then((page) {
          if (_closing || generation != _contextGeneration) return;
          final ids = contextEntries.map((entry) => entry.item.id).toSet();
          contextEntries.addAll(
            _cacheRecords(
              page['entries'] as List,
            ).where((entry) => ids.add(entry.item.id)),
          );
          contextEntries.sort(InboxStore._compareEntries);
          if (newer) {
            _newerContext = (page['cursor'] as Map?)?.cast<String, dynamic>();
            moreNewerContext = page['more'] == true;
          } else {
            _olderContext = (page['cursor'] as Map?)?.cast<String, dynamic>();
            moreOlderContext = page['more'] == true;
          }
        });
    _contextRead = task;
    return task.whenComplete(() => _contextRead = null);
  }
}
