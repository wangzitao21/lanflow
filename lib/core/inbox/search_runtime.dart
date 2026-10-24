part of 'inbox_controller.dart';

class SearchSupersededException implements Exception {
  const SearchSupersededException();
  @override
  String toString() => '搜索条件已更新';
}

class _MessageSearch {
  _MessageSearch(this.query, this.group, this.revision)
    : key = jsonEncode(
        Map.fromEntries(
          query.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
        ),
      );
  final Map<String, dynamic> query;
  final Object? group;
  final int revision;
  final String key;
  final result = Completer<Map<String, dynamic>>();
}

extension _SearchRuntime on InboxController {
  Future<Map<String, dynamic>> _queueSearch(
    Map<String, dynamic> query,
    Object? group,
  ) {
    if (_closed) return Future.error(StateError('收件箱已关闭'));
    final next = _MessageSearch(Map.of(query), group, store.revision);
    if (group != null) {
      // Retire only this caller's pending searches. Other panels and callers
      // without a group retain their independent queries and page requests.
      for (final pending in _searchQueue.toList()) {
        if (!identical(pending.group, group)) continue;
        if (pending.key == next.key && pending.revision == next.revision) {
          return pending.result.future;
        }
        _searchQueue.remove(pending);
        pending.result.completeError(const SearchSupersededException());
      }
      final running = _activeSearch;
      if (running != null &&
          identical(running.group, group) &&
          running.key == next.key &&
          running.revision == next.revision) {
        return running.result.future;
      }
    }
    _searchQueue.add(next);
    _startNextSearch();
    return next.result.future;
  }

  void _startNextSearch() {
    if (_activeSearch != null || _closed || _searchQueue.isEmpty) return;
    final request = _searchQueue.removeAt(0);
    _activeSearch = request;
    _searchWorker =
        Future<Map<String, dynamic>>.sync(
              () => store.searchMessages(request.query),
            )
            .then<void>(
              request.result.complete,
              onError: (Object error, StackTrace stack) {
                request.result.completeError(error, stack);
              },
            )
            .whenComplete(() {
              _activeSearch = null;
              _searchWorker = null;
              _startNextSearch();
            });
  }

  void _cancelQueuedSearches({Object? group}) {
    for (final request in _searchQueue.toList()) {
      if (group != null && !identical(request.group, group)) continue;
      _searchQueue.remove(request);
      request.result.completeError(const SearchSupersededException());
    }
  }
}
